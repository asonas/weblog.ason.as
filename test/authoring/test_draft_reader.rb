# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_migration"
require "weblog_authoring/lambda_api"
require "weblog_authoring/development_database"

class DraftReaderTest < Minitest::Test
  ID = "dc802ad0b89946aeb6b7623c2ba7bc79"

  def setup
    @root = Pathname(Dir.mktmpdir("draft-reader"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @legacy = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    @legacy.setup!
    @old = @legacy.save(WeblogAuthoring::SaveRequest.new(page_type: "named", title: "旧DBにだけ存在", body: "旧本文 [[非公開タグ]]"))
    @source = { "format" => 1, "site_url" => "https://example.com", "articles" => [{
      "id" => ID, "page_type" => "date", "route" => "2026-09-01", "title" => "2026-09-01", "body" => "公開本文 [[日記]] [[公開タグ]]",
      "cover_mode" => "none", "cover_image_url" => nil, "created_at" => "2026-09-01T01:00:00Z", "updated_at" => "2026-09-02T01:00:00Z", "published_at" => "2026-09-01T01:00:00Z",
    }], }
    WeblogAuthoring::DraftMigration.new(store: @store).import(@source)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_published_reader_apis_do_not_fall_back_to_legacy_or_working_content
    outbox = @legacy.pending_webmention_outbox
    @store.append(ID, { "protocol" => 1, "generation" => 1, "update_id" => "working-title", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => {
        "title" => { "value" => "未公開タイトル", "expected_revision" => 0 },
        "page_type" => { "value" => "named", "expected_revision" => 0 },
        "page_date" => { "value" => "", "expected_revision" => 0 },
      }, })
    @store.create(@old.id, { "protocol" => 1, "generation" => 1 })
    reader = WeblogAuthoring::DraftReader.new(store: @store, database: @legacy)
    publication = WeblogAuthoring::DraftPublication.local(store: @store)
    publisher = WeblogAuthoring::DraftPublisher.local(publication:, database: reader, root: @root.join("html"),
      shell: -> { '<html><head></head><body><div id="authoring-root"></div></body></html>' }, site_url: "https://example.com")
    snapshot = @store.published_snapshot(ID)
    @store.record_publication_html(ID, snapshot.fetch("id"), publisher.repair(snapshot))
    api = WeblogAuthoring::LambdaApi.new(database: @legacy, draft_store: @store, reader_database: reader, draft_publisher: publisher)
    ["/api/pages", "/api/tags", "/api/archive", "/api/page-names", "/api/related"].each do |path|
      response = get(api, path)
      assert_equal 200, response.fetch(:statusCode), path
      refute_includes response.fetch(:body), "旧DBにだけ存在", path
      refute_includes response.fetch(:body), "未公開タイトル", path
      refute_includes response.fetch(:body), "非公開タグ", path
    end
    list = JSON.parse(get(api, "/api/pages").fetch(:body)).fetch("pages")
    assert_equal [ID], (list.map { |page| page.fetch("id") })
    assert_equal "2026-09-01", list.first.fetch("title")
    timeline = get(api, "/api/pages", query: { "kind" => "timeline" })
    assert_equal [ID], (JSON.parse(timeline.fetch(:body)).fetch("pages").map { |page| page.fetch("id") })
    assert_equal 404, get(api, "/api/pages/#{@old.id}", parameters: { "id" => @old.id }).fetch(:statusCode)
    route = get(api, "/api/routes/old", parameters: { "route" => @old.route })
    assert_empty JSON.parse(route.fetch(:body)).fetch("body")
    published = get(api, "/api/pages/#{ID}", parameters: { "id" => ID })
    assert_equal "公開本文 [[日記]] [[公開タグ]]", JSON.parse(published.fetch(:body)).fetch("body")
    html = get(api, "/2026-09-01")
    assert_equal 200, html.fetch(:statusCode)
    assert_includes html.fetch(:body), "2026-09-01"
    refute_includes html.fetch(:body), "未公開タイトル"
    assert_equal outbox, @legacy.pending_webmention_outbox
  end

  def test_publication_order_cursors_and_diary_neighbors_use_only_public_snapshots
    second = "ec802ad0b89946aeb6b7623c2ba7bc79"
    third = "fc802ad0b89946aeb6b7623c2ba7bc79"
    root = @root.join("three.sqlite3")
    store = WeblogAuthoring::DraftStore.sqlite(root)
    store.setup!
    @source.fetch("articles").concat([
      @source.fetch("articles").first.merge("id" => second, "route" => "2026-09-02", "title" => "2026-09-02", "updated_at" => "2026-09-03T01:00:00Z"),
      @source.fetch("articles").first.merge("id" => third, "route" => "通常記事", "title" => "通常記事", "page_type" => "named", "body" => "[[公開タグ]]", "updated_at" => "2026-09-04T01:00:00Z"),
    ])
    WeblogAuthoring::DraftMigration.new(store:).import(@source)
    reader = WeblogAuthoring::DraftReader.new(store:, database: @legacy)
    assert_equal [third, second, ID], reader.list_pages.map(&:id)
    cursor = { timestamp: Time.iso8601("2026-09-03T01:00:00Z"), id: second }
    assert_equal [ID], reader.list_pages(limit: 1, before: cursor).map(&:id)
    assert_equal [third], reader.list_pages(limit: 1, after: cursor).map(&:id)
    assert_equal [third], reader.list_pages(kind: "article").map(&:id)
    assert_equal [second, ID], reader.list_pages(kind: "diary").map(&:id)
    assert_equal [third, second, ID], reader.list_timeline_pages(limit: 3, month: "2026-09").map(&:id)
    timeline_cursor = { key: "2026-09-02T00:00:00", id: second }
    assert_equal [ID], reader.list_timeline_pages(limit: 1, before: timeline_cursor).map(&:id)
    assert_equal [third], reader.list_timeline_pages(limit: 1, after: timeline_cursor).map(&:id)
    assert_empty reader.list_timeline_pages(limit: 3, month: "2026-08")
    assert_equal({ "newer" => "2026-09-02", "older" => nil }, WeblogAuthoring::DiaryNavigation.new(reader).neighbors("2026-09-01"))
  end

  private

  def get(api, path, query: {}, parameters: {})
    api.call({ "requestContext" => { "http" => { "method" => "GET" } }, "rawPath" => path, "queryStringParameters" => query, "pathParameters" => parameters })
  end
end
