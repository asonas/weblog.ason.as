# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_runtime"
require "weblog_authoring/draft_migration"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_session"

class DraftRuntimeTest < Minitest::Test
  class SearchProcess
    def build(workdir:, corpus_dir:)
      path = File.join(workdir, "index.sqlite3")
      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE documents (id INTEGER PRIMARY KEY, collection TEXT, path TEXT, active INTEGER, hash TEXT)")
      db.execute("CREATE TABLE content (hash TEXT PRIMARY KEY, doc TEXT)")
      db.execute("CREATE VIRTUAL TABLE documents_fts USING fts5(path, title, body)")
      Dir.children(corpus_dir).sort.each_with_index do |name, index|
        body = File.read(File.join(corpus_dir, name))
        hash = Digest::SHA256.hexdigest(body)
        db.execute("INSERT INTO documents VALUES (?, 'weblog', ?, 1, ?)", [index + 1, name, hash])
        db.execute("INSERT INTO content VALUES (?, ?)", [hash, body])
        db.execute("INSERT INTO documents_fts(rowid, path, title, body) VALUES (?, ?, ?, ?)", [index + 1, name, body.lines.first, body])
      end
      db.close
      path
    end
  end

  def test_cutover_preserves_readers_then_publishes_asynchronously_without_legacy_writes_or_sending
    Dir.mktmpdir("draft-runtime") do |directory|
      root = Pathname(directory)
      database = WeblogAuthoring::DevelopmentDatabase.new(root.join("legacy.sqlite3"), content_dir: root.join("content"))
      database.setup!
      page = database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", title: "Migrated article", body: "Public original"))
      outbox = database.pending_webmention_outbox
      store = WeblogAuthoring::DraftStore.sqlite(root.join("drafts.sqlite3"))
      store.setup!
      store.setup_cutover!
      objects = WeblogAuthoring::LocalPublicationObjects.new(root.join("objects"))
      objects.put_object(bucket: "site", key: "index.html", body: '<html><head></head><body><div id="authoring-root"></div></body></html>')
      objects.put_object(bucket: "site", key: "static/authoring/public.html", body: '<html><head></head><body><div id="authoring-root"></div></body></html>')
      objects.put_object(bucket: "site", key: page.route, body: "Legacy article HTML")
      objects.put_object(bucket: "site", key: "feed.xml", body: "Legacy feed")
      client = Aws::Lambda::Client.new(stub_responses: true)
      client.stub_responses(:invoke, status_code: 202)
      publication = WeblogAuthoring::DraftPublication.local(store:)
      runtime = WeblogAuthoring::DraftRuntime.new(store:, database:, publication:, s3_client: objects, bucket: "site", site_url: "https://example.com", lambda_client: client, worker_function: "fixture-worker", search_runner: SearchProcess.new)
      codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
      cookie = codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf" }, ttl: 3600)
      api = runtime.api({ database:, session_codec: codec, allowed_github_user_id: 630_181 })
      request = lambda do |method, path, payload = {}, query = {}|
        api.call({ "rawPath" => path, "requestContext" => { "http" => { "method" => method } }, "queryStringParameters" => query,
          "headers" => { "x-csrf-token" => "csrf", "content-type" => "application/json" }, "cookies" => ["weblog_authoring_session=#{cookie}"], "body" => JSON.generate(payload), })
      end
      assert_equal "Legacy article HTML", request.call("GET", "/#{page.route}").fetch(:body)
      assert_equal "Legacy feed", request.call("GET", "/feed.xml").fetch(:body)
      store.transition_cutover(expected: "legacy", to: "draining")
      store.transition_cutover(expected: "draining", to: "frozen", evidence: { "legacy_writers_retired" => true, "legacy_generators_paused" => true, "pending_legacy_publications" => 0, "record" => "isolated fixture" })
      source = WeblogAuthoring::DraftMigration.export_sqlite(root.join("legacy.sqlite3"), site_url: "https://example.com")
      migration = WeblogAuthoring::DraftMigration.new(store:).import(source)
      original = store.published_snapshot(page.id)
      store.transition_cutover(expected: "frozen", to: "preparing", evidence: { "source_preserved" => true, "fingerprint" => migration.fetch("fingerprint"), "record" => "isolated source" })
      assert_raises(WeblogAuthoring::DraftStore::CutoverError) { runtime.legacy_work { flunk "Legacy generator admitted" } }
      repaired = runtime.work({ "operation" => "draft_repair" })
      assert_equal "completed", repaired.fetch("status"), repaired.inspect
      assert_equal "Legacy article HTML", request.call("GET", "/#{page.route}").fetch(:body)
      ready = { "published_outputs_ready" => true, "legacy_generators_paused" => true, "record" => "isolated outputs" }
      store.transition_cutover(expected: "preparing", to: "verifying", evidence: ready)
      assert_includes request.call("GET", "/#{page.route}").fetch(:body), "Public original"
      assert_equal request.call("GET", "/#{page.route}"), request.call("GET", "/#{page.route}/")
      assert_includes request.call("GET", "/#{page.route}").fetch(:body), "/draft-editor?id=#{page.id}"
      assert_includes request.call("GET", "/feed.xml").fetch(:body), "https://example.com/%4Digrated%20article"
      assert_equal "", request.call("HEAD", "/#{page.route}").fetch(:body)
      store.transition_cutover(expected: "verifying", to: "legacy", evidence: { "legacy_state_verified" => true, "record" => "isolated rollback" })
      assert_equal "Legacy article HTML", request.call("GET", "/#{page.route}").fetch(:body)
      store.transition_cutover(expected: "legacy", to: "draining")
      store.transition_cutover(expected: "draining", to: "frozen", evidence: { "legacy_writers_retired" => true, "legacy_generators_paused" => true, "pending_legacy_publications" => 0, "record" => "isolated fixture" })
      store.transition_cutover(expected: "frozen", to: "preparing", evidence: { "source_preserved" => true, "fingerprint" => migration.fetch("fingerprint"), "record" => "isolated source" })
      store.transition_cutover(expected: "preparing", to: "verifying", evidence: ready)
      store.transition_cutover(expected: "verifying", to: "open", evidence: { "reader_outputs_verified" => true, "legacy_generators_paused" => true, "record" => "isolated verification" })
      assert_equal 409, request.call("PATCH", "/api/authoring/pages/#{page.id}").fetch(:statusCode)
      update = { "protocol" => 1, "generation" => 1, "update_id" => "new-cover", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 15,
        "metadata" => { "cover_mode" => { "value" => "none", "expected_revision" => 0 } }, }
      assert_equal 200, request.call("POST", "/api/authoring/drafts/#{page.id}/uploads", update.merge("chunks" => 1)).fetch(:statusCode)
      assert_equal 200, request.call("PUT", "/api/authoring/drafts/#{page.id}/uploads/new-cover/chunks/0", update).fetch(:statusCode)
      assert_equal 200, request.call("POST", "/api/authoring/drafts/#{page.id}/uploads/new-cover/commit", update).fetch(:statusCode)
      assert_equal original.fetch("id"), store.published_snapshot(page.id).fetch("id")
      version = publication.accept(page.id, publication.prepare(page.id).merge("request_id" => "explicit-publication")).fetch("id")
      queued = request.call("POST", "/api/authoring/drafts/#{page.id}/publications/#{version}/run")
      assert_equal 200, queued.fetch(:statusCode), queued.inspect
      dispatch = JSON.parse(queued.fetch(:body)).fetch("dispatch")
      assert_equal "queued", dispatch.fetch("status")
      assert_equal original.fetch("id"), store.published_snapshot(page.id).fetch("id")
      result = runtime.work(JSON.parse(client.api_requests.last.fetch(:params).fetch(:payload)))
      assert(result.fetch("stages").all? { |stage| stage.fetch("status") == "completed" }, result.inspect)
      polled = request.call("GET", "/api/authoring/drafts/#{page.id}/publications/#{version}", {}, { "dispatch_id" => dispatch.fetch("id") })
      assert_equal "completed", JSON.parse(polled.fetch(:body)).dig("dispatch", "status")
      assert_equal version, store.published_snapshot(page.id).fetch("id")
      assert_equal "none", store.published_snapshot(page.id).dig("metadata", "cover_mode")
      assert_includes request.call("GET", "/api/search", {}, { "q" => "original" }).fetch(:body), "Migrated article"
      assert_equal outbox, database.pending_webmention_outbox
      assert_equal "Legacy article HTML", objects.get_object(bucket: "site", key: page.route).body.read
      store.transition_cutover(expected: "open", to: "paused")
      assert_raises(WeblogAuthoring::DraftStore::Error) { store.transition_cutover(expected: "paused", to: "legacy") }
      assert_equal version, store.published_snapshot(page.id).fetch("id")
    end
  end
end
