# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/development_database"
require "weblog_authoring/diary_navigation"
require "weblog_authoring/lambda_api"

class TestDiaryNavigation < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("diary-navigation")
    @database = WeblogAuthoring::DevelopmentDatabase.new(
      File.join(@directory, "pages.sqlite3"), content_dir: File.join(@directory, "content")
    )
    @database.setup!
    @navigation = WeblogAuthoring::DiaryNavigation.new(@database)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def save(name, body: "本文 [[日記]]")
    @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name:, body:))
  end

  def test_selects_published_diaries_by_route_date_instead_of_creation_order
    save("2026-09-11")
    save("2026-09-10")
    save("2026-09-07")
    save("2026-09-09", body: "通常の記事")
    save("日記について")
    hidden = save("2026-09-08")
    SQLite3::Database.new(@database.path.to_s) do |db|
      db.execute("UPDATE pages SET status = 'draft' WHERE id = ?", [hidden.id])
      db.execute("UPDATE pages SET page_type = 'date', page_date = name, name = NULL WHERE name = '2026-09-07'")
    end

    assert_equal({ "newer" => "2026-09-11", "older" => "2026-09-07" }, @navigation.neighbors("2026-09-10"))
    assert_equal({ "newer" => nil, "older" => nil }, @navigation.neighbors("2026-09-09"))
    assert_equal({ "newer" => nil, "older" => nil }, @navigation.neighbors("日記について"))
  end

  def test_edges_and_new_or_emptied_diaries_are_reflected_on_the_next_request
    save("2026-09-10")
    assert_equal({ "newer" => nil, "older" => nil }, @navigation.neighbors("2026-09-10"))
    newer = save("2026-09-12")
    assert_equal({ "newer" => "2026-09-12", "older" => nil }, @navigation.neighbors("2026-09-10"))
    assert_equal({ "newer" => nil, "older" => "2026-09-10" }, @navigation.neighbors("2026-09-12"))
    @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", page_id: newer.id, name: newer.name, body: ""))
    assert_equal({ "newer" => nil, "older" => nil }, @navigation.neighbors("2026-09-10"))
  end

  def test_public_lambda_endpoint_revalidates_neighbors
    save("2026-09-10")
    api = WeblogAuthoring::LambdaApi.new(database: @database)
    event = { "rawPath" => "/api/diary-navigation", "requestContext" => { "http" => { "method" => "GET" } }, "queryStringParameters" => { "route" => "2026-09-10" } }
    first = api.call(event)
    assert_equal 200, first.fetch(:statusCode), first.fetch(:body)
    assert_equal({ "newer" => nil, "older" => nil }, JSON.parse(first.fetch(:body)))
    event["headers"] = { "if-none-match" => first.fetch(:headers).fetch("etag") }
    assert_equal 304, api.call(event).fetch(:statusCode)
    save("2026-09-11")
    changed = api.call(event)
    assert_equal 200, changed.fetch(:statusCode)
    assert_equal "2026-09-11", JSON.parse(changed.fetch(:body)).fetch("newer")
  end
end
