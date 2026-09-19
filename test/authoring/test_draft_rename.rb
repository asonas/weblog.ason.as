# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_jobs"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_api"

class DraftRenameTest < Minitest::Test
  class Storage < WeblogAuthoring::LocalPublicationObjects
    attr_accessor :writes_before_failure

    def put_object(**params)
      if writes_before_failure
        raise IOError, "placement unavailable" if writes_before_failure.zero?
        self.writes_before_failure -= 1
      end
      super
    end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("draft-rename"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    @database.setup!
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    @objects = Storage.new(@root.join("objects"))
    @objects.put_object(bucket: "site", key: "index.html", body: '<html><head></head><body><div id="authoring-root"></div></body></html>')
    @publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database: @database, s3_client: @objects, site_bucket: "site", site_url: "https://example.com")
    @api = WeblogAuthoring::LambdaApi.new(database: @database, draft_store: @store, draft_publication: @publication, draft_publisher: @publisher)
    @target = create("Old", "target body")
    @reference = create("Reference", "Published [[Old]]")
    publish(@target)
    publish(@reference)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_batch_keeps_old_reader_content_on_partial_failure_and_preserves_private_work
    before = @store.published_snapshot(@reference)
    target_before = @store.published_snapshot(@target)
    feed_before = feed
    title(@target, "New", 1)
    title(@reference, "Private title", 1)
    append_text(@reference, " private unfinished text")
    working = @store.read(@reference, {})
    confirmation = @publication.prepare(@target)
    assert_equal([@reference], confirmation.fetch("rename").fetch("references").map { |entry| entry.fetch("article_id") })
    assert_equal 200, reader("Old").fetch(:statusCode)
    assert_equal 404, reader("New").fetch(:statusCode)
    request = confirmation.merge("request_id" => "rename")
    batch = @publication.accept(@target, request).fetch("id")
    @objects.writes_before_failure = 1
    assert_raises(IOError) { @publisher.run(@target, batch) }
    assert_equal(1, @store.rename_members(batch).count { |member| member["html_key"] })
    assert_equal 200, reader("Old").fetch(:statusCode)
    assert_equal 404, reader("New").fetch(:statusCode)
    assert_includes reader("Reference").fetch(:body), "Old"
    @objects.writes_before_failure = nil
    assert_equal "completed", @publisher.run(@target, batch).fetch("status")
    assert_equal 301, reader("Old").fetch(:statusCode)
    assert_equal "/New", URI::DEFAULT_PARSER.unescape(reader("Old").fetch(:headers).fetch("location"))
    assert_equal 200, reader("New").fetch(:statusCode)
    assert_includes reader("Reference").fetch(:body), "New"
    refute_includes reader("Reference").fetch(:body), "Private title"
    assert_equal "Published [[New]]", @store.published_snapshot(@reference).fetch("body")
    assert_equal before.fetch("updated_at"), @store.published_snapshot(@reference).fetch("updated_at")
    refute_equal target_before.fetch("updated_at"), @store.published_snapshot(@target).fetch("updated_at")
    assert_equal target_before.fetch("published_at"), @store.published_snapshot(@target).fetch("published_at")
    assert_includes feed_before, "<id>urn:uuid:#{@target}</id>"
    assert_includes feed, "<id>urn:uuid:#{@target}</id>"
    assert_equal working, @store.read(@reference, {})
    assert_equal batch, @publication.accept(@target, request).fetch("id")
    assert_empty @database.pending_webmention_outbox
    @store.cleanup_publication_stages(now: Time.now.utc + (31 * 86400))
    assert_equal 301, reader("Old").fetch(:statusCode)
  end

  def test_working_route_reservations_conflict_without_changing_public_routes
    title(@target, "Reserved", 1)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { title(@reference, "Reserved", 1) }.status
    assert_equal "Reference", @store.read(@reference, {}).dig("metadata", "title", "value")
    assert_equal 200, reader("Old").fetch(:statusCode)
    assert_equal 404, reader("Reserved").fetch(:statusCode)
    title(@target, "Other", 2)
    title(@reference, "Reserved", 1)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { title(@reference, "Old", 2) }.status
  end

  def test_changed_public_references_require_reconfirmation_and_supersede_staged_batches
    title(@target, "New", 1)
    stale = @publication.prepare(@target).merge("request_id" => "stale")
    append_text(@reference, " first public addition")
    publish(@reference)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @publication.accept(@target, stale) }.status
    batch = @publication.accept(@target, @publication.prepare(@target).merge("request_id" => "batch")).fetch("id")
    append_text(@reference, " newer public addition")
    publish(@reference)
    newer = @store.published_snapshot(@reference)
    assert_equal "superseded", @publisher.run(@target, batch).fetch("status")
    assert_equal newer, @store.published_snapshot(@reference)
    assert_equal 200, reader("Old").fetch(:statusCode)
    assert_equal 404, reader("New").fetch(:statusCode)
    publish(@target)
    assert_includes reader("Reference").fetch(:body), "newer public addition"
    assert_equal 301, reader("Old").fetch(:statusCode)
  end

  private

  def feed
    outputs = WeblogAuthoring::DraftOutputs.new(store: @store, s3_client: @objects, bucket: "site", site_url: "https://example.com")
    artifact = outputs.build("atom")
    @objects.get_object(bucket: "site", key: artifact.fetch("object_key")).body.read
  end

  def append_text(id, body)
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", "history", "text", body)
    assert status.success?, error
    @store.append(id, JSON.parse(output).first.merge("protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid, "body_bytes" => body.bytesize))
  end

  def create(name, body)
    id = SecureRandom.uuid
    @store.create(id, { "protocol" => 1, "generation" => 1 })
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", "history", "text", body)
    assert status.success?, error
    update = JSON.parse(output).first
    @store.append(id, update.merge("protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid, "body_bytes" => body.bytesize,
      "metadata" => { "title" => { "value" => name, "expected_revision" => 0 } }))
    id
  end

  def title(id, value, revision)
    @store.append(id, { "protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "title" => { "value" => value, "expected_revision" => revision } }, })
  end

  def publish(id)
    accepted = @publication.accept(id, @publication.prepare(id).merge("request_id" => SecureRandom.uuid))
    @publisher.run(id, accepted.fetch("id"))
  end

  def reader(route)
    @api.call({ "requestContext" => { "http" => { "method" => "GET" } }, "rawPath" => "/#{route}" })
  end
end
