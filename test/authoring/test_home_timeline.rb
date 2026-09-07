# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_database"
require_relative "../../lib/weblog_authoring/home_timeline"
require_relative "../../lib/weblog_authoring/lambda_api"

class TestHomeTimeline < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("home-timeline")
    @database = WeblogAuthoring::DevelopmentDatabase.new(
      File.join(@directory, "pages.sqlite3"), content_dir: File.join(@directory, "content"),
      clock: -> { Time.iso8601("2026-09-07T12:00:00+09:00") }
    )
    @database.setup!
    @timeline = WeblogAuthoring::HomeTimeline.new(@database)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def save(name, body: "本文", updated_at: "2026-09-07T00:00:00.000000000+00:00")
    page = @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name:, body:))
    SQLite3::Database.new(@database.path.to_s) { |sqlite| sqlite.execute("UPDATE pages SET updated_at = ? WHERE id = ?", [updated_at, page.id]) }
    @database.find(page.id)
  end

  def test_mixes_diary_dates_and_article_updates_with_tokyo_month_boundaries
    diary = save("2026-08-31", body: "本文 [[日記]]")
    last_article = save("8月の記事", updated_at: "2026-08-31T14:59:59.000000000+00:00")
    save("9月の記事", updated_at: "2026-08-31T15:00:00.000000000+00:00")
    august = @timeline.window("month" => "2026-08")
    assert_equal [last_article.id, diary.id], august.fetch("pages").map(&:id)
    refute august.fetch("has_newer")
    refute august.fetch("has_older")
  end

  def test_traverses_all_pages_and_returns_to_the_same_window_without_duplicate_timestamps
    pages = 29.times.map { |i| save("同時更新#{i}") }.sort_by(&:id).reverse
    first = @timeline.window({})
    second = @timeline.window("before" => first.fetch("older_cursor"))
    third = @timeline.window("before" => second.fetch("older_cursor"))
    assert_equal(pages.map(&:id), [first, second, third].flat_map { |window| window.fetch("pages").map(&:id) })
    assert_equal([12, 12, 5], [first, second, third].map { |window| window.fetch("pages").length })
    refute first.fetch("has_newer")
    refute third.fetch("has_older")
    assert second.fetch("has_newer")
    previous = @timeline.window("after" => third.fetch("newer_cursor"))
    assert_equal second.fetch("pages"), previous.fetch("pages")
    assert previous.fetch("has_newer")
    assert previous.fetch("has_older")
    newest = @timeline.window("after" => previous.fetch("newer_cursor"))
    assert_equal first.fetch("pages"), newest.fetch("pages")
    refute newest.fetch("has_newer")
  end

  def test_lambda_exposes_the_timeline_window_and_rejects_invalid_queries
    save("2026-09-02", body: "本文 [[日記]]")
    api = WeblogAuthoring::LambdaApi.new(database: @database)
    event = { "rawPath" => "/api/pages", "requestContext" => { "http" => { "method" => "GET" } }, "queryStringParameters" => { "kind" => "timeline", "month" => "2026-09" } }
    response = api.call(event)
    assert_equal 200, response.fetch(:statusCode)
    assert_equal(["2026-09-02"], JSON.parse(response.fetch(:body)).fetch("pages").map { |page| page.fetch("title") })
    event["queryStringParameters"]["before"] = "invalid"
    assert_equal 422, api.call(event).fetch(:statusCode)
  end
end
