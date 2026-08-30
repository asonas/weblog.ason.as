# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

module WeblogAuthoring
  class WebmentionRevalidator
    def initialize(database:, sqs_client:, queue_url:, clock: Time.method(:now), limit: 100, stale_after_days: 7)
      @database = database
      @sqs_client = sqs_client
      @queue_url = queue_url
      @clock = clock
      @limit = limit
      @stale_after_days = stale_after_days
    end

    def call
      timestamp = @clock.call
      mentions = @database.stale_approved_webmentions(
        before: timestamp - (@stale_after_days * 24 * 60 * 60), limit: @limit
      )
      mentions.each { |mention| enqueue(mention, timestamp) }
      { "queued" => mentions.length }
    end

    private

    def enqueue(mention, timestamp)
      job_id = SecureRandom.uuid
      source = mention.fetch("source")
      target = mention.fetch("target")
      @sqs_client.send_message(
        queue_url: @queue_url,
        message_body: JSON.generate(
          mention.merge("type" => "verify", "job_id" => job_id, "received_at" => timestamp.iso8601)
        ),
        message_group_id: Digest::SHA256.hexdigest("#{source}\0#{target}"),
        message_deduplication_id: job_id
      )
    end
  end
end
