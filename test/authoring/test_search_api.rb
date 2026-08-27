# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/lambda_api"
require_relative "../../lib/weblog_authoring/search_index"

require "digest"
require "stringio"

class SearchApiTest < Minitest::Test
  class FakeS3
    ObjectBody = Data.define(:body)

    attr_accessor :manifest, :index

    def initialize(manifest:, index:)
      self.manifest = manifest
      self.index = index
    end

    def get_object(bucket:, key:, response_target: nil)
      body = key == "search/manifest.json" ? manifest : index
      if response_target
        File.binwrite(response_target, body)
        ObjectBody.new(nil)
      else
        ObjectBody.new(StringIO.new(body))
      end
    end
  end

  def test_searches_the_immutable_index_with_title_boost
    index = search_index_fixture
    manifest = JSON.generate(
      "corpus_hash" => "fixture",
      "index_key" => "search/generations/fixture/index.sqlite3",
      "index_sha256" => Digest::SHA256.hexdigest(index),
      "generated_at" => "2026-08-27T12:00:00+09:00"
    )
    Dir.mktmpdir("search-cache-") do |cache_dir|
      log = StringIO.new
      search_index = WeblogAuthoring::SearchIndex.new(
        s3_client: FakeS3.new(manifest:, index:),
        bucket: "site",
        cache_dir:
      )
      api = WeblogAuthoring::LambdaApi.new(
        database: Object.new,
        search_index:,
        logger: log,
        clock: -> { Time.iso8601("2026-08-27T12:01:00+09:00") }
      )

      response = api.call(event(query: { "q" => "全文検索", "limit" => "2" }))
      results = JSON.parse(response.fetch(:body)).fetch("results")

      assert_equal 200, response.fetch(:statusCode)
      assert_equal "private, no-store", response.fetch(:headers).fetch("cache-control")
      assert_equal %w[title-match body-match], results.map { |result| result.fetch("route") }
      assert_equal "全文検索の設計", results.fetch(0).fetch("title")
      assert_includes results.fetch(0).fetch("excerpt"), "本文で全文検索を扱う"
      assert_equal "2026-08-20T12:00:00+09:00", results.fetch(0).fetch("updated_at")
      event = JSON.parse(log.string)
      assert_equal "search_completed", event.fetch("event")
      assert_equal 60, event.fetch("index_age_seconds")
      assert_kind_of Numeric, event.fetch("duration_ms")
      refute_includes log.string, "全文検索"
    end
  end

  def test_searches_a_dotted_title_by_partial_domain
    index = search_index_fixture
    Dir.mktmpdir("search-cache-") do |cache_dir|
      search_index = WeblogAuthoring::SearchIndex.new(
        s3_client: FakeS3.new(manifest: manifest_for("fixture", index), index:),
        bucket: "site",
        cache_dir:
      )
      api = WeblogAuthoring::LambdaApi.new(database: Object.new, search_index:, logger: StringIO.new)

      response = api.call(event(query: { "q" => "weblog.ason" }))

      assert_equal 200, response.fetch(:statusCode)
      results = JSON.parse(response.fetch(:body)).fetch("results")
      assert_equal "weblog.ason.asの書き心地", results.fetch(0).fetch("title")
    end
  end

  def test_keeps_the_loaded_generation_when_a_new_download_is_invalid
    index = search_index_fixture
    s3 = FakeS3.new(manifest: manifest_for("first", index), index:)
    Dir.mktmpdir("search-cache-") do |cache_dir|
      search_index = WeblogAuthoring::SearchIndex.new(s3_client: s3, bucket: "site", cache_dir:)
      api = WeblogAuthoring::LambdaApi.new(database: Object.new, search_index:, logger: StringIO.new)
      first = api.call(event(query: { "q" => "全文検索" }))
      assert_equal 200, first.fetch(:statusCode)

      s3.manifest = JSON.generate(
        "corpus_hash" => "broken",
        "index_key" => "search/generations/broken/index.sqlite3",
        "index_sha256" => "0" * 64
      )
      s3.index = "not a sqlite database"

      response = api.call(event(query: { "q" => "全文検索" }))

      assert_equal 200, response.fetch(:statusCode)
      routes = JSON.parse(response.fetch(:body)).fetch("results").map { |result| result.fetch("route") }
      assert_equal %w[title-match body-match], routes
    end
  end

  def test_prefers_the_newer_page_when_scores_are_equal
    index = search_index_fixture
    Dir.mktmpdir("search-cache-") do |cache_dir|
      search_index = WeblogAuthoring::SearchIndex.new(
        s3_client: FakeS3.new(manifest: manifest_for("fixture", index), index:),
        bucket: "site",
        cache_dir:
      )
      api = WeblogAuthoring::LambdaApi.new(database: Object.new, search_index:, logger: StringIO.new)

      response = api.call(event(query: { "q" => "同点", "limit" => "2" }))
      routes = JSON.parse(response.fetch(:body)).fetch("results").map { |result| result.fetch("route") }

      assert_equal %w[newest-tie newer-tie], routes
    end
  end

  def test_rejects_an_invalid_limit_without_caching_the_error
    api = WeblogAuthoring::LambdaApi.new(database: Object.new)

    response = api.call(event(query: { "q" => "全文検索", "limit" => "21" }))

    assert_equal 422, response.fetch(:statusCode)
    assert_equal "private, no-store", response.fetch(:headers).fetch("cache-control")
    assert_equal ["limit must be between 1 and 20"], JSON.parse(response.fetch(:body)).dig("errors", "limit")
  end

  def test_returns_no_results_for_empty_and_unmatched_queries
    index = search_index_fixture
    Dir.mktmpdir("search-cache-") do |cache_dir|
      search_index = WeblogAuthoring::SearchIndex.new(
        s3_client: FakeS3.new(manifest: manifest_for("fixture", index), index:),
        bucket: "site",
        cache_dir:
      )
      api = WeblogAuthoring::LambdaApi.new(database: Object.new, search_index:, logger: StringIO.new)

      empty = api.call(event(query: { "q" => " " }))
      unmatched = api.call(event(query: { "q" => "存在しない検索語" }))

      assert_equal [], JSON.parse(empty.fetch(:body)).fetch("results")
      assert_equal [], JSON.parse(unmatched.fetch(:body)).fetch("results")
      assert_equal "private, no-store", empty.fetch(:headers).fetch("cache-control")
      assert_equal "private, no-store", unmatched.fetch(:headers).fetch("cache-control")
    end
  end

  private

  def event(query:)
    {
      "rawPath" => "/api/search",
      "queryStringParameters" => query,
      "requestContext" => { "http" => { "method" => "GET" } },
    }
  end

  def search_index_fixture
    Dir.mktmpdir("search-index-") do |directory|
      path = File.join(directory, "index.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE documents (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, active INTEGER NOT NULL)")
      database.execute("CREATE TABLE content (hash TEXT PRIMARY KEY, doc TEXT NOT NULL)")
      database.execute("CREATE VIRTUAL TABLE documents_fts USING fts5(filepath, title, body)")
      database.execute(<<~SQL)
        CREATE TABLE weblog_pages (
          document_id INTEGER PRIMARY KEY,
          route TEXT NOT NULL,
          title TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      SQL
      insert_document(
        database,
        id: 1,
        route: "title-match",
        title: "全文検索の設計",
        updated_at: "2026-08-20T12:00:00+09:00",
        body: "本文で全文検索を扱う記事です",
        fts_title: "全 文 検 索 の 設 計",
        fts_body: "本 文 で 全 文 検 索 を 扱 う 記 事 で す"
      )
      insert_document(
        database,
        id: 2,
        route: "body-match",
        title: "別の記事",
        updated_at: "2026-08-27T12:00:00+09:00",
        body: "新しい本文にも全文検索という言葉があります",
        fts_title: "別 の 記 事",
        fts_body: "新 し い 本 文 に も 全 文 検 索 と い う 言 葉 が あ り ま す"
      )
      insert_document(
        database,
        id: 3,
        route: "older-tie",
        title: "旧同点記録",
        updated_at: "2026-08-20T12:00:00+09:00",
        body: "同点",
        fts_title: "旧 同 点 記 録",
        fts_body: "同 点"
      )
      insert_document(
        database,
        id: 4,
        route: "newer-tie",
        title: "新同点記録",
        updated_at: "2026-08-27T12:00:00+09:00",
        body: "同点",
        fts_title: "新 同 点 記 録",
        fts_body: "同 点"
      )
      insert_document(
        database,
        id: 5,
        route: "newest-tie",
        title: "現同点記録",
        updated_at: "2026-08-28T12:00:00+09:00",
        body: "同点",
        fts_title: "現 同 点 記 録",
        fts_body: "同 点"
      )
      insert_document(
        database,
        id: 6,
        route: "weblog.ason.asの書き心地",
        title: "weblog.ason.asの書き心地",
        updated_at: "2026-08-27T13:00:00+09:00",
        body: "個人ブログの編集体験について書いた記事です",
        fts_title: "weblog ason as の 書 き 心 地",
        fts_body: "個 人 ブ ロ グ の 編 集 体 験 に つ い て 書 い た 記 事 で す"
      )
      database.close
      File.binread(path)
    end
  end

  def manifest_for(corpus_hash, index)
    JSON.generate(
      "corpus_hash" => corpus_hash,
      "index_key" => "search/generations/#{corpus_hash}/index.sqlite3",
      "index_sha256" => Digest::SHA256.hexdigest(index),
      "generated_at" => "2026-08-27T12:00:00+09:00"
    )
  end

  def insert_document(database, id:, route:, title:, updated_at:, body:, fts_title:, fts_body:)
    hash = "hash-#{id}"
    database.execute("INSERT INTO documents VALUES (?, ?, 1)", [id, hash])
    database.execute("INSERT INTO content VALUES (?, ?)", [hash, body])
    database.execute(
      "INSERT INTO documents_fts(rowid, filepath, title, body) VALUES (?, ?, ?, ?)",
      [id, route, fts_title, fts_body]
    )
    database.execute("INSERT INTO weblog_pages VALUES (?, ?, ?, ?)", [id, route, title, updated_at])
  end
end
