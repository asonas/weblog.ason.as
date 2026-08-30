# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_sender"

class WebmentionSenderTest < Minitest::Test
  Response = WeblogAuthoring::WebmentionFetcher::Response

  class Database
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def record_webmention_delivery(**delivery)
      deliveries << delivery
    end
  end

  class Fetcher
    attr_reader :posts

    def initialize(response, post_status: 202)
      @response = response
      @post_status = post_status
      @posts = []
    end

    def fetch(_url)
      @response
    end

    def post_form(url, form)
      posts << [url, form]
      @post_status
    end
  end

  def setup
    @job = {
      "type" => "deliver", "delivery_id" => "delivery-id", "page_id" => "page-id",
      "source" => "https://weblog.ason.as/article", "target" => "https://target.example/post",
    }
    @database = Database.new
  end

  def test_discovers_the_header_endpoint_and_accepts_any_2xx_response
    fetcher = Fetcher.new(response(link_header: '<https://target.example/webmention?token=1>; rel="webmention"'))
    sender = WeblogAuthoring::WebmentionSender.new(database: @database, fetcher:)

    sender.deliver(@job)

    assert_equal(
      ["https://target.example/webmention?token=1", {
        "source" => "https://weblog.ason.as/article", "target" => "https://target.example/post",
      },],
      fetcher.posts.fetch(0)
    )
    assert_equal "succeeded", @database.deliveries.fetch(0).fetch(:status)
    assert_equal 202, @database.deliveries.fetch(0).fetch(:http_status)
  end

  def test_falls_back_to_an_html_anchor_endpoint
    fetcher = Fetcher.new(response(body: '<a rel="webmention" href="/endpoint">Webmention</a>'))

    WeblogAuthoring::WebmentionSender.new(database: @database, fetcher:).deliver(@job)

    assert_equal "https://target.example/endpoint", fetcher.posts.fetch(0).fetch(0)
  end

  def test_records_a_target_without_an_endpoint_without_retrying
    fetcher = Fetcher.new(response(body: "<p>No endpoint</p>"))

    WeblogAuthoring::WebmentionSender.new(database: @database, fetcher:).deliver(@job)

    assert_empty fetcher.posts
    assert_equal "not_supported", @database.deliveries.fetch(0).fetch(:status)
  end

  private

  def response(body: "<p>Target</p>", link_header: nil)
    Response.new(
      url: "https://target.example/post", status: 200, content_type: "text/html",
      link_header:, body:, redirect_count: 0, duration_ms: 10
    )
  end
end
