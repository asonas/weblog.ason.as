# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "weblog_authoring/development_database"
require "weblog_authoring/webmention_fetcher"

class WebmentionDatabaseTest < Minitest::Test
  Response = WeblogAuthoring::WebmentionFetcher::Response
  NOW = Time.iso8601("2026-08-30T12:00:00Z")

  def setup
    @tmpdir = Dir.mktmpdir
    @database = WeblogAuthoring::DevelopmentDatabase.new(
      File.join(@tmpdir, "database.sqlite3"), content_dir: File.join(@tmpdir, "content"), clock: -> { NOW }
    )
    @database.setup!
    @job = {
      "job_id" => "job-id", "source" => "https://example.com/post",
      "target" => "https://weblog.ason.as/article", "target_page_id" => "page-id",
      "received_at" => "2026-08-30T11:59:00Z",
    }
    @response = Response.new(
      url: @job.fetch("source"), status: 200, content_type: "text/html", body: "body",
      link_header: nil, redirect_count: 0, duration_ms: 12
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_verified_relation_starts_pending_and_approval_publishes_the_candidate
    verify(title: "First title", hash: "first-hash")
    pending = @database.list_webmentions.fetch(0)

    assert_equal "pending", pending.fetch("moderation_status")
    assert_equal "First title", pending.fetch("candidate").fetch("title")
    assert_nil pending.fetch("approved")

    approved = @database.moderate_webmention(id: pending.fetch("id"), decision: "approved")

    assert_equal "approved", approved.fetch("moderation_status")
    assert_equal "First title", approved.fetch("approved").fetch("title")
    assert_nil approved.fetch("candidate")
    public_ids = @database.approved_webmentions_for_page("page-id").map { |item| item.fetch("id") }
    assert_equal [approved.fetch("id")], public_ids
  end

  def test_changed_approved_mention_keeps_the_public_snapshot_until_the_candidate_is_approved
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)
    @database.moderate_webmention(id: relation.fetch("id"), decision: "approved")

    verify(title: "Changed title", hash: "changed-hash")
    changed = @database.list_webmentions.fetch(0)

    assert_equal "First title", changed.fetch("approved").fetch("title")
    assert_equal "Changed title", changed.fetch("candidate").fetch("title")
  end

  def test_duplicate_notification_does_not_create_an_unchanged_candidate
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)
    @database.moderate_webmention(id: relation.fetch("id"), decision: "approved")

    verify(title: "First title", hash: "first-hash")
    duplicate = @database.list_webmentions.fetch(0)

    assert_equal "approved", duplicate.fetch("moderation_status")
    assert_nil duplicate.fetch("candidate")
    assert_equal "First title", duplicate.fetch("approved").fetch("title")
  end

  def test_rejected_mention_can_be_returned_to_pending_without_refetching
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)
    @database.moderate_webmention(id: relation.fetch("id"), decision: "rejected")

    pending = @database.moderate_webmention(id: relation.fetch("id"), decision: "pending")

    assert_equal "pending", pending.fetch("moderation_status")
    assert_equal "First title", pending.fetch("candidate").fetch("title")
  end

  def test_confirmed_link_removal_immediately_removes_the_public_snapshot
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)
    @database.moderate_webmention(id: relation.fetch("id"), decision: "approved")

    @database.record_webmention_deletion(job: @job, response: @response, reason: "link_missing")

    assert_empty @database.approved_webmentions_for_page("page-id")
    assert_equal "deleted", @database.list_webmentions.fetch(0).fetch("verification_status")
  end

  def test_a_restored_deleted_link_returns_as_a_new_pending_candidate
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)
    @database.moderate_webmention(id: relation.fetch("id"), decision: "approved")
    @database.record_webmention_deletion(job: @job, response: @response, reason: "link_missing")

    verify(title: "Restored title", hash: "restored-hash")
    restored = @database.list_webmentions.fetch(0)

    assert_equal relation.fetch("id"), restored.fetch("id")
    assert_equal "pending", restored.fetch("moderation_status")
    assert_equal "Restored title", restored.fetch("candidate").fetch("title")
    assert_nil restored.fetch("approved")
  end

  def test_relationless_failures_remain_diagnosable_and_requeueable
    @database.record_webmention_failure(
      job: @job, result: "blocked_source", message: "private address"
    )

    failure = @database.list_webmention_failures.fetch(0)
    retry_job = @database.webmention_reverification(failure.fetch("id"))

    assert_equal "blocked_source", failure.fetch("result")
    assert_equal "https://example.com/post", retry_job.fetch("source")
    assert_equal "page-id", retry_job.fetch("target_page_id")
  end

  def test_page_save_records_a_transactional_publish_and_delivery_outbox
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "[First](https://example.net/first)"
    ))
    @database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: "named", name: "Webmention",
      body: "[Second](https://example.net/second)", expected_updated_at: page.updated_at
    ))

    outbox = @database.pending_webmention_outbox.find do |item|
      item.dig("payload", "current_targets") == ["https://example.net/second"]
    end

    assert_equal "page_saved", outbox.fetch("event_type")
    assert_equal ["https://example.net/first"], outbox.dig("payload", "previous_targets")
    assert_equal ["https://example.net/second"], outbox.dig("payload", "current_targets")
    targets = @database.webmention_page_targets(page.id)
    assert_equal(
      ["https://example.net/first", "https://example.net/second"],
      targets.map { |target| target.fetch("target_url") }
    )
    refute targets.fetch(0).fetch("active")
    assert targets.fetch(1).fetch("active")
  end

  def test_emptying_a_published_page_records_an_unpublish_outbox_and_deactivates_targets
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "[First](https://example.net/first)"
    ))
    @database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: "named", name: "Webmention", body: "",
      expected_updated_at: page.updated_at
    ))

    outbox = @database.pending_webmention_outbox.find do |item|
      item.fetch("event_type") == "page_unpublished"
    end

    assert_equal ["https://example.net/first"], outbox.dig("payload", "previous_targets")
    assert_empty outbox.dig("payload", "current_targets")
    refute @database.webmention_page_targets(page.id).fetch(0).fetch("active")
  end

  def test_complete_deletion_removes_the_relation_snapshots_and_attempt_history
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)

    @database.delete_webmention(id: relation.fetch("id"))

    assert_empty @database.list_webmentions
    assert_empty @database.list_webmention_failures
    assert_raises(KeyError) { @database.delete_webmention(id: relation.fetch("id")) }
  end

  def test_failed_delivery_remains_diagnosable
    delivery = @job.merge("delivery_id" => "delivery-id", "page_id" => "page-id")
    @database.record_webmention_delivery(
      job: delivery, status: "temporary_failure", http_status: 503, error: "unavailable"
    )

    failure = @database.list_webmention_delivery_failures.fetch(0)

    assert_equal "delivery-id", failure.fetch("id")
    assert_equal 503, failure.fetch("http_status")
    assert_equal "unavailable", failure.fetch("error")
    retry_job = @database.webmention_delivery_retry("delivery-id")
    assert_equal "https://example.com/post", retry_job.fetch("source")
    assert_equal "https://weblog.ason.as/article", retry_job.fetch("target")
  end

  private

  def verify(title:, hash:)
    @database.record_verified_webmention(
      job: @job, response: @response, title:, site_name: "Example", content_hash: hash
    )
  end
end
