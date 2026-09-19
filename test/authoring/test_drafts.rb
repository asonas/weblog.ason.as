# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"
require "weblog_authoring/draft_store"

class DraftsTest < Minitest::Test
  ID = "dc802ad0-b899-46ae-b6b7-623c2ba7bc79"

  def setup
    @root = Pathname(Dir.mktmpdir("drafts-test"))
    @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("public.sqlite3"), content_dir: @root.join("content"))
    @database.setup!
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    @cookie = @codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf" }, ttl: 3600)
    @api = WeblogAuthoring::LambdaApi.new(database: @database, draft_store: @store, session_codec: @codec, allowed_github_user_id: 630_181)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_durable_updates_can_be_reopened_without_publishing
    response = call("PUT", "", { "protocol" => 1, "generation" => 1 })
    assert_equal 200, response[:statusCode]
    assert_equal 0, JSON.parse(response[:body]).fetch("head")
    update = { "protocol" => 1, "generation" => 1, "update_id" => "u1", "data" => "AAA=",
               "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
               "metadata" => { "title" => { "value" => "まだ下書き", "expected_revision" => 0 } }, }
    receipt = call("POST", "/updates", update)
    assert_equal 200, receipt[:statusCode]
    assert_equal JSON.parse(receipt[:body]), JSON.parse(call("POST", "/updates", update)[:body])

    reopened = JSON.parse(call("GET")[:body])
    assert_equal 1, reopened.fetch("head")
    assert_equal "まだ下書き", reopened.dig("metadata", "title", "value")
    assert_equal(["AAA="], reopened.fetch("updates").map { |item| item.fetch("data") })
    assert_equal "private, no-store", call("GET")[:headers].fetch("cache-control")
    assert_empty @database.list_pages
    assert_empty @database.pending_webmention_outbox

    changed = update.merge("data" => "AAE=", "digest" => Digest::SHA256.hexdigest("\0\1"))
    assert_equal 409, call("POST", "/updates", changed)[:statusCode]
    assert_equal 1, JSON.parse(call("GET")[:body]).fetch("head")
  end

  def test_drafts_require_authentication_and_csrf_and_are_disabled_by_default
    assert_equal 401, call("GET", authenticated: false)[:statusCode]
    assert_equal "private, no-store", call("GET", authenticated: false)[:headers]["cache-control"]
    assert_equal 403, call("PUT", "", { "protocol" => 1, "generation" => 1 }, csrf: "wrong")[:statusCode]
    @api = WeblogAuthoring::LambdaApi.new(database: @database, session_codec: @codec, allowed_github_user_id: 630_181)
    assert_equal 404, call("PUT", "", { "protocol" => 1, "generation" => 1 })[:statusCode]
  end

  def test_complete_binary_update_survives_storage_chunk_boundaries
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    binary = (0..255).to_a.pack("C*") * 1025
    update = { "protocol" => 1, "generation" => 1, "update_id" => "chunked", "data" => Base64.strict_encode64(binary),
               "digest" => Digest::SHA256.hexdigest(binary), "body_bytes" => 0, }
    assert_equal 200, call("POST", "/updates", update)[:statusCode]
    page = JSON.parse(call("GET")[:body])
    assert_equal binary, Base64.strict_decode64(page.fetch("updates").first.fetch("data"))
    assert_equal 1, page.fetch("cursor")
  end

  def test_catchup_stays_at_its_fixed_high_water_and_metadata_conflicts_do_not_consume_a_sequence
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    update = { "protocol" => 1, "generation" => 1, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0 }
    assert_equal 200, call("POST", "/updates", update.merge("update_id" => "one"))[:statusCode]
    assert_equal 200, call("POST", "/updates", update.merge("update_id" => "two"))[:statusCode]
    first = JSON.parse(call("GET")[:body])
    assert_equal [1, 2], first.values_at("cursor", "through")
    assert_equal 200, call("POST", "/updates", update.merge("update_id" => "three"))[:statusCode]
    next_page = JSON.parse(call("GET", query: { "cursor" => "1", "through" => "2" })[:body])
    assert_equal [2, 2], next_page.values_at("cursor", "through")
    conflict = update.merge("update_id" => "conflict", "metadata" => { "title" => { "value" => "stale", "expected_revision" => 5 } })
    assert_equal 409, call("POST", "/updates", conflict)[:statusCode]
    assert_equal 3, JSON.parse(call("GET")[:body]).fetch("head")
    assert_equal 422, call("POST", "/updates", update.merge("update_id" => "large", "body_bytes" => 524_289))[:statusCode]
  end

  private

  def call(method, suffix = "", body = nil, authenticated: true, csrf: "csrf", query: {})
    @api.call({ "rawPath" => "/api/authoring/drafts/#{ID}#{suffix}",
                "requestContext" => { "http" => { "method" => method } },
                "headers" => { "content-type" => "application/json", "x-csrf-token" => csrf },
                "cookies" => authenticated ? ["weblog_authoring_session=#{@cookie}"] : [],
                "queryStringParameters" => query, "body" => body && JSON.generate(body), })
  end
end
