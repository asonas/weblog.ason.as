# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_migration"
require "aws-sdk-lambda"
require "weblog_authoring/remote_draft_jobs"

class DraftDispatchesTest < Minitest::Test
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
end
