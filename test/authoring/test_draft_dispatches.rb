# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_migration"
require "aws-sdk-lambda"
require "weblog_authoring/remote_draft_jobs"
require "weblog_authoring/draft_jobs"

class DraftDispatchesTest < Minitest::Test
  def test_overlapping_dispatches_and_resends_do_not_repeat_a_running_stage
    with_publication do |store, id, version|
      publisher = Object.new
      publisher.define_singleton_method(:current?) { |_snapshot| true }
      outputs = Object.new
      outputs.define_singleton_method(:current?) { |_stage| true }
      jobs = WeblogAuthoring::DraftJobs.new(store:, publisher:, outputs:)
      dispatches = 2.times.map { store.queue_publication_dispatch(id, version) }
      run = lambda do |dispatch|
        work = store.start_publication_dispatch(dispatch.fetch("id"))
        next unless work
        jobs.run(id, version, retry_now: true)
        store.finish_publication_dispatch(dispatch.fetch("id"))
      end
      calls = 0
      publisher.define_singleton_method(:run) do |_article, _version|
        calls += 1
        run.call(dispatches.last) if calls == 1
      end
      run.call(dispatches.first)
      run.call(dispatches.first)
      run.call(store.queue_publication_dispatch(id, version))
      assert_equal 1, calls
      html = store.publication_stages(id, version).find { |stage| stage.fetch("stage") == "html" }
      assert_equal 1, html.fetch("attempts")
      assert_equal "completed", html.fetch("status")
    end
  end

  def test_running_claim_recovers_only_after_its_lease_expires
    with_publication do |store, id, version|
      now = Time.now.utc
      first = store.begin_publication_stage(id, version, "html", now:)
      assert_nil store.begin_publication_stage(id, version, "html", now: now + 299, retry_now: true)
      recovered = store.begin_publication_stage(id, version, "html", now: now + 300, retry_now: true)
      refute_nil recovered
      refute_equal first.fetch("token"), recovered.fetch("token")
      refute store.complete_publication_stage(first, now: now + 301)
      assert store.complete_publication_stage(recovered, now: now + 301)
    end
  end

  def test_manual_retry_still_resumes_retry_wait_and_needs_attention
    with_publication do |store, id, version|
      now = Time.now.utc
      5.times do |index|
        claim = store.begin_publication_stage(id, version, "html", now:, retry_now: true)
        refute_nil claim
        store.fail_publication_stage(claim, "temporary failure", now:)
        stage = store.publication_stages(id, version).first
        assert_equal(index == 4 ? "needs_attention" : "retry_wait", stage.fetch("status"))
      end
      assert_nil store.begin_publication_stage(id, version, "html", now:)
      refute_nil store.begin_publication_stage(id, version, "html", now:, retry_now: true)
    end
  end

  def test_async_publication_tracks_worker_completion_separately_from_acceptance
    Dir.mktmpdir("draft-dispatch") do |directory|
      store = WeblogAuthoring::DraftStore.sqlite(File.join(directory, "drafts.sqlite3"))
      store.setup!
      id = SecureRandom.uuid
      source = { "format" => 1, "site_url" => "https://example.com", "articles" => [{
        "id" => id, "page_type" => "named", "route" => "記事", "title" => "記事", "body" => "本文", "cover_mode" => "none", "cover_image_url" => nil,
        "created_at" => "2026-09-01T00:00:00Z", "updated_at" => "2026-09-01T00:00:00Z", "published_at" => "2026-09-01T00:00:00Z",
      }], }
      WeblogAuthoring::DraftMigration.new(store:).import(source)
      snapshot = store.published_snapshot(id)
      client = Aws::Lambda::Client.new(stub_responses: true)
      client.stub_responses(:invoke, status_code: 202)
      jobs = WeblogAuthoring::RemoteDraftJobs.new(store:, lambda_client: client, function_name: "fixture-worker")
      queued = jobs.run(id, snapshot.fetch("id"), retry_now: true)
      assert_equal "queued", queued.dig("dispatch", "status")
      event = client.api_requests.last.fetch(:params)
      assert_equal "Event", event.fetch(:invocation_type)
      dispatch_id = JSON.parse(event.fetch(:payload)).fetch("dispatch_id")
      assert_equal queued.dig("dispatch", "id"), dispatch_id
      claim = store.start_publication_dispatch(dispatch_id)
      assert_equal [id, snapshot.fetch("id")], claim.values_at("article_id", "version_id")
      assert_equal "running", store.publication_dispatch(id, snapshot.fetch("id"), dispatch_id).fetch("status")
      store.finish_publication_dispatch(dispatch_id)
      assert_equal "completed", store.publication_dispatch(id, snapshot.fetch("id"), dispatch_id).fetch("status")
      assert_nil store.start_publication_dispatch(dispatch_id)
      assert_equal snapshot, store.published_snapshot(id)
      assert_raises(WeblogAuthoring::DraftStore::Error) { store.publication_dispatch(SecureRandom.uuid, snapshot.fetch("id"), dispatch_id) }
    end
  end

  private

  def with_publication
    Dir.mktmpdir("draft-claims") do |directory|
      store = WeblogAuthoring::DraftStore.sqlite(File.join(directory, "drafts.sqlite3"))
      store.setup!
      id = SecureRandom.uuid
      WeblogAuthoring::DraftMigration.new(store:).import({ "format" => 1, "site_url" => "https://example.com", "articles" => [{
        "id" => id, "page_type" => "named", "route" => "Article", "title" => "Article", "body" => "Body", "cover_mode" => "none", "cover_image_url" => nil,
        "created_at" => "2026-09-01T00:00:00Z", "updated_at" => "2026-09-01T00:00:00Z", "published_at" => "2026-09-01T00:00:00Z",
      }], })
      yield store, id, store.published_snapshot(id).fetch("id")
    end
  end
end
