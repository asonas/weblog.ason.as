# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_revalidator"

class WebmentionRevalidatorTest < Minitest::Test
  class Database
    attr_reader :query

    def stale_approved_webmentions(before:, limit:)
      @query = { before:, limit: }
      [{ "source" => "https://example.com/post", "target" => "https://weblog.ason.as/article", "target_page_id" => "page-id" }]
    end
  end

  class Sqs
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(message)
      messages << message
    end
  end

  def test_queues_a_bounded_batch_of_stale_approved_mentions
    now = Time.iso8601("2026-08-30T12:00:00Z")
    database = Database.new
    sqs = Sqs.new
    result = WeblogAuthoring::WebmentionRevalidator.new(
      database:, sqs_client: sqs, queue_url: "queue", clock: -> { now }, limit: 25, stale_after_days: 7
    ).call

    assert_equal({ before: now - (7 * 24 * 60 * 60), limit: 25 }, database.query)
    assert_equal 1, result.fetch("queued")
    body = JSON.parse(sqs.messages.fetch(0).fetch(:message_body))
    assert_equal "verify", body.fetch("type")
    assert_equal "page-id", body.fetch("target_page_id")
  end
end
