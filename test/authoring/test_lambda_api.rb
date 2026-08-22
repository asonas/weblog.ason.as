# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/lambda_api"

class LambdaApiTest < Minitest::Test
  class FakeDatabase
    attr_reader :health_checks, :pages

    def initialize(pages)
      @pages = pages
      @health_checks = 0
    end

    def healthy?
      @health_checks += 1
      true
    end

    def list_pages
      pages
    end

    def find(id)
      pages.find { |page| page.id == id }
    end

    def find_route(route)
      pages.find { |page| page.route == route }
    end
  end

  def setup
    @page = WeblogAuthoring::PageDocument.new(
      id: "page-id",
      page_type: "named",
      name: "記事名",
      page_date: nil,
      title: nil,
      status: "published",
      created_at: Time.iso8601("2026-08-22T10:00:00+09:00"),
      updated_at: Time.iso8601("2026-08-22T11:00:00+09:00"),
      published_at: Time.iso8601("2026-08-22T11:00:00+09:00"),
      path: Pathname("content/pages/article.md"),
      body: "本文",
      links: []
    )
    @database = FakeDatabase.new([@page])
    @api = WeblogAuthoring::LambdaApi.new(database: @database)
  end

  def test_returns_health
    response = @api.call(event("GET", "/health"))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal({ "status" => "ok" }, JSON.parse(response.fetch(:body)))
    assert_equal 1, @database.health_checks
  end

  def test_lists_page_summaries_without_bodies
    response = @api.call(event("GET", "/api/pages"))
    page = JSON.parse(response.fetch(:body)).fetch("pages").fetch(0)

    assert_equal "記事名", page.fetch("title")
    assert_equal "記事名", page.fetch("route")
    refute page.key?("body")
  end

  def test_finds_a_page_by_id
    response = @api.call(event("GET", "/api/pages/page-id", "id" => "page-id"))
    page = JSON.parse(response.fetch(:body)).fetch("page")

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "本文", page.fetch("body")
  end

  def test_finds_a_page_by_encoded_route
    response = @api.call(event("GET", "/api/routes/%E8%A8%98%E4%BA%8B%E5%90%8D", "route" => "%E8%A8%98%E4%BA%8B%E5%90%8D"))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "記事名", JSON.parse(response.fetch(:body)).dig("page", "route")
  end

  def test_returns_not_found_for_unknown_routes
    response = @api.call(event("POST", "/api/pages"))

    assert_equal 404, response.fetch(:statusCode)
  end

  private

  def event(method, path, path_parameters = nil)
    {
      "rawPath" => path,
      "pathParameters" => path_parameters,
      "requestContext" => { "http" => { "method" => method } },
    }
  end
end
