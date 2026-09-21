# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_store"
require "weblog_authoring/draft_migration"
require "weblog_authoring/lambda_api"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_session"
require "weblog_authoring/draft_cutover_api"

class DraftCutoverTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("draft-cutover"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @store.setup_cutover!
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_maintenance_closes_admission_before_waiting_for_inflight_legacy_writes
    entered = Queue.new
    release = Queue.new
    writer = Thread.new do
      @store.with_cutover_operation("legacy_write") do |phase|
        entered << phase
        release.pop
      end
    end
    assert_equal "legacy", entered.pop
    @store.transition_cutover(expected: "legacy", to: "draining")
    assert_equal 1, @store.cutover_status.fetch("operations").length
    error = assert_raises(WeblogAuthoring::DraftStore::CutoverError) { @store.with_cutover_operation("legacy_write") { flunk "Admitted during maintenance" } }
    assert_equal 503, error.status
    assert_equal "authoring_maintenance", error.code
    evidence = { "legacy_writers_retired" => true, "legacy_generators_paused" => true, "pending_legacy_publications" => 0, "record" => "fixture evidence" }
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.transition_cutover(expected: "draining", to: "frozen", evidence:) }
    release << true
    writer.value
    assert_empty @store.cutover_status.fetch("operations")
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.transition_cutover(expected: "draining", to: "frozen") }
    assert_raises(IOError) { @store.with_cutover_operation("publication") { raise IOError, "fixture publication failure" } }
    assert_empty @store.cutover_status.fetch("operations")
    @store.transition_cutover(expected: "draining", to: "frozen", evidence:)
    assert_equal "frozen", @store.cutover_status.fetch("phase")
    assert_raises(WeblogAuthoring::DraftStore::CutoverError) { @store.with_cutover_operation("publication") { flunk "Generator admitted while frozen" } }
  ensure
    release << true if release
    writer&.join
  end

  def test_recovery_removes_only_the_verified_stale_publication_receipt
    @store.transition_cutover(expected: "legacy", to: "draining")
    @store.transition_cutover(expected: "draining", to: "frozen", evidence: {
      "legacy_writers_retired" => true, "legacy_generators_paused" => true, "pending_legacy_publications" => 0, "record" => "fixture drain evidence",
    })
    source = { "format" => 1, "site_url" => "https://example.com", "articles" => [] }
    migration = WeblogAuthoring::DraftMigration.new(store: @store).import(source)
    @store.transition_cutover(expected: "frozen", to: "preparing", evidence: {
      "source_preserved" => true, "fingerprint" => migration.fetch("fingerprint"), "record" => "fixture source",
    })
    database = SQLite3::Database.new(@root.join("drafts.sqlite3"))
    database.execute("INSERT INTO draft_cutover_operations VALUES (?, 'draft_publication', 'preparing', ?)", ["stale", Time.now.utc.iso8601(6)])
    database.execute("INSERT INTO draft_cutover_operations VALUES (?, 'draft_publication', 'preparing', ?)", ["other", Time.now.utc.iso8601(6)])
    evidence = { "record" => "request ended", "operation_ended" => true, "partial_state_preserved" => true, "request_id" => "request-1" }

    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.recover_cutover_operation(id: "stale", evidence: evidence.except("operation_ended")) }
    status = @store.recover_cutover_operation(id: "stale", evidence:)

    assert_equal ["other"], (status.fetch("operations").map { |operation| operation.fetch("id") })
  ensure
    database&.close
  end

  def test_rollback_is_allowed_before_reopening_but_new_work_is_retained_after_reopening
    freeze_legacy
    source = { "format" => 1, "site_url" => "https://example.com", "articles" => [{
      "id" => "dc802ad0b89946aeb6b7623c2ba7bc79", "page_type" => "named", "route" => "元の記事", "title" => "元の記事", "body" => "保持する本文",
      "cover_mode" => "none", "cover_image_url" => nil, "created_at" => "2026-09-01T01:00:00Z", "updated_at" => "2026-09-02T01:00:00Z", "published_at" => "2026-09-01T01:00:00Z",
    }], }
    migration = WeblogAuthoring::DraftMigration.new(store: @store)
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.transition_cutover(expected: "frozen", to: "preparing") }
    imported = migration.import(source)
    verify = { "fingerprint" => imported.fetch("fingerprint"), "source_preserved" => true, "record" => "fixture source verification" }
    @store.transition_cutover(expected: "frozen", to: "preparing", evidence: verify)
    ready = { "published_outputs_ready" => true, "legacy_generators_paused" => true, "record" => "fixture output placement" }
    @store.transition_cutover(expected: "preparing", to: "verifying", evidence: ready)
    assert_raises(WeblogAuthoring::DraftStore::CutoverError) { @store.with_cutover_operation("draft_write") { flunk "Editing reopened without verification" } }
    @store.transition_cutover(expected: "verifying", to: "legacy", evidence: { "legacy_state_verified" => true, "record" => "fixture rollback verification" })
    assert_equal "legacy", @store.with_cutover_operation("legacy_write") { |phase| phase }
    freeze_legacy
    @store.transition_cutover(expected: "frozen", to: "preparing", evidence: verify)
    @store.transition_cutover(expected: "preparing", to: "verifying", evidence: ready)
    reopen = { "reader_outputs_verified" => true, "legacy_generators_paused" => true, "record" => "fixture reader verification" }
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.transition_cutover(expected: "verifying", to: "open") }
    @store.transition_cutover(expected: "verifying", to: "open", evidence: reopen)
    id = SecureRandom.uuid
    @store.with_cutover_operation("draft_write") { @store.create(id, { "protocol" => 1, "generation" => 1 }) }
    error = assert_raises(WeblogAuthoring::DraftStore::CutoverError) { @store.with_cutover_operation("legacy_write") { flunk "Legacy writer reopened" } }
    assert_equal 409, error.status
    assert_equal "upgrade_required", error.code
    assert_raises(WeblogAuthoring::DraftStore::Error) { migration.import(source) }
    @store.transition_cutover(expected: "open", to: "paused")
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.transition_cutover(expected: "paused", to: "legacy") }
    assert_raises(WeblogAuthoring::DraftStore::CutoverError) { @store.with_cutover_operation("draft_write") { flunk "Write admitted during repair" } }
    assert_equal id, @store.read(id, {}).fetch("id")
    @store.transition_cutover(expected: "paused", to: "open", evidence: reopen)
    assert_equal id, @store.read(id, {}).fetch("id")
  end

  def test_api_keeps_readers_available_and_rejects_both_write_protocols_until_reopened
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    original = database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", title: "元の記事", body: "公開中の本文"))
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    cookie = codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf" }, ttl: 3600)
    options = { database:, session_codec: codec, allowed_github_user_id: 630_181, frontend_url: "https://example.com" }
    legacy = WeblogAuthoring::LambdaApi.new(**options)
    published = WeblogAuthoring::LambdaApi.new(**options, draft_store: @store, reader_database: WeblogAuthoring::DraftReader.new(store: @store, database:))
    api = WeblogAuthoring::DraftCutoverApi.new(store: @store, legacy:, published:)
    request = lambda do |method, path, payload = {}|
      api.call({ "requestContext" => { "http" => { "method" => method } }, "rawPath" => path,
        "pathParameters" => { "id" => original.id }, "queryStringParameters" => {}, "headers" => { "x-csrf-token" => "csrf", "content-type" => "application/json" },
        "cookies" => ["weblog_authoring_session=#{cookie}"], "body" => JSON.generate(payload), })
    end
    freeze_legacy
    [
      ["POST", "/api/authoring/pages"], ["PATCH", "/api/authoring/pages/#{original.id}"], ["POST", "/api/rename"],
      ["PUT", "/api/authoring/drafts/#{original.id}"], ["POST", "/api/authoring/drafts/#{original.id}/publications"],
    ].each do |method, path|
      response = request.call(method, path)
      assert_equal 503, response.fetch(:statusCode)
      assert_equal "authoring_maintenance", JSON.parse(response.fetch(:body)).fetch("code")
      assert_equal "no-store", response.fetch(:headers).fetch("cache-control")
    end
    assert_equal "公開中の本文", JSON.parse(request.call("GET", "/api/pages/#{original.id}").fetch(:body)).fetch("body")
    assert_equal 503, api.call({ "source" => "aws.events", "detail-type" => "Scheduled Event" }).fetch(:statusCode)
    source = WeblogAuthoring::DraftMigration.export_sqlite(@root.join("legacy.sqlite3"), site_url: "https://example.com")
    # Distinct fixture bodies expose which reader handled each request.
    source.fetch("articles").first["body"] = "新経路の検証用本文"
    result = WeblogAuthoring::DraftMigration.new(store: @store).import(source)
    @store.transition_cutover(expected: "frozen", to: "preparing", evidence: { "source_preserved" => true, "fingerprint" => result.fetch("fingerprint"), "record" => "fixture source" })
    assert_equal "公開中の本文", JSON.parse(request.call("GET", "/api/pages/#{original.id}").fetch(:body)).fetch("body")
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.transition_cutover(expected: "preparing", to: "verifying") }
    @store.transition_cutover(expected: "preparing", to: "verifying", evidence: { "published_outputs_ready" => true, "legacy_generators_paused" => true, "record" => "fixture outputs" })
    assert_equal "新経路の検証用本文", JSON.parse(request.call("GET", "/api/pages/#{original.id}").fetch(:body)).fetch("body")
    @store.transition_cutover(expected: "verifying", to: "open", evidence: { "reader_outputs_verified" => true, "legacy_generators_paused" => true, "record" => "fixture outputs" })
    outbox = database.pending_webmention_outbox
    rejected = request.call("PATCH", "/api/authoring/pages/#{original.id}", { "title" => "元の記事", "body" => "旧画面からの上書き" })
    assert_equal 409, rejected.fetch(:statusCode)
    assert_equal "upgrade_required", JSON.parse(rejected.fetch(:body)).fetch("code")
    assert_equal "公開中の本文", database.find(original.id).body
    assert_equal outbox, database.pending_webmention_outbox
    created = request.call("PUT", "/api/authoring/drafts/#{SecureRandom.uuid}", { "protocol" => 1, "generation" => 1 })
    assert_equal 200, created.fetch(:statusCode)
    @store.transition_cutover(expected: "open", to: "paused")
    assert_equal "新経路の検証用本文", JSON.parse(request.call("GET", "/api/pages/#{original.id}").fetch(:body)).fetch("body")
  end

  private

  def freeze_legacy
    @store.transition_cutover(expected: "legacy", to: "draining")
    @store.transition_cutover(expected: "draining", to: "frozen", evidence: {
      "legacy_writers_retired" => true, "legacy_generators_paused" => true, "pending_legacy_publications" => 0, "record" => "fixture drain evidence",
    })
  end
end
