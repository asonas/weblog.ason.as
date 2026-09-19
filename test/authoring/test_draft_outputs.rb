# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_jobs"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_api"

class DraftOutputsTest < Minitest::Test
  class SearchProcess
    attr_accessor :failure
    attr_accessor :before_build

    def build(workdir:, corpus_dir:)
      raise IOError, "search process unavailable" if failure
      hook = before_build
      self.before_build = nil
      hook&.call
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

  def test_repair_finds_corrupt_output_even_when_all_stages_are_completed
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "publish")).fetch("id")
    @jobs.run(@id, version)
    active = @store.published_snapshot(@id)
    previous_key = @store.output_head("atom").fetch("object_key")
    @objects.put_object(bucket: "site", key: previous_key, body: "corrupt output")
    assert_equal "completed", @jobs.repair.fetch("status")
    assert_includes @outputs.feed, "Public article"
    refute_equal previous_key, @store.output_head("atom").fetch("object_key")
    assert_equal active, @store.published_snapshot(@id)
    assert_equal 1, @store.publication_stages(@id, version).find { |stage| stage["stage"] == "search" }.fetch("attempts")
  end

  def test_repair_restores_corrupt_and_missing_article_html_without_republication
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "publish")).fetch("id")
    @jobs.run(@id, version)
    active = @store.published_snapshot(@id)
    revision = @store.publication_revision
    @objects.put_object(bucket: "site", key: active.fetch("html_key"), body: "corrupt article")
    assert_equal "completed", @jobs.repair.fetch("status")
    repaired = @store.published_snapshot(@id)
    assert_includes @publisher.read(repaired), "Public article"
    refute_equal active.fetch("html_key"), repaired.fetch("html_key")
    File.unlink(@root.join("objects", "site", repaired.fetch("html_key")))
    assert_equal "completed", @jobs.repair.fetch("status")
    assert_includes @publisher.read(@store.published_snapshot(@id)), "Public article"
    assert_equal active.except("html_key", "html_digest"), @store.published_snapshot(@id).except("html_key", "html_digest")
    assert_equal revision, @store.publication_revision
  end

  def test_exhausted_search_attempts_require_author_retry_and_survive_retention
    @process.failure = true
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "publish")).fetch("id")
    @jobs.run(@id, version)
    4.times { @now += 3600; @jobs.repair }
    failed = @store.publication_stages(@id, version).find { |stage| stage["stage"] == "search" }
    assert_equal ["needs_attention", 5], failed.values_at("status", "attempts")
    @now += 31 * 86400
    @jobs.repair
    assert_equal(failed, @store.publication_stages(@id, version).find { |stage| stage["stage"] == "search" })
    @process.failure = false
    assert(@jobs.run(@id, version, retry_now: true).fetch("stages").all? { |stage| stage["status"] == "completed" })
  end

  def test_slow_output_generation_cannot_replace_a_newer_publication
    old = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "old")).fetch("id")
    latest = nil
    @process.before_build = lambda do
      @store.append(@id, { "protocol" => 1, "generation" => 1, "update_id" => "new-cover", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 6,
        "metadata" => { "cover_mode" => { "value" => "none", "expected_revision" => 0 } }, })
      latest = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "latest")).fetch("id")
      @jobs.run(@id, latest)
    end
    @jobs.run(@id, old)
    assert_equal latest, @store.published_snapshot(@id).fetch("id")
    assert @outputs.current?("search")
    assert @outputs.current?("atom")
    assert_equal "superseded", @store.publication_stages(@id, old).find { |stage| stage["stage"] == "search" }.fetch("status")
    @now += 31 * 86400
    @jobs.repair
    assert_empty @store.publication_stages(@id, old)
    assert_equal 404, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.publication_job(@id, old) }.status
    assert_equal old, @store.publication_snapshot(@id, old).fetch("id")
  end

  def test_eventbridge_repair_serves_published_feed_and_search_without_draining_webmention
    @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "Legacy article", body: "https://example.net/target"))
    unsent = @database.pending_webmention_outbox
    refute_empty unsent
    @process.failure = true
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "publish")).fetch("id")
    @jobs.run(@id, version)
    active = @store.published_snapshot(@id)
    api = WeblogAuthoring::LambdaApi.new(database: @database, draft_store: @store, draft_publication: @publication, draft_publisher: @publisher, draft_jobs: @jobs, draft_outputs: @outputs)
    @process.failure = false
    @now += 3600
    scheduled = api.call({ "source" => "aws.events", "detail-type" => "Scheduled Event" })
    assert_equal "completed", JSON.parse(scheduled.fetch(:body)).fetch("status")
    feed = api.call({ "requestContext" => { "http" => { "method" => "GET" } }, "rawPath" => "/feed.xml" })
    assert_equal 200, feed.fetch(:statusCode)
    assert_includes feed.fetch(:body), "urn:uuid:#{@id}"
    refute_includes feed.fetch(:body), "Legacy article"
    search = api.call({ "requestContext" => { "http" => { "method" => "GET" } }, "rawPath" => "/api/search", "queryStringParameters" => { "q" => "Public" } })
    assert_equal(["Public article"], JSON.parse(search.fetch(:body)).fetch("results").map { |entry| entry.fetch("title") })
    assert_equal active, @store.published_snapshot(@id)
    assert_equal unsent, @database.pending_webmention_outbox
  end

  def setup
    @root = Pathname(Dir.mktmpdir("draft-outputs"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    @database.setup!
    @id = SecureRandom.uuid
    @store.create(@id, { "protocol" => 1, "generation" => 1 })
    append_title("Public article", 0)
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", "history")
    assert status.success?, error
    JSON.parse(output).each { |update| @store.append(@id, update.merge("protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid, "body_bytes" => 12)) }
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    @objects = WeblogAuthoring::LocalPublicationObjects.new(@root.join("objects"))
    @objects.put_object(bucket: "site", key: "index.html", body: '<html><head></head><body><div id="authoring-root"></div></body></html>')
    @publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database: @database, s3_client: @objects, site_bucket: "site", site_url: "https://example.com")
    @process = SearchProcess.new
    @now = Time.now.utc
    @outputs = WeblogAuthoring::DraftOutputs.new(store: @store, s3_client: @objects, bucket: "site", site_url: "https://example.com", search_runner: @process, cache_dir: @root.join("search-cache").to_s)
    @jobs = WeblogAuthoring::DraftJobs.new(store: @store, publisher: @publisher, outputs: @outputs, clock: -> { @now })
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_partial_search_failure_keeps_article_and_feed_public_and_retry_only_resumes_search
    @process.failure = true
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "publish" )).fetch("id")
    result = @jobs.run(@id, version, retry_now: true)
    assert_equal "completed", result.fetch("status")
    assert_equal "retry_wait", result.fetch("stages").find { |stage| stage["stage"] == "search" }.fetch("status")
    active = @store.published_snapshot(@id)
    assert_equal version, active.fetch("id")
    feed = @outputs.feed
    assert_includes feed, "urn:uuid:#{@id}"
    assert_includes feed, "Public article"
    append_title("Private working title", 1)
    assert_equal feed, @outputs.feed
    @jobs.repair
    assert_equal 1, @store.publication_stages(@id, version).find { |stage| stage["stage"] == "search" }.fetch("attempts")
    @process.failure = false
    finished = @jobs.run(@id, version, retry_now: true)
    assert(finished.fetch("stages").all? { |stage| stage.fetch("status") == "completed" })
    assert_equal feed, @outputs.feed
    assert_equal active, @store.published_snapshot(@id)
    assert_equal(["Public article"], @outputs.search(query: "Public", limit: 10).results.map { |entry| entry.fetch("title") })
    assert_empty @outputs.search(query: "Private", limit: 10).results
    assert_empty @database.pending_webmention_outbox
  end

  private

  def append_title(title, revision)
    @store.append(@id, { "protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid,
      "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "title" => { "value" => title, "expected_revision" => revision } }, })
  end
end
