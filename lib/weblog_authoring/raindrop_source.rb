# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

require_relative "inbox_sync"

module WeblogAuthoring
  class RaindropSource
    RECENT_SECONDS = 7 * 24 * 60 * 60

    class Client
      API_URL = "https://api.raindrop.io"
      PER_PAGE = 50

      def initialize(token:, request: NetHttpRequest.new)
        @token = token
        @request = request
      end

      def list(collection_id:, created_since: nil)
        page = 0
        items = []
        loop do
          response = @request.call(
            uri: collection_uri(collection_id, page),
            headers: { "Authorization" => "Bearer #{@token}" }
          )
          page_items = response.fetch("items")
          raise TypeError, "Raindrop items must be an array" unless page_items.is_a?(Array)

          items.concat(page_items.select { |item| recent?(item, created_since) })
          break if page_items.length < PER_PAGE || crossed_boundary?(page_items, created_since)

          page += 1
        end
        items
      end

      private

      def collection_uri(collection_id, page)
        uri = URI("#{API_URL}/rest/v1/raindrops/#{collection_id}")
        uri.query = URI.encode_www_form(page:, perpage: PER_PAGE, sort: "-created")
        uri
      end

      def recent?(item, created_since)
        created_since.nil? || Time.iso8601(item.fetch("created")) >= created_since
      end

      def crossed_boundary?(items, created_since)
        created_since && items.any? { |item| Time.iso8601(item.fetch("created")) < created_since }
      end
    end

    class NetHttpRequest
      def call(uri:, headers:)
        response = Net::HTTP.get_response(uri, headers)
        unless response.is_a?(Net::HTTPSuccess)
          raise "Raindrop API returned #{response.code}"
        end

        JSON.parse(response.body)
      end
    end

    def initialize(client:, clock: Time.method(:now))
      @client = client
      @clock = clock
    end

    def fetch(watermark:) # rubocop:disable Lint/UnusedMethodArgument
      fetched_at = @clock.call
      cutoff = fetched_at - RECENT_SECONDS
      trashed_ids = @client.list(collection_id: -99, created_since: cutoff).to_h do |item|
        [Integer(item.fetch("_id")), true]
      end
      items = @client.list(collection_id: 0, created_since: cutoff).filter_map do |item|
        occurred_at = Time.iso8601(item.fetch("created"))
        next if occurred_at < cutoff

        raindrop_id = Integer(item.fetch("_id"))
        next if trashed_ids.key?(raindrop_id)

        InboxSync::Item.new(
          kind: "bookmark",
          source_id: raindrop_id.to_s,
          occurred_at:,
          payload: {
            "raindrop_id" => raindrop_id,
            "url" => item.fetch("link"),
            "title" => item.fetch("title"),
          }
        )
      end
      InboxSync::Snapshot.new(items:, complete: true, watermark: fetched_at.iso8601)
    end
  end
end
