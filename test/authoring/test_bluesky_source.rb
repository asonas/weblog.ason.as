# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "weblog_authoring/bluesky_source"

class BlueskySourceTest < Minitest::Test
  NOW = Time.iso8601("2026-08-30T12:00:00Z")

  class FixtureClient
    attr_reader :since

    def list_posts(since:)
      @since = since
      [
        {
          "uri" => "at://did:plc:me/app.bsky.feed.post/new",
          "cid" => "cid-new",
          "createdAt" => "2026-08-30T09:00:00Z",
          "canonicalUrl" => "https://bsky.app/profile/did:plc:me/post/new",
          "authorDid" => "did:plc:me",
        },
        {
          "uri" => "at://did:plc:me/app.bsky.feed.post/old",
          "cid" => "cid-old",
          "createdAt" => "2026-08-23T11:59:59Z",
          "canonicalUrl" => "https://bsky.app/profile/did:plc:me/post/old",
          "authorDid" => "did:plc:me",
        },
      ]
    end
  end

  class FixtureLambda
    Response = Data.define(:payload, :function_error)

    attr_reader :invocations

    def initialize(body:, function_error: nil)
      @body = body
      @function_error = function_error
      @invocations = []
    end

    def invoke(**arguments)
      invocations << arguments
      Response.new(payload: StringIO.new(JSON.generate(@body)), function_error: @function_error)
    end
  end

  def test_builds_a_complete_seven_day_post_snapshot
    client = FixtureClient.new
    source = WeblogAuthoring::BlueskySource.new(client:, clock: -> { NOW })

    snapshot = source.fetch(watermark: "ignored")

    assert_equal NOW - (7 * 24 * 60 * 60), client.since
    assert snapshot.complete
    assert_equal NOW.iso8601, snapshot.watermark
    assert_equal 1, snapshot.items.length
    item = snapshot.items.first
    assert_equal "post", item.kind
    assert_equal "at://did:plc:me/app.bsky.feed.post/new", item.source_id
    assert_equal Time.iso8601("2026-08-30T09:00:00Z"), item.occurred_at
    assert_equal(
      {
        "record_uri" => "at://did:plc:me/app.bsky.feed.post/new",
        "record_cid" => "cid-new",
        "canonical_url" => "https://bsky.app/profile/did:plc:me/post/new",
        "author_did" => "did:plc:me",
      },
      item.payload
    )
  end

  def test_client_invokes_the_oauth_lambda_with_the_cutoff
    lambda_client = FixtureLambda.new(body: { "posts" => [] })
    client = WeblogAuthoring::BlueskySource::Client.new(
      lambda_client:,
      function_name: "bluesky-oauth"
    )

    assert_empty client.list_posts(since: NOW)

    invocation = lambda_client.invocations.fetch(0)
    assert_equal "bluesky-oauth", invocation.fetch(:function_name)
    assert_equal "RequestResponse", invocation.fetch(:invocation_type)
    assert_equal(
      { "action" => "list_posts", "since" => NOW.iso8601 },
      JSON.parse(invocation.fetch(:payload))
    )
  end
end
