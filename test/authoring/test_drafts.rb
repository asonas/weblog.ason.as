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
    receipt = upload(update)
    assert_equal 200, receipt[:statusCode]
    assert_equal JSON.parse(receipt[:body]), JSON.parse(upload(update)[:body])

    reopened = JSON.parse(call("GET")[:body])
    assert_equal 1, reopened.fetch("head")
    assert_equal "まだ下書き", reopened.dig("metadata", "title", "value")
    assert_equal(["AAA="], reopened.fetch("updates").map { |item| item.fetch("data") })
    assert_equal "private, no-store", call("GET")[:headers].fetch("cache-control")
    assert_empty @database.list_pages
    assert_empty @database.pending_webmention_outbox

    changed = update.merge("data" => "AAE=", "digest" => Digest::SHA256.hexdigest("\0\1"))
    assert_equal 409, upload(changed)[:statusCode]
    assert_equal 1, JSON.parse(call("GET")[:body]).fetch("head")
  end

  def test_diary_title_and_date_route_cannot_diverge
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    update = { "protocol" => 1, "generation" => 1, "update_id" => "divergent-diary", "data" => "AAA=",
               "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
               "metadata" => {
                 "title" => { "value" => "日付とは別のタイトル", "expected_revision" => 0 },
                 "page_type" => { "value" => "date", "expected_revision" => 0 },
                 "page_date" => { "value" => "2026-09-22", "expected_revision" => 0 },
               }, }

    assert_equal 422, upload(update)[:statusCode]
    assert_equal 0, JSON.parse(call("GET")[:body]).fetch("head")
  end

  def test_drafts_require_authentication_and_csrf_and_are_disabled_by_default
    assert_equal 401, call("GET", authenticated: false)[:statusCode]
    assert_equal "private, no-store", call("GET", authenticated: false)[:headers]["cache-control"]
    assert_equal 403, call("PUT", "", { "protocol" => 1, "generation" => 1 }, csrf: "wrong")[:statusCode]
    @api = WeblogAuthoring::LambdaApi.new(database: @database, session_codec: @codec, allowed_github_user_id: 630_181)
    assert_equal 404, call("PUT", "", { "protocol" => 1, "generation" => 1 })[:statusCode]
  end

  def test_legacy_article_identity_survives_draft_storage_and_reopening
    @article_id = "dc802ad0b89946aeb6b7623c2ba7bc79"
    assert_equal 200, call("PUT", "", { "protocol" => 1, "generation" => 1 })[:statusCode]
    update = { "protocol" => 1, "generation" => 1, "update_id" => "legacy-edit", "data" => "AAA=",
               "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
               "metadata" => { "title" => { "value" => "移行した記事", "expected_revision" => 0 } }, }
    assert_equal 200, upload(update)[:statusCode]
    reopened = JSON.parse(call("GET")[:body])
    assert_equal @article_id, reopened.fetch("id")
    assert_equal "移行した記事", reopened.dig("metadata", "title", "value")
    assert_equal 1, reopened.fetch("head")
  end

  def test_complete_binary_update_survives_storage_chunk_boundaries
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    binary = (0..255).to_a.pack("C*") * 1025
    update = { "protocol" => 1, "generation" => 1, "update_id" => "chunked", "data" => Base64.strict_encode64(binary),
               "digest" => Digest::SHA256.hexdigest(binary), "body_bytes" => 0, }
    assert_equal 200, upload(update)[:statusCode]
    page = JSON.parse(call("GET")[:body])
    assert_equal binary, Base64.strict_decode64(page.fetch("updates").first.fetch("data"))
    assert_equal 1, page.fetch("cursor")
  end

  def test_chunked_upload_is_immutable_and_only_commits_when_complete
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    binary = (0..255).to_a.pack("C*") * 1_200
    parts = binary.bytes.each_slice(WeblogAuthoring::DraftStore::TRANSPORT_CHUNK_BYTES).map { |bytes| bytes.pack("C*") }
    manifest = { "protocol" => 1, "generation" => 1, "update_id" => "chunked-upload",
                 "digest" => Digest::SHA256.hexdigest(binary), "body_bytes" => 0,
                 "metadata" => {}, "chunks" => parts.length, }
    assert_equal 200, call("POST", "/uploads", manifest)[:statusCode]
    first = { "protocol" => 1, "generation" => 1, "data" => Base64.strict_encode64(parts[0]),
              "digest" => Digest::SHA256.hexdigest(parts[0]), }
    assert_equal 200, call("PUT", "/uploads/chunked-upload/chunks/0", first)[:statusCode]
    assert_equal 409, call("POST", "/uploads/chunked-upload/commit", { "protocol" => 1, "generation" => 1 })[:statusCode]
    assert_equal 0, JSON.parse(call("GET")[:body]).fetch("head")
    assert_equal 200, call("PUT", "/uploads/chunked-upload/chunks/0", first)[:statusCode]
    changed = first.merge("data" => Base64.strict_encode64("changed"), "digest" => Digest::SHA256.hexdigest("changed"))
    assert_equal 409, call("PUT", "/uploads/chunked-upload/chunks/0", changed)[:statusCode]
    parts.drop(1).each_with_index do |part, index|
      chunk = { "protocol" => 1, "generation" => 1, "data" => Base64.strict_encode64(part),
                "digest" => Digest::SHA256.hexdigest(part), }
      assert_equal 200, call("PUT", "/uploads/chunked-upload/chunks/#{index + 1}", chunk)[:statusCode]
    end
    receipt = call("POST", "/uploads/chunked-upload/commit", { "protocol" => 1, "generation" => 1 })
    assert_equal 200, receipt[:statusCode]
    assert_equal JSON.parse(receipt[:body]), JSON.parse(call("POST", "/uploads/chunked-upload/commit", { "protocol" => 1, "generation" => 1 })[:body])
    page = JSON.parse(call("GET")[:body])
    assert_equal 1, page.fetch("head")
    assert_equal binary, Base64.strict_decode64(page.fetch("updates").first.fetch("data"))
  end

  def test_catchup_stays_at_its_fixed_high_water_and_metadata_conflicts_do_not_consume_a_sequence
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    update = { "protocol" => 1, "generation" => 1, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0 }
    assert_equal 200, upload(update.merge("update_id" => "one"))[:statusCode]
    assert_equal 200, upload(update.merge("update_id" => "two"))[:statusCode]
    first = JSON.parse(call("GET")[:body])
    assert_equal [1, 2], first.values_at("cursor", "through")
    assert_equal 200, upload(update.merge("update_id" => "three"))[:statusCode]
    next_page = JSON.parse(call("GET", query: { "cursor" => "1", "through" => "2" })[:body])
    assert_equal [2, 2], next_page.values_at("cursor", "through")
    conflict = update.merge("update_id" => "conflict", "metadata" => { "title" => { "value" => "stale", "expected_revision" => 5 } })
    assert_equal 409, upload(conflict)[:statusCode]
    assert_equal 3, JSON.parse(call("GET")[:body]).fetch("head")
    assert_equal 422, upload(update.merge("update_id" => "large", "body_bytes" => 524_289))[:statusCode]
  end

  def test_checkpoint_is_served_in_bounded_chunks_before_its_suffix
    call("PUT", "", { "protocol" => 1, "generation" => 1 })
    update = { "protocol" => 1, "generation" => 1, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0 }
    upload(update.merge("update_id" => "one"))
    checkpoint_data = (0..255).to_a.pack("C*") * 1025
    checkpoint = { "protocol" => 1, "generation" => 1, "article_id" => ID, "through" => 1,
                   "data" => Base64.strict_encode64(checkpoint_data), "digest" => Digest::SHA256.hexdigest(checkpoint_data), }
    @store.activate_verified_checkpoint(ID, checkpoint, expected_checkpoint: 0)
    upload(update.merge("update_id" => "two"))

    first = JSON.parse(call("GET")[:body])
    assert_equal [0, 2], first.values_at("cursor", "through")
    assert_empty first.fetch("updates")
    assert_equal [1, 2, 0], first.fetch("checkpoint").values_at("through", "chunks", "position")
    second = JSON.parse(call("GET", query: { "through" => "2", "checkpoint_through" => "1", "checkpoint_position" => "1" })[:body])
    assert_equal 1, second.dig("checkpoint", "position")
    rebuilt = [first, second].map { |page| Base64.strict_decode64(page.dig("checkpoint", "data")) }.join
    assert_equal checkpoint_data, rebuilt
    suffix = JSON.parse(call("GET", query: { "cursor" => "1", "through" => "2" })[:body])
    assert_equal [2, 2], suffix.values_at("cursor", "through")
    assert_equal "two", suffix.fetch("updates").first.fetch("update_id")
  end

  private

  def upload(update)
    binary = Base64.strict_decode64(update.fetch("data"))
    parts = binary.bytes.each_slice(WeblogAuthoring::DraftStore::TRANSPORT_CHUNK_BYTES).map { |bytes| bytes.pack("C*") }
    started = call("POST", "/uploads", update.except("data").merge("chunks" => parts.length))
    return started unless started[:statusCode] == 200
    parsed = JSON.parse(started[:body])
    return started if parsed.key?("sequence")

    parts.each_with_index do |part, position|
      chunk = { "protocol" => 1, "generation" => 1, "data" => Base64.strict_encode64(part),
                "digest" => Digest::SHA256.hexdigest(part), }
      response = call("PUT", "/uploads/#{update.fetch("update_id")}/chunks/#{position}", chunk)
      return response unless response[:statusCode] == 200
    end
    call("POST", "/uploads/#{update.fetch("update_id")}/commit", { "protocol" => 1, "generation" => 1 })
  end

  def call(method, suffix = "", body = nil, authenticated: true, csrf: "csrf", query: {})
    @api.call({ "rawPath" => "/api/authoring/drafts/#{@article_id || ID}#{suffix}",
                "requestContext" => { "http" => { "method" => method } },
                "headers" => { "content-type" => "application/json", "x-csrf-token" => csrf },
                "cookies" => authenticated ? ["weblog_authoring_session=#{@cookie}"] : [],
                "queryStringParameters" => query, "body" => body && JSON.generate(body), })
  end
end
