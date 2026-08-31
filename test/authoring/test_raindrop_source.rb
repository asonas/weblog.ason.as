# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/raindrop_source"

class RaindropSourceTest < Minitest::Test
  NOW = Time.iso8601("2026-08-29T12:00:00Z")

  class FixtureRequest
    attr_reader :uris

    def initialize(responses)
      @responses = responses
      @uris = []
    end

    def call(uri:, headers:)
      uris << uri
      raise "missing bearer token" unless headers.fetch("Authorization") == "Bearer test-token"

      @responses.fetch([uri.path, URI.decode_www_form(uri.query).to_h.fetch("page")])
    end
  end

  class FixtureClient
    def initialize(collections)
      @collections = collections
    end

    def list(collection_id:, **)
      @collections.fetch(collection_id)
    end
  end

  def test_client_pages_through_all_raindrops_and_trash
    first_page = Array.new(50) { |index| raindrop(index + 1) }
    request = FixtureRequest.new(
      ["/rest/v1/raindrops/0", "0"] => { "items" => first_page },
      ["/rest/v1/raindrops/0", "1"] => { "items" => [raindrop(51)] },
      ["/rest/v1/raindrops/-99", "0"] => { "items" => [raindrop(9)] }
    )
    client = WeblogAuthoring::RaindropSource::Client.new(token: "test-token", request:)

    current = client.list(collection_id: 0)
    trash = client.list(collection_id: -99)

    assert_equal 51, current.length
    assert_equal([9], trash.map { |item| item.fetch("_id") })
    assert_equal(%w[0 1 0], request.uris.map { |uri| URI.decode_www_form(uri.query).to_h.fetch("page") })
    assert(request.uris.all? { |uri| URI.decode_www_form(uri.query).to_h.fetch("perpage") == "50" })
  end

  def test_client_stops_after_crossing_the_recent_window
    recent = Array.new(49) { |index| raindrop(index + 1) }
    old = raindrop(50, created: NOW - (8 * 86_400))
    request = FixtureRequest.new(
      ["/rest/v1/raindrops/0", "0"] => { "items" => [*recent, old] }
    )
    client = WeblogAuthoring::RaindropSource::Client.new(token: "test-token", request:)

    items = client.list(collection_id: 0, created_since: NOW - (7 * 86_400))

    assert_equal 49, items.length
    assert_equal 1, request.uris.length
  end

  def test_source_builds_a_complete_recent_snapshot_and_excludes_trash
    client = FixtureClient.new(
      0 => [
        raindrop(1, created: NOW - 3600, link: "https://example.com/new", title: "New", excerpt: "Summary", cover: "https://cdn.example/cover.jpg"),
        raindrop(2, created: NOW - (8 * 86_400), link: "https://example.com/old", title: "Old"),
        raindrop(3, created: NOW - 7200, link: "https://example.com/trash", title: "Trash"),
      ],
      -99 => [raindrop(3, created: NOW - 7200)]
    )
    source = WeblogAuthoring::RaindropSource.new(client:, clock: -> { NOW })

    snapshot = source.fetch(watermark: "2026-08-28T12:00:00Z")

    assert snapshot.complete
    assert_equal NOW.iso8601, snapshot.watermark
    assert_equal ["1"], snapshot.items.map(&:source_id)
    item = snapshot.items.fetch(0)
    assert_equal "bookmark", item.kind
    assert_equal NOW - 3600, item.occurred_at
    assert_equal(
      {
        "raindrop_id" => 1,
        "url" => "https://example.com/new",
        "title" => "New",
        "excerpt" => "Summary",
        "cover" => "https://cdn.example/cover.jpg",
      },
      item.payload
    )
  end

  private

  def raindrop(id, created: NOW - 3600, link: "https://example.com/#{id}", title: "Bookmark #{id}", excerpt: nil, cover: nil)
    {
      "_id" => id,
      "created" => created.iso8601,
      "lastUpdate" => created.iso8601,
      "link" => link,
      "title" => title,
      "excerpt" => excerpt,
      "cover" => cover,
    }
  end
end
