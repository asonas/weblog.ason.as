# frozen_string_literal: true

require "json"
require "stringio"
require "time"

require_relative "inbox_sync"

module WeblogAuthoring
  class BlueskySource
    RECENT_SECONDS = 7 * 24 * 60 * 60

    class Client
      def initialize(lambda_client:, function_name:)
        @lambda_client = lambda_client
        @function_name = function_name
      end

      def list_posts(since:)
        response = @lambda_client.invoke(
          function_name: @function_name,
          invocation_type: "RequestResponse",
          payload: JSON.generate("action" => "list_posts", "since" => since.iso8601)
        )
        raise "Bluesky OAuth Lambda failed" unless response.function_error.nil?

        body = response.payload.respond_to?(:read) ? response.payload.read : response.payload.to_s
        posts = JSON.parse(body).fetch("posts")
        raise TypeError, "Bluesky posts must be an array" unless posts.is_a?(Array)

        posts
      end
    end

    def initialize(client:, clock: Time.method(:now))
      @client = client
      @clock = clock
    end

    def fetch(watermark:) # rubocop:disable Lint/UnusedMethodArgument
      fetched_at = @clock.call
      cutoff = fetched_at - RECENT_SECONDS
      items = @client.list_posts(since: cutoff).filter_map do |post|
        occurred_at = Time.iso8601(post.fetch("createdAt"))
        next if occurred_at < cutoff

        InboxSync::Item.new(
          kind: "post",
          source_id: post.fetch("uri"),
          occurred_at:,
          payload: {
            "record_uri" => post.fetch("uri"),
            "record_cid" => post.fetch("cid"),
            "canonical_url" => post.fetch("canonicalUrl"),
            "author_did" => post.fetch("authorDid"),
          }
        )
      end
      InboxSync::Snapshot.new(items:, complete: true, watermark: fetched_at.iso8601)
    end
  end
end
