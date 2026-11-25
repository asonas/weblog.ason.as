# frozen_string_literal: true

require "json"
require "net/http"
require "stringio"
require "time"
require "uri"

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

    class HttpClient
      def initialize(origin:)
        @origin = URI(origin)
      end

      def list_posts(since:)
        request("/posts", "posts", since:)
      end

      private

      def request(path, key, since:)
        uri = @origin + path
        response = Net::HTTP.post(uri, JSON.generate("since" => since.iso8601), "content-type" => "application/json")
        raise "Bluesky OAuth development server returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        items = JSON.parse(response.body).fetch(key)
        raise TypeError, "Bluesky #{key} must be an array" unless items.is_a?(Array)

        items
      end
    end

    def initialize(client:, clock: Time.method(:now))
      @client = client
      @clock = clock
    end

    def fetch(watermark:) # rubocop:disable Lint/UnusedMethodArgument
      fetched_at = @clock.call
      cutoff = fetched_at - RECENT_SECONDS
      posts = @client.list_posts(since: cutoff).filter_map do |post|
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
            "text" => post.fetch("text"),
          }
        )
      end
      InboxSync::Snapshot.new(items: posts, complete: true, watermark: fetched_at.iso8601)
    end
  end
end
