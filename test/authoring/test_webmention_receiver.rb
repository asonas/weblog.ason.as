# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/models"
require "weblog_authoring/webmention_receiver"

class WebmentionReceiverTest < Minitest::Test
  class Database
    def initialize(page)
      @page = page
    end

    def find_route(route)
      @page if route == @page.route
    end
  end

  class Queue
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(**message)
      messages << message
    end
  end

  class Resolver
    def getaddresses(host)
      { "example.com" => ["8.8.8.8"], "127.0.0.1" => ["127.0.0.1"] }.fetch(host, [])
    end
  end

  def setup
    page = WeblogAuthoring::PageDocument.new(
      id: "article-id", page_type: "named", name: "記事", page_date: nil, title: nil,
      status: "published", created_at: Time.iso8601("2026-08-30T00:00:00Z"),
      updated_at: Time.iso8601("2026-08-30T00:00:00Z"), published_at: Time.iso8601("2026-08-30T00:00:00Z"),
      path: Pathname("content/pages/article.md"), body: "本文", links: []
    )
    @queue = Queue.new
    @receiver = WeblogAuthoring::WebmentionReceiver.new(
      database: Database.new(page), sqs_client: @queue, queue_url: "queue-url",
      site_url: "https://weblog.ason.as", clock: -> { Time.iso8601("2026-08-30T12:00:00Z") },
      id_generator: -> { "job-id" }, resolver: Resolver.new
    )
  end

  def test_accepts_a_form_encoded_notification_for_a_published_article
    response = @receiver.call(event(source: "https://example.com/post", target: "https://weblog.ason.as/%E8%A8%98%E4%BA%8B/"))
    message = @queue.messages.fetch(0)
    payload = JSON.parse(message.fetch(:message_body))

    assert_equal 202, response.fetch(:statusCode)
    assert_equal "https://example.com/post", payload.fetch("source")
    assert_equal "verify", payload.fetch("type")
    assert_equal "https://weblog.ason.as/%E8%A8%98%E4%BA%8B", payload.fetch("target")
    assert_equal "article-id", payload.fetch("target_page_id")
    assert_equal "job-id", message.fetch(:message_deduplication_id)
    assert_equal 64, message.fetch(:message_group_id).length
  end

  def test_rejects_an_unowned_target_without_queuing
    response = @receiver.call(event(source: "https://example.com/post", target: "https://example.net/article"))

    assert_equal 400, response.fetch(:statusCode)
    assert_empty @queue.messages
  end

  def test_rejects_private_source_addresses_without_queuing
    response = @receiver.call(event(source: "http://127.0.0.1/post", target: "https://weblog.ason.as/%E8%A8%98%E4%BA%8B"))

    assert_equal 400, response.fetch(:statusCode)
    assert_empty @queue.messages
  end

  def test_rejects_a_non_url_source_without_queuing
    response = @receiver.call(event(source: "not-a-url", target: "https://weblog.ason.as/%E8%A8%98%E4%BA%8B"))

    assert_equal 400, response.fetch(:statusCode)
    assert_empty @queue.messages
  end

  def test_rejects_oversized_requests_before_parsing
    response = @receiver.call(
      "headers" => { "content-type" => "application/x-www-form-urlencoded" },
      "body" => "x" * (WeblogAuthoring::WebmentionReceiver::MAX_BODY_BYTES + 1)
    )

    assert_equal 413, response.fetch(:statusCode)
    assert_empty @queue.messages
  end

  def test_disabled_receiver_preserves_a_retryable_failure_boundary
    receiver = WeblogAuthoring::WebmentionReceiver.new(
      database: Object.new, sqs_client: @queue, queue_url: "queue-url",
      site_url: "https://weblog.ason.as", enabled: false
    )

    response = receiver.call(event(source: "https://example.com/post", target: "https://weblog.ason.as/%E8%A8%98%E4%BA%8B"))

    assert_equal 503, response.fetch(:statusCode)
    assert_equal "3600", response.fetch(:headers).fetch("retry-after")
    assert_empty @queue.messages
  end

  def test_target_ownership_check_failure_returns_a_retryable_response
    database = Object.new
    database.define_singleton_method(:find_route) { |_route| raise "database unavailable" }
    receiver = WeblogAuthoring::WebmentionReceiver.new(
      database:, sqs_client: @queue, queue_url: "queue-url", site_url: "https://weblog.ason.as",
      resolver: Resolver.new, logger: StringIO.new
    )

    response = receiver.call(event(
      source: "https://example.com/post", target: "https://weblog.ason.as/%E8%A8%98%E4%BA%8B"
    ))

    assert_equal 503, response.fetch(:statusCode)
    assert_equal "3600", response.fetch(:headers).fetch("retry-after")
    assert_empty @queue.messages
  end

  private

  def event(source:, target:)
    {
      "headers" => { "content-type" => "application/x-www-form-urlencoded; charset=utf-8" },
      "body" => URI.encode_www_form(source:, target:),
    }
  end
end
