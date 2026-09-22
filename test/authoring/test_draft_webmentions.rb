# frozen_string_literal: true

require_relative "../test_helper"
require "aws-sdk-sqs"
require "weblog_authoring/draft_publication"
require "weblog_authoring/draft_publisher"
require "weblog_authoring/development_database"
require "weblog_authoring/local_publication_objects"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"
require "weblog_authoring/webmention_fetcher"
require "weblog_authoring/webmention_receiver"
require "weblog_authoring/draft_reader"

class DraftWebmentionsTest < Minitest::Test
  ID = "d33af6a1-5b55-4a44-8b61-95a3847167b1"
  SCOPE = { "protocol" => 1, "generation" => 1 }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("draft-webmentions"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @store.create(ID, SCOPE)
    @store.append(ID, SCOPE.merge("update_id" => "title", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 2,
      "metadata" => { "title" => { "value" => "Article", "expected_revision" => 0 } }))
    @body = "[One](https://one.example/post)"
    @publication = WeblogAuthoring::DraftPublication.new(store: @store) do |job|
      { "article_id" => ID, "protocol" => 1, "generation" => 1, "through" => job.fetch("through"), "markdown" => @body }
    end
    @sqs = Aws::SQS::Client.new(stub_responses: true)
    @service = WeblogAuthoring::DraftWebmentions.new(store: @store, sqs_client: @sqs, queue_url: "https://sqs.ap-northeast-1.amazonaws.com/123456789012/mentions.fifo", site_url: "https://example.com", enabled: true)
    @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("mentions.sqlite3"), content_dir: @root.join("content"))
    @database.setup!
    @objects = WeblogAuthoring::LocalPublicationObjects.new(@root.join("objects"))
    @objects.put_object(bucket: "site", key: "index.html", body: '<html><head></head><body><div id="authoring-root"></div></body></html>')
    @publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database: @database, s3_client: @objects, site_bucket: "site", site_url: "https://example.com")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_first_publication_sends_once_and_updates_require_explicit_new_link_sending
    version = accept
    assert_empty @store.webmention_requests(ID)
    @publisher.run(ID, version)
    @service.dispatch
    assert_equal(["https://one.example/post"], deliveries.map { |job| job.fetch("target") })
    @service.dispatch
    assert_equal 1, deliveries.size

    @body += "\n[Two](https://two.example/post#heading)\n[Local](https://example.com/other)"
    updated = publish
    @service.dispatch
    assert_equal 1, deliveries.size
    assert_equal ["https://two.example/post"], @service.status(ID).fetch("targets")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @service.send_new(ID, version) }.status
    @service.send_new(ID, updated)
    @service.send_new(ID, updated)
    assert_equal(["https://one.example/post", "https://two.example/post"], deliveries.map { |job| job.fetch("target") })
    assert_empty @service.status(ID).fetch("targets")
    @body = "No links remain."
    publish
    @service.dispatch
    assert_equal 2, deliveries.size
  end

  def test_delivery_queue_failure_is_retryable_after_publication_without_duplicate_requests
    publish
    @sqs.stub_responses(:send_message, "ServiceUnavailable")
    assert_raises(Aws::SQS::Errors::ServiceUnavailable) { @service.dispatch }
    assert_equal "pending", @store.webmention_requests(ID).first.fetch("status")
    assert @store.published_snapshot(ID)
    @sqs.stub_responses(:send_message, {})
    @service.dispatch
    assert_equal "queued", @store.webmention_requests(ID).first.fetch("status")
    assert_equal deliveries.first.fetch("delivery_id"), deliveries.last.fetch("delivery_id")
  end

  def test_approval_and_revocation_update_existing_public_html_without_publishing_or_sending
    publish
    snapshot = @store.published_snapshot(ID)
    job = { "job_id" => "received", "source" => "https://reader.example/post", "target" => "https://example.com/Article", "target_page_id" => ID, "received_at" => Time.now.iso8601 }
    response = WeblogAuthoring::WebmentionFetcher::Response.new(url: job.fetch("source"), status: 200, content_type: "text/html", link_header: nil, body: "<p>Source</p>", redirect_count: 0, duration_ms: 10)
    @database.record_verified_webmention(job:, response:, title: "Reader title", site_name: "Reader", content_hash: "content")
    mention = @database.list_webmentions.first
    refute_includes @publisher.read_with_webmentions(snapshot), "Reader title"
    @database.moderate_webmention(id: mention.fetch("id"), decision: "approved")
    assert_includes @publisher.read_with_webmentions(snapshot), "Reader title"
    @database.moderate_webmention(id: mention.fetch("id"), decision: "pending")
    refute_includes @publisher.read_with_webmentions(snapshot), "Reader title"
    assert_equal snapshot, @store.published_snapshot(ID)
    assert_empty deliveries
  end

  def test_manual_api_requires_authentication_csrf_and_the_saved_public_version
    publish
    @body += "\n[Two](https://two.example/post)"
    version = publish
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    cookie = codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf" }, ttl: 3600)
    api = WeblogAuthoring::LambdaApi.new(database: @database, draft_store: @store, draft_webmentions: @service, session_codec: codec, allowed_github_user_id: 630_181)
    event = { "rawPath" => "/api/authoring/drafts/#{ID}/webmentions", "requestContext" => { "http" => { "method" => "POST" } },
      "headers" => { "x-csrf-token" => "csrf", "content-type" => "application/json" }, "body" => JSON.generate("version_id" => version), }
    assert_equal 401, api.call(event).fetch(:statusCode)
    event["cookies"] = ["weblog_authoring_session=#{cookie}"]
    assert_equal 403, api.call(event.merge("headers" => {})).fetch(:statusCode)
    assert_empty deliveries
    assert_equal 202, api.call(event).fetch(:statusCode)
    assert_equal 2, deliveries.size
  end

  def test_receiver_accepts_a_newly_published_draft_without_a_legacy_page
    resolver = Object.new
    def resolver.getaddresses(_host) = ["8.8.8.8"]
    reader = WeblogAuthoring::DraftReader.new(store: @store, database: @database)
    receiver = WeblogAuthoring::WebmentionReceiver.new(database: reader, sqs_client: @sqs,
      queue_url: "https://sqs.ap-northeast-1.amazonaws.com/123456789012/mentions.fifo", site_url: "https://example.com", resolver:)
    event = { "headers" => { "content-type" => "application/x-www-form-urlencoded" },
      "body" => URI.encode_www_form("source" => "https://reader.example/post", "target" => "https://example.com/Article"), }
    assert_equal 400, receiver.call(event).fetch(:statusCode)
    publish
    assert_nil @database.find(ID)
    assert_equal 202, receiver.call(event).fetch(:statusCode)
    assert_equal ID, deliveries.last.fetch("target_page_id")
  end

  private

  def accept
    @publication.accept(ID, @publication.prepare(ID).merge("request_id" => SecureRandom.uuid)).fetch("id")
  end

  def publish
    version = accept
    @publisher.run(ID, version)
    version
  end

  def deliveries
    @sqs.api_requests.select { |request| request.fetch(:operation_name) == :send_message }.map { |request| JSON.parse(request.fetch(:params).fetch(:message_body)) }
  end
end
