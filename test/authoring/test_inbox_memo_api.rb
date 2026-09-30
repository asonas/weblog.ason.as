# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"
require "weblog_authoring/development_app"
require "rack/mock"

class InboxMemoApiTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("inbox-memo-api"))
    @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("authoring.sqlite3"), content_dir: @root.join("content"))
    @database.setup!
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    @api = WeblogAuthoring::LambdaApi.new(database: @database, draft_store: @store, session_codec: @codec, allowed_github_user_id: 1)
    @cookie = "weblog_authoring_session=#{@codec.issue(kind: 'session', attributes: { 'github_user_id' => 1, 'csrf_token' => 'csrf' }, ttl: 600)}"
    pairing = WeblogAuthoring::MobileUpload.new(database: @database)
    @credentials = pairing.exchange_pairing(code: pairing.issue_pairing.fetch("code"), device_name: "Phone")
    @id = SecureRandom.uuid
    @payload = { "operation_id" => SecureRandom.uuid, "expected_revision" => 0, "body" => "[[日記のネタ]]" }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_web_requires_login_and_csrf_and_never_caches_memos
    assert_equal 401, call("GET", "/api/inbox/memos").fetch(:statusCode)
    assert_equal 403, call("PUT", "/api/inbox/memos/#{@id}", cookies: [@cookie]).fetch(:statusCode)
    saved = call("PUT", "/api/inbox/memos/#{@id}", cookies: [@cookie], headers: { "x-csrf-token" => "csrf" })
    assert_equal 200, saved.fetch(:statusCode)
    listed = call("GET", "/api/inbox/memos", cookies: [@cookie])
    assert_equal "no-store", listed.fetch(:headers).fetch("cache-control")
    assert_equal ["[[日記のネタ]]"], JSON.parse(listed.fetch(:body)).fetch("memos").map { |memo| memo.fetch("body") }
  end

  def test_paired_phone_can_edit_memos_but_cannot_edit_drafts_or_use_revoked_credentials
    path = "/api/mobile/memos/#{@id}"
    assert_equal 401, call("PUT", path).fetch(:statusCode)
    headers = { "authorization" => "Bearer #{@credentials.fetch('token')}" }
    assert_equal 200, call("PUT", path, headers:).fetch(:statusCode)
    assert_equal "[[日記のネタ]]", JSON.parse(call("GET", path, headers:).fetch(:body)).fetch("body")
    assert_equal 401, call("PUT", "/api/authoring/drafts/#{@id}", headers:).fetch(:statusCode)
    @database.revoke_mobile_device(@credentials.fetch("device").fetch("id"))
    assert_equal 401, call("GET", path, headers:).fetch(:statusCode)
  end

  def test_development_routes_share_memos_between_web_and_paired_phone
    app = WeblogAuthoring::DevelopmentApp.application(root: @root, drafts_enabled: true, inbox_sources: {}, s3_client: Aws::S3::Client.new(stub_responses: true))
    request = Rack::MockRequest.new(app)
    response = request.put("http://127.0.0.1/api/inbox/memos/#{@id}", "CONTENT_TYPE" => "application/json", input: JSON.generate(@payload))
    assert_equal 200, response.status, response.body
    assert_equal 401, request.get("http://127.0.0.1/api/mobile/memos").status
    issued = request.post("http://127.0.0.1/api/mobile/pairings", "CONTENT_TYPE" => "application/json", input: "{}")
    code = JSON.parse(issued.body).fetch("code")
    exchanged = request.post("http://127.0.0.1/api/mobile/pairings/exchange", "CONTENT_TYPE" => "application/json", input: JSON.generate(code:, device_name: "Phone"))
    token = JSON.parse(exchanged.body).fetch("token")
    listed = request.get("http://127.0.0.1/api/mobile/memos", "HTTP_AUTHORIZATION" => "Bearer #{token}")
    assert_equal 200, listed.status, listed.body
    assert_equal "private, no-store", listed.headers.fetch("cache-control")
    assert_equal @id, JSON.parse(listed.body).fetch("memos").first.fetch("id")
  end

  private

  def call(method, path, cookies: [], headers: {})
    @api.call({ "rawPath" => path, "requestContext" => { "http" => { "method" => method } },
                "headers" => { "content-type" => "application/json" }.merge(headers), "cookies" => cookies, "body" => JSON.generate(@payload) })
  end
end
