# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "weblog_authoring/draft_store"
require "weblog_authoring/draft_publication"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"
require "weblog_authoring/draft_publisher"

class DraftPublicationTest < Minitest::Test
  ID = "dc802ad0-b899-46ae-b6b7-623c2ba7bc79"
  SCOPE = { "protocol" => 1, "generation" => 1 }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("draft-publication"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @store.create(ID, SCOPE)
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", "history")
    assert status.success?, error
    JSON.parse(output).each_with_index do |update, index|
      metadata = index.zero? ? { "title" => { "value" => "公開する記事", "expected_revision" => 0 } } : {}
      @store.append(ID, SCOPE.merge(update).merge("update_id" => "initial-#{index}", "body_bytes" => 12, "metadata" => metadata))
    end
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_confirmed_snapshot_is_immutable_and_activates_only_after_html_placement
    confirmation = @publication.prepare(ID)
    request = confirmation.merge("request_id" => "publish-one")
    accepted = @publication.accept(ID, request)
    assert_equal "accepted", accepted.fetch("status")
    assert_nil @store.published_snapshot(ID)
    assert_equal accepted, @publication.accept(ID, request)

    append_title("公開後も未公開の編集")
    placed = []
    completed = @publication.complete(ID, accepted.fetch("id")) do |snapshot|
      placed << snapshot
      "published/#{snapshot.fetch('id')}.html"
    end
    assert_equal "completed", completed.fetch("status")
    assert_equal "残す", placed.first.fetch("body")
    assert_equal "公開する記事", @store.published_snapshot(ID).dig("metadata", "title")
    assert_equal @store.read(ID, {}).fetch("created_at"), @store.published_snapshot(ID).fetch("article_created_at")
    assert_equal "unpublished_changes", @publication.prepare(ID).fetch("article_state")
    assert_equal completed, @publication.complete(ID, accepted.fetch("id")) { flunk "Already placed" }
    assert_equal accepted.fetch("id"), @publication.accept(ID, request).fetch("id")
  end

  def test_changed_head_or_confirmation_is_rejected_and_identical_content_is_a_noop
    confirmation = @publication.prepare(ID)
    append_title("まだ確認していないタイトル")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @publication.accept(ID, confirmation.merge("request_id" => "stale"))
    }.status
    fresh = @publication.prepare(ID)
    accepted = @publication.accept(ID, fresh.merge("request_id" => "current"))
    @publication.complete(ID, accepted.fetch("id")) { "published/current.html" }
    active = @store.published_snapshot(ID)
    same = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "same"))
    assert_equal "unchanged", same.fetch("status")
    assert_equal active, @store.published_snapshot(ID)
    assert_equal "public", @publication.prepare(ID).fetch("article_state")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @publication.accept(ID, fresh.merge("request_id" => "current", "content_hash" => "0" * 64))
    }.status
  end

  def test_failed_placement_is_retryable_and_stale_completion_cannot_replace_newer_content
    first = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "first"))
    assert_raises(IOError) { @publication.complete(ID, first.fetch("id")) { raise IOError, "storage unavailable" } }
    assert_nil @store.published_snapshot(ID)
    assert_equal "needs_attention", @store.publication_job(ID, first.fetch("id")).fetch("status")
    @publication.complete(ID, first.fetch("id")) { "published/first.html" }
    first_time = @store.published_snapshot(ID).fetch("published_at")
    # Cover changes are publishable without changing the article route.
    append_cover("none", 0)
    second = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "second"))
    @publication.complete(ID, second.fetch("id")) do
      append_cover("auto", 1)
      third = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "third"))
      @publication.complete(ID, third.fetch("id")) { "published/third.html" }
      "published/second.html"
    end
    active = @store.published_snapshot(ID)
    assert_equal "auto", active.dig("metadata", "cover_mode")
    assert_equal first_time, active.fetch("published_at")
    assert_equal "superseded", @store.publication_job(ID, second.fetch("id")).fetch("status")
  end

  def test_authorized_publication_api_places_html_before_readers_see_the_confirmed_version
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("public.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:get_object, body: '<html><head><title>Site</title></head><body><div id="authoring-root"></div></body></html>')
    publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database:, s3_client: s3, site_bucket: "site", site_url: "https://example.com")
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    cookie = codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf" }, ttl: 3600)
    api = WeblogAuthoring::LambdaApi.new(database:, draft_store: @store, draft_publication: @publication, draft_publisher: publisher, session_codec: codec, allowed_github_user_id: 630_181)
    request = ->(method, path, payload = {}, authenticated = true) do
      api.call({ "requestContext" => { "http" => { "method" => method } }, "rawPath" => path,
        "pathParameters" => { "id" => ID, "route" => "公開する記事" },
        "headers" => { "x-csrf-token" => "csrf", "content-type" => "application/json" }, "cookies" => authenticated ? ["weblog_authoring_session=#{cookie}"] : [], "body" => JSON.generate(payload), })
    end
    base = "/api/authoring/drafts/#{ID}/publications"
    assert_equal 401, request.call("POST", "#{base}/prepare", {}, false)[:statusCode]
    assert_equal 404, request.call("GET", "/api/pages/#{ID}", {}, false)[:statusCode]
    confirmation = JSON.parse(request.call("POST", "#{base}/prepare")[:body])
    accepted = request.call("POST", base, confirmation.merge("request_id" => "api-publication"))
    assert_equal 202, accepted[:statusCode], accepted[:body]
    version = JSON.parse(accepted[:body]).fetch("id")
    assert_equal 404, request.call("GET", "/api/pages/#{ID}", {}, false)[:statusCode]
    assert_equal "accepted", JSON.parse(request.call("GET", "#{base}/#{version}")[:body]).fetch("status")
    completed = request.call("POST", "#{base}/#{version}/run")
    assert_equal "completed", JSON.parse(completed[:body]).fetch("status"), completed[:body]
    placed = s3.api_requests.find { |call| call[:operation_name] == :put_object }.fetch(:params)
    assert_equal "published/#{ID}/#{version}.html", placed.fetch(:key)
    assert_includes placed.fetch(:body), "残す"
    s3.stub_responses(:get_object, body: placed.fetch(:body))
    html_response = request.call("GET", "/公開する記事", {}, false)
    assert_equal 200, html_response[:statusCode]
    assert_equal placed.fetch(:body), html_response[:body]
    append_title("秘密の作業版")
    reader = request.call("GET", "/api/routes/公開する記事", {}, false)
    assert_equal 200, reader[:statusCode], reader[:body]
    assert_includes reader[:body], "残す"
    refute_includes reader[:body], "秘密の作業版"
    assert_empty database.pending_webmention_outbox
    assert_empty database.list_pages
  end

  def test_lost_storage_ack_does_not_overwrite_placed_html_during_retry
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("public.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    s3 = Aws::S3::Client.new(stub_responses: true)
    shell = '<html><head></head><body>original<div id="authoring-root"></div></body></html>'
    objects = {}
    s3.stub_responses(:get_object, ->(context) { { body: context.params[:key] == "index.html" ? shell : objects.fetch(context.params[:key]) } })
    s3.stub_responses(:put_object, lambda do |context|
      key = context.params.fetch(:key)
      if objects.key?(key) && context.params[:if_none_match] == "*"
        raise Aws::S3::Errors::PreconditionFailed.new(context, "already placed")
      end
      objects[key] = context.params.fetch(:body)
      raise IOError, "storage acknowledgement lost"
    end)
    publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database:, s3_client: s3, site_bucket: "site", site_url: "https://example.com")
    version = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "lost-placement")).fetch("id")
    assert_raises(IOError) { publisher.run(ID, version) }
    assert_nil @store.published_snapshot(ID)
    shell = shell.sub("original", "changed-template")
    assert_equal "completed", publisher.run(ID, version).fetch("status")
    html = publisher.read(@store.published_snapshot(ID))
    assert_includes html, "original"
    refute_includes html, "changed-template"
  end

  def test_diary_title_and_date_route_remain_equal_across_publications
    @store.append(ID, SCOPE.merge("update_id" => "diary", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 6,
                                 "metadata" => { "title" => { "value" => "2026-09-20", "expected_revision" => 1 },
                                                 "page_type" => { "value" => "date", "expected_revision" => 0 },
                                                 "page_date" => { "value" => "2026-09-20", "expected_revision" => 0 }, }))
    first = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "diary-first"))
    @publication.complete(ID, first.fetch("id")) { "diary-first.html" }
    page = WeblogAuthoring::DraftPublisher.page(@store.published_snapshot(ID))
    assert_equal "2026-09-20", page.route
    assert_equal "2026-09-20", page.display_title

    @store.append(ID, SCOPE.merge("update_id" => "date-change", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 6,
                                 "metadata" => { "title" => { "value" => "2026-09-21", "expected_revision" => 2 },
                                                 "page_date" => { "value" => "2026-09-21", "expected_revision" => 1 }, }))
    changed = @publication.prepare(ID)
    assert_equal %w[2026-09-20 2026-09-21], changed.fetch("rename").values_at("from", "to")
    assert_equal "2026-09-20", @store.published_snapshot(ID).fetch("route")
  end

  private

  def append_title(title)
    @store.append(ID, SCOPE.merge("update_id" => SecureRandom.uuid, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 6,
      "metadata" => { "title" => { "value" => title, "expected_revision" => 1 } }))
  end

  def append_cover(value, revision)
    @store.append(ID, SCOPE.merge("update_id" => SecureRandom.uuid, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 6,
      "metadata" => { "cover_mode" => { "value" => value, "expected_revision" => revision } }))
  end
end
