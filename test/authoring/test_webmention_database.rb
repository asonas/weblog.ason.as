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

  def test_moderation_decision_requests_a_publication_refresh_for_the_target_page
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "本文"
    ))
    initial = @database.pending_webmention_outbox.fetch(0)
    @database.complete_webmention_outbox(
      initial.fetch("id"), revision: initial.dig("payload", "revision")
    )
    @job = @job.merge(
      "target" => "https://weblog.ason.as/Webmention", "target_page_id" => page.id
    )
    verify(title: "First title", hash: "first-hash")
    relation = @database.list_webmentions.fetch(0)

    @database.moderate_webmention(id: relation.fetch("id"), decision: "approved")

    refresh = @database.pending_webmention_outbox.fetch(0)
    assert_equal page.id, refresh.fetch("page_id")
    refute_equal initial.dig("payload", "revision"), refresh.dig("payload", "revision")
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

  def test_many_page_saves_leave_one_effective_publication_refresh
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "[First](https://example.net/first)"
    ))
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: "named", name: "Webmention",
      body: "[Second](https://example.net/second)", expected_updated_at: page.updated_at
    ))
    @database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: "named", name: "Webmention",
      body: "[Latest](https://example.net/latest)", expected_updated_at: page.updated_at
    ))

    pending = @database.pending_webmention_outbox
    outbox = pending.fetch(0)

    assert_equal 1, pending.length
    assert_equal "page_saved", outbox.fetch("event_type")
    assert_empty outbox.dig("payload", "previous_targets")
    assert_equal ["https://example.net/latest"], outbox.dig("payload", "current_targets")
    assert_empty @database.webmention_page_targets(page.id)
  end

  def test_save_racing_with_completion_remains_pending
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "[First](https://example.net/first)"
    ))
    publishing = @database.pending_webmention_outbox.fetch(0)
    @database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: "named", name: "Webmention",
      body: "[Latest](https://example.net/latest)", expected_updated_at: page.updated_at
    ))

    completed = @database.complete_webmention_outbox(
      publishing.fetch("id"), revision: publishing.dig("payload", "revision")
    )

    refute completed
    pending = @database.pending_webmention_outbox.fetch(0)
    assert_equal ["https://example.net/latest"], pending.dig("payload", "current_targets")
    assert_empty @database.webmention_page_targets(page.id)
  end

  def test_failure_after_completion_restores_the_refresh_for_retry
    @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "本文"
    ))
    refresh = @database.pending_webmention_outbox.fetch(0)
    @database.complete_webmention_outbox(
      refresh.fetch("id"), revision: refresh.dig("payload", "revision")
    )

    @database.fail_webmention_outbox(refresh.fetch("id"))

    retried = @database.pending_webmention_outbox.fetch(0)
    assert_equal refresh.fetch("id"), retried.fetch("id")
    assert_equal 2, retried.fetch("attempt_count")
  end

  def test_route_transition_uses_the_last_published_route
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "old-route", body: "本文"
    ))
    published = @database.pending_webmention_outbox.fetch(0)
    @database.complete_webmention_outbox(
      published.fetch("id"), revision: published.dig("payload", "revision")
    )
    sqlite = SQLite3::Database.new(File.join(@tmpdir, "database.sqlite3"))
    sqlite.execute(
      "UPDATE pages SET name = ?, updated_at = ? WHERE id = ?",
      ["new-route", (NOW + 1).iso8601(9), page.id]
    )
    sqlite.close

    refresh = @database.request_publication_refresh(page.id)

    assert_equal "https://weblog.ason.as/old-route", refresh.dig("payload", "previous_source_url")
    assert_equal "https://weblog.ason.as/new-route", refresh.dig("payload", "source_url")
  end

  def test_backlog_compaction_retains_one_refresh_and_keeps_old_rows_recoverable
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "本文"
    ))
    sqlite = SQLite3::Database.new(File.join(@tmpdir, "database.sqlite3"))
    payload = JSON.generate(
      "source_url" => "https://weblog.ason.as/Webmention",
      "previous_source_url" => nil, "previous_targets" => [], "current_targets" => []
    )
    %w[legacy-one legacy-two].each do |id|
      sqlite.execute(
        <<~SQL,
          INSERT INTO webmention_outbox (
            id, event_type, page_id, payload, status, attempt_count, created_at, notified_at, completed_at
          ) VALUES (?, 'page_saved', ?, ?, 'pending', 0, ?, NULL, NULL)
        SQL
        [id, page.id, payload, NOW.iso8601(9)]
      )
    end
    sqlite.close

    assert_equal({ "pages" => 1, "superseded" => 0, "retained" => 1 },
                 @database.compact_webmention_outbox)
    summary = @database.compact_webmention_outbox(dry_run: false)

    assert_equal({ "pages" => 1, "superseded" => 2, "retained" => 1 }, summary)
    assert_equal 1, @database.pending_webmention_outbox.length
    assert_nil @database.webmention_outbox("legacy-one")
  end

  def test_emptying_a_published_page_records_an_unpublish_outbox_and_deactivates_targets
    page = @database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "Webmention", body: "[First](https://example.net/first)"
    ))
    published = @database.pending_webmention_outbox.fetch(0)
    @database.complete_webmention_outbox(
      published.fetch("id"), revision: published.dig("payload", "revision")
    )
    @database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: "named", name: "Webmention", body: "",
      expected_updated_at: page.updated_at
    ))

    outbox = @database.pending_webmention_outbox.find do |item|
      item.fetch("event_type") == "page_unpublished"
    end

    assert_equal ["https://example.net/first"], outbox.dig("payload", "previous_targets")
    assert_empty outbox.dig("payload", "current_targets")
    assert @database.webmention_page_targets(page.id).fetch(0).fetch("active")
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
