# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_administration"
require "weblog_authoring/draft_publication"
require "weblog_authoring/development_database"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"

class DraftAdministrationTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("draft-administration"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    @admin = WeblogAuthoring::DraftAdministration.new(store: @store, publication: @publication)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_daily_reopens_real_work_and_returning_metadata_to_public_hash_clears_changes
    first = @admin.daily("2026-09-20")
    id = first.fetch("id")
    assert_equal "[[日曜日]] [[202609]] [[0920]] [[日記]]", first.fetch("initial_body")
    assert_equal first, @admin.daily("2026-09-20")
    assert_equal "date", @store.read(id, {}).dig("metadata", "page_type", "value")
    assert_equal "draft", @admin.list.fetch("articles").first.fetch("state")
    accepted = @publication.accept(id, @publication.prepare(id).merge("request_id" => "publish"))
    @publication.complete(id, accepted.fetch("id")) { "daily.html" }
    assert_equal "public", @admin.list.fetch("articles").first.fetch("state")
    change_cover(id, "none", 0)
    assert_equal "unpublished_changes", @admin.list.fetch("articles").first.fetch("state")
    change_cover(id, "auto", 1)
    row = @admin.list(query: "09-20").fetch("articles").first
    assert_equal "public", row.fetch("state")
    assert_equal "completed", row.fetch("publication").fetch("status")
    assert_empty @admin.list(query: "not-found").fetch("articles")
    assert_equal first, @admin.daily("2026-09-20")
  end

  def test_listing_is_bounded_and_search_scans_later_pages
    26.times { |index| @admin.daily((Date.new(2026, 1, 1) + index).iso8601) }
    first = @admin.list
    assert_equal 25, first.fetch("articles").length
    last = @admin.list(cursor: first.fetch("cursor"))
    assert_equal 1, last.fetch("articles").length
    assert_nil last.fetch("cursor")
    title = last.fetch("articles").first.dig("metadata", "title")
    filtered = @admin.list(query: title)
    assert_equal title, filtered.fetch("articles").first.dig("metadata", "title")
    assert_nil filtered.fetch("cursor")
  end

  def test_listing_batches_published_content_reconstruction
    ids = 2.times.map do |index|
      result = @admin.daily("2026-09-#{20 + index}")
      id = result.fetch("id")
      accepted = @publication.accept(id, @publication.prepare(id).merge("request_id" => "publish-#{index}"))
      @publication.complete(id, accepted.fetch("id")) { "#{id}.html" }
      id
    end
    calls = []
    @publication.define_singleton_method(:working_content_hashes) do |requested|
      calls << requested
      requested.to_h { |id| [id, working_content_hash(id)] }
    end

    rows = @admin.list.fetch("articles")

    assert_equal [ids.reverse], calls
    assert_equal %w[public public], (rows.map { |row| row.fetch("state") })
  end

  def test_listing_remains_available_when_reconstruction_is_throttled
    id = @admin.daily("2026-09-20").fetch("id")
    accepted = @publication.accept(id, @publication.prepare(id).merge("request_id" => "publish"))
    @publication.complete(id, accepted.fetch("id")) { "daily.html" }
    @publication.define_singleton_method(:working_content_hashes) { |_ids| raise WeblogAuthoring::DraftStore::Error.new("公開版の復元に失敗しました。", 503) }

    row = @admin.list.fetch("articles").first

    assert_equal "unknown", row.fetch("state")
    assert_equal "公開版の復元に失敗しました。", row.fetch("state_error")
  end

  def test_listing_rejects_an_invalid_cursor
    assert_raises(WeblogAuthoring::DraftStore::Error) { @admin.list(cursor: "not-a-cursor") }
  end

  def test_daily_reuses_an_existing_date_article_and_rejects_invalid_dates
    id = SecureRandom.uuid
    @store.create(id, { "protocol" => 1, "generation" => 1 })
    @store.append(id, { "protocol" => 1, "generation" => 1, "update_id" => "date", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "title" => { "value" => "2026-09-20", "expected_revision" => 0 }, "page_type" => { "value" => "date", "expected_revision" => 0 },
                      "page_date" => { "value" => "2026-09-20", "expected_revision" => 0 }, }, })
    assert_equal id, @admin.daily("2026-09-20").fetch("id")
    assert_raises(WeblogAuthoring::DraftStore::Error) { @admin.daily("2026-02-30") }
    assert_raises(WeblogAuthoring::DraftStore::Error) { @admin.daily(nil) }
  end

  def test_list_and_daily_endpoints_are_private_authenticated_and_csrf_protected
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("public.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    cookie = codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf" }, ttl: 3600)
    api = WeblogAuthoring::LambdaApi.new(database:, draft_store: @store, draft_publication: @publication, session_codec: codec, allowed_github_user_id: 630_181)
    event = { "rawPath" => "/api/authoring/drafts", "requestContext" => { "http" => { "method" => "GET" } } }
    assert_equal 401, api.call(event)[:statusCode]
    event["cookies"] = ["#{WeblogAuthoring::LambdaApi::AUTH_COOKIE}=#{cookie}"]
    response = api.call(event)
    assert_equal 200, response[:statusCode]
    assert_equal "private, no-store", response[:headers].fetch("cache-control")
    event["rawPath"] += "/daily"
    event["requestContext"]["http"]["method"] = "POST"
    event["body"] = JSON.generate("date" => "2026-09-20")
    assert_equal 403, api.call(event)[:statusCode]
    event["headers"] = { "x-csrf-token" => "csrf", "content-type" => "application/json" }
    assert_equal 200, api.call(event)[:statusCode]
    assert_equal 1, @admin.list.fetch("articles").length
  end

  def test_renamed_unpublished_diary_does_not_capture_the_original_date
    first = @admin.daily("2026-09-20").fetch("id")
    @store.append(first, { "protocol" => 1, "generation" => 1, "update_id" => "rename-date", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "title" => { "value" => "2026-09-21", "expected_revision" => 0 },
                      "page_date" => { "value" => "2026-09-21", "expected_revision" => 0 }, }, })
    second = @admin.daily("2026-09-20").fetch("id")
    refute_equal first, second
    assert_equal "2026-09-20", @store.read(second, {}).dig("metadata", "title", "value")
    assert_equal first, @admin.daily("2026-09-21").fetch("id")
    assert_equal second, @admin.daily("2026-09-20").fetch("id")
  end

  def test_renamed_published_diary_redirect_does_not_reopen_as_the_daily_entry
    original = @admin.daily("2026-09-22").fetch("id")
    first = @publication.accept(original, @publication.prepare(original).merge("request_id" => "publish-diary"))
    @publication.complete(original, first.fetch("id")) { "daily.html" }
    @store.append(original, { "protocol" => 1, "generation" => 1, "update_id" => "convert-to-article", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => {
        "title" => { "value" => "テストの記事です。", "expected_revision" => 0 },
        "page_type" => { "value" => "named", "expected_revision" => 0 },
        "page_date" => { "value" => "", "expected_revision" => 0 },
      }, })
    renamed = @publication.prepare(original)
    second = @publication.accept(original, renamed.merge("request_id" => "publish-article"))
    @publication.complete(original, second.fetch("id")) { "article.html" }

    new_daily = @admin.daily("2026-09-22")
    metadata = @store.read(new_daily.fetch("id"), {}).fetch("metadata")

    refute_equal original, new_daily.fetch("id")
    assert_equal "2026-09-22", metadata.dig("title", "value")
    assert_equal "date", metadata.dig("page_type", "value")
  end

  private

  def change_cover(id, value, revision)
    @store.append(id, { "protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "cover_mode" => { "value" => value, "expected_revision" => revision } }, })
  end
end
