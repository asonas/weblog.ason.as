# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "webrick"
require "weblog_authoring/bluesky_source"

class BlueskySourceTest < Minitest::Test
  NOW = Time.iso8601("2026-08-30T12:00:00Z")

  class FixtureClient
    attr_reader :post_since, :like_since

    def list_posts(since:)
      @post_since = since
      [
        {
          "uri" => "at://did:plc:me/app.bsky.feed.post/new",
          "cid" => "cid-new",
          "createdAt" => "2026-08-30T09:00:00Z",
          "canonicalUrl" => "https://bsky.app/profile/did:plc:me/post/new",
          "authorDid" => "did:plc:me",
          "text" => "New post text",
        },
        {
          "uri" => "at://did:plc:me/app.bsky.feed.post/old",
          "cid" => "cid-old",
          "createdAt" => "2026-08-23T11:59:59Z",
          "canonicalUrl" => "https://bsky.app/profile/did:plc:me/post/old",
          "authorDid" => "did:plc:me",
          "text" => "Old post text",
        },
      ]
    end

    def list_likes(since:)
      @like_since = since
      [
        {
          "uri" => "at://did:plc:me/app.bsky.feed.like/like-new",
          "cid" => "like-cid-new",
          "createdAt" => "2026-08-30T10:00:00Z",
          "subjectUri" => "at://did:plc:author/app.bsky.feed.post/post-new",
          "subjectCid" => "subject-cid-new",
          "canonicalUrl" => "https://bsky.app/profile/did:plc:author/post/post-new",
          "authorDid" => "did:plc:author",
          "text" => "Liked post text",
          "authorHandle" => "author.example",
          "authorDisplayName" => "Author",
          "thumbnailUrl" => "https://cdn.example/thumb.jpg",
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

  def test_builds_a_complete_seven_day_post_and_like_snapshot
    client = FixtureClient.new
    source = WeblogAuthoring::BlueskySource.new(client:, clock: -> { NOW })

    snapshot = source.fetch(watermark: "ignored")

    assert_equal NOW - (7 * 24 * 60 * 60), client.post_since
    assert_equal NOW - (7 * 24 * 60 * 60), client.like_since
    assert snapshot.complete
    assert_equal NOW.iso8601, snapshot.watermark
    assert_equal 2, snapshot.items.length
    post = snapshot.items.fetch(0)
    assert_equal "post", post.kind
    assert_equal "at://did:plc:me/app.bsky.feed.post/new", post.source_id
    assert_equal Time.iso8601("2026-08-30T09:00:00Z"), post.occurred_at
    assert_equal(
      {
        "record_uri" => "at://did:plc:me/app.bsky.feed.post/new",
        "record_cid" => "cid-new",
        "canonical_url" => "https://bsky.app/profile/did:plc:me/post/new",
        "author_did" => "did:plc:me",
        "text" => "New post text",
      },
      post.payload
    )
    like = snapshot.items.fetch(1)
    assert_equal "like", like.kind
    assert_equal "at://did:plc:me/app.bsky.feed.like/like-new", like.source_id
    assert_equal Time.iso8601("2026-08-30T10:00:00Z"), like.occurred_at
    assert_equal(
      {
        "like_uri" => "at://did:plc:me/app.bsky.feed.like/like-new",
        "like_cid" => "like-cid-new",
        "subject_uri" => "at://did:plc:author/app.bsky.feed.post/post-new",
        "subject_cid" => "subject-cid-new",
        "canonical_url" => "https://bsky.app/profile/did:plc:author/post/post-new",
        "author_did" => "did:plc:author",
        "text" => "Liked post text",
        "author_handle" => "author.example",
        "author_display_name" => "Author",
        "thumbnail_url" => "https://cdn.example/thumb.jpg",
      },
      like.payload
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

  def test_client_requests_likes_from_the_oauth_lambda_with_the_cutoff
    lambda_client = FixtureLambda.new(body: { "likes" => [] })
    client = WeblogAuthoring::BlueskySource::Client.new(
      lambda_client:,
      function_name: "bluesky-oauth"
    )

    assert_empty client.list_likes(since: NOW)

    invocation = lambda_client.invocations.fetch(0)
    assert_equal(
      { "action" => "list_likes", "since" => NOW.iso8601 },
      JSON.parse(invocation.fetch(:payload))
    )
  end

  def test_http_client_reads_posts_and_likes_from_the_loopback_server
    requests = []
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/") do |request, response|
      requests << [request.path, JSON.parse(request.body)]
      key = request.path == "/posts" ? "posts" : "likes"
      response["content-type"] = "application/json"
      response.body = JSON.generate(key => [{ "uri" => key }])
    end
    thread = Thread.new { server.start }
    client = WeblogAuthoring::BlueskySource::HttpClient.new(origin: "http://127.0.0.1:#{server.config.fetch(:Port)}")

    assert_equal [{ "uri" => "posts" }], client.list_posts(since: NOW)
    assert_equal [{ "uri" => "likes" }], client.list_likes(since: NOW)
    assert_equal [["/posts", { "since" => NOW.iso8601 }], ["/likes", { "since" => NOW.iso8601 }]], requests
  ensure
    server&.shutdown
    thread&.join
  end
end
