# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/github_oauth"
require_relative "../../lib/weblog_authoring/lambda_api"
require_relative "../../lib/weblog_authoring/lambda_session"

class LambdaApiTest < Minitest::Test
  class FakeS3
    ObjectBody = Data.define(:body)

    attr_reader :objects

    def initialize
      @objects = {}
    end

    def get_object(bucket:, key:)
      value = objects[[bucket, key]]
      raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") if value.nil?

      ObjectBody.new(StringIO.new(value))
    end

    def put_object(bucket:, key:, body:, content_type:, cache_control: nil) # rubocop:disable Lint/UnusedMethodArgument
      objects[[bucket, key]] = body
    end
  end

  class FakeEmbedFetcher
    attr_reader :requests

    def initialize
      @requests = []
    end

    def fetch(url)
      requests << url
      {
        "url" => url,
        "canonical_url" => url,
        "title" => "Example",
        "description" => "Description",
        "image_url" => "https://example.com/image.jpg",
        "site_name" => "example.com",
        "status" => "ready",
      }
    end
  end

  class FakeDatabase
    attr_reader :health_checks, :pages, :saved_requests

    def initialize(pages)
      @pages = pages
      @health_checks = 0
      @saved_requests = []
    end

    def healthy?
      @health_checks += 1
      true
    end

    def list_pages
      pages
    end

    def find(id)
      pages.find { |page| page.id == id }
    end

    def find_route(route)
      pages.find { |page| page.route == route }
    end

    def save(request)
      saved_requests << request
      pages.fetch(0)
    end
  end

  class FakeOAuth
    attr_reader :authentication_request

    def authorization_url(redirect_uri:, state:, code_challenge:)
      "https://github.com/login/oauth/authorize?#{URI.encode_www_form(redirect_uri:, state:, code_challenge:)}"
    end

    def authenticate(**request)
      @authentication_request = request
      { "id" => 630_181, "login" => "asonas" }
    end
  end

  def setup
    @page = WeblogAuthoring::PageDocument.new(
      id: "page-id",
      page_type: "named",
      name: "記事名",
      page_date: nil,
      title: nil,
      status: "published",
      created_at: Time.iso8601("2026-08-22T10:00:00+09:00"),
      updated_at: Time.iso8601("2026-08-22T11:00:00+09:00"),
      published_at: Time.iso8601("2026-08-22T11:00:00+09:00"),
      path: Pathname("content/pages/article.md"),
      body: "本文",
      links: []
    )
    @database = FakeDatabase.new([@page])
    @api = WeblogAuthoring::LambdaApi.new(database: @database)
  end

  def test_returns_health
    response = @api.call(event("GET", "/health"))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal({ "status" => "ok" }, JSON.parse(response.fetch(:body)))
    assert_equal 1, @database.health_checks
  end

  def test_publishes_an_rss_feed_to_s3_for_a_scheduled_event
    s3 = FakeS3.new
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      frontend_url: "https://weblog.ason.as",
      s3_client: s3,
      site_bucket: "production-site"
    )

    response = api.call("source" => "aws.events", "detail-type" => "Scheduled Event")
    feed = s3.objects.fetch(["production-site", "feed.xml"])

    assert_equal 200, response.fetch(:statusCode)
    assert_includes feed, "<title>記事名</title>"
    assert_includes feed, "&lt;p&gt;本文&lt;/p&gt;"
    assert_includes feed, "https://weblog.ason.as/%E8%A8%98%E4%BA%8B%E5%90%8D"
  end

  def test_lists_page_summaries_without_bodies
    response = @api.call(event("GET", "/api/pages"))
    page = JSON.parse(response.fetch(:body)).fetch("pages").fetch(0)

    assert_equal "home", JSON.parse(response.fetch(:body)).fetch("mode")
    assert_equal "記事名", page.fetch("title")
    assert_equal "記事名", page.fetch("route")
    refute page.key?("body")
  end

  def test_finds_a_page_by_id
    response = @api.call(event("GET", "/api/pages/page-id", { "id" => "page-id" }))
    page = JSON.parse(response.fetch(:body))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "editor", page.fetch("mode")
    assert_equal "本文", page.fetch("body")
  end

  def test_finds_a_page_by_encoded_route
    response = @api.call(event(
      "GET",
      "/api/routes/%E8%A8%98%E4%BA%8B%E5%90%8D",
      { "route" => "%E8%A8%98%E4%BA%8B%E5%90%8D" }
    ))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "記事名", JSON.parse(response.fetch(:body)).fetch("name")
  end

  def test_returns_pages_related_by_wiki_links
    source = page_document(id: "source", name: "source", body: "[[target]]")
    target = page_document(id: "target", name: "target", body: "")
    @database.pages.replace([source, target])

    response = @api.call(event("GET", "/api/routes/source", { "route" => "source" }))
    linked_pages = JSON.parse(response.fetch(:body)).fetch("linked_pages")

    assert_equal ["target"], linked_pages.map { |page| page.fetch("route") }
  end

  def test_returns_related_pages_from_the_pagination_endpoint
    target = page_document(id: "target", name: "target", body: "")
    sources = 51.times.map do |index|
      page_document(id: "source-#{index}", name: "source-#{index}", body: "[[target]]")
    end
    @database.pages.replace([target, *sources])

    first = @api.call(event("GET", "/api/routes/target", { "route" => "target" }))
    first_body = JSON.parse(first.fetch(:body))
    second = @api.call(event(
      "GET",
      "/api/related",
      query: { "route" => "target", "excluding_id" => "target", "offset" => "50" }
    ))
    second_body = JSON.parse(second.fetch(:body))

    assert_equal 50, first_body.fetch("linked_pages").length
    assert first_body.fetch("linked_pages_has_more")
    assert_equal 1, second_body.fetch("pages").length
    refute second_body.fetch("has_more")
  end

  def test_returns_and_caches_embed_metadata
    s3 = FakeS3.new
    fetcher = FakeEmbedFetcher.new
    clock = -> { Time.iso8601("2026-08-22T12:00:00+09:00") }
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      s3_client: s3,
      asset_bucket: "production-assets",
      embed_fetcher: fetcher,
      clock:
    )
    url = "https://example.com/article"

    first = api.call(event("GET", "/api/embed", query: { "url" => url }))
    second = api.call(event("GET", "/api/embed", query: { "url" => url }))

    assert_equal 200, first.fetch(:statusCode)
    assert_equal "Example", JSON.parse(first.fetch(:body)).fetch("title")
    assert_equal first.fetch(:body), second.fetch(:body)
    assert_equal [url], fetcher.requests
    assert_equal 1, s3.objects.length
  end

  def test_returns_not_found_for_unknown_routes
    response = @api.call(event("GET", "/api/unknown"))

    assert_equal 404, response.fetch(:statusCode)
  end

  def test_mutations_require_an_allowed_session_and_csrf_token
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      allowed_github_user_id: 630_181
    )

    unauthorized = api.call(json_event("POST", "/api/pages", { title: "new", body: "本文" }))
    assert_equal 401, unauthorized.fetch(:statusCode)

    denied_token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 999, "login" => "other", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    denied = api.call(json_event(
      "POST",
      "/api/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{denied_token}"],
      headers: { "content-type" => "application/json", "x-csrf-token" => "csrf-token" }
    ))
    assert_equal 403, denied.fetch(:statusCode)

    allowed_token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    missing_csrf = api.call(json_event(
      "POST",
      "/api/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{allowed_token}"]
    ))
    assert_equal 403, missing_csrf.fetch(:statusCode)

    allowed = api.call(json_event(
      "POST",
      "/api/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{allowed_token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    assert_equal 201, allowed.fetch(:statusCode)
    assert_equal "本文", @database.saved_requests.fetch(0).body
  end

  def test_github_oauth_creates_an_authenticated_session
    oauth = FakeOAuth.new
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      oauth:,
      session_codec: codec,
      redirect_uri: "https://weblog.ason.as/api/auth/github/callback",
      frontend_url: "https://weblog.ason.as",
      allowed_github_user_id: 630_181
    )

    login = api.call(event("GET", "/api/auth/github", query: { "return_to" => "/2026-08-22" }))
    oauth_cookie = login.fetch(:cookies).fetch(0).split(";", 2).fetch(0)
    oauth_token = oauth_cookie.split("=", 2).fetch(1)
    oauth_session = codec.read(oauth_token, kind: "oauth")
    callback = api.call(event(
      "GET",
      "/api/auth/github/callback",
      query: { "code" => "temporary", "state" => oauth_session.fetch("state") },
      cookies: [oauth_cookie]
    ))

    assert_equal 302, callback.fetch(:statusCode)
    assert_equal "https://weblog.ason.as/2026-08-22", callback.dig(:headers, "location")
    assert_equal "temporary", oauth.authentication_request.fetch(:code)

    session_cookie = callback.fetch(:cookies).find { |cookie| cookie.start_with?("weblog_authoring_session=") }
    session = api.call(event("GET", "/api/auth/session", cookies: [session_cookie.split(";", 2).fetch(0)]))
    auth = JSON.parse(session.fetch(:body))
    assert_equal true, auth.fetch("authenticated")
    assert_equal true, auth.fetch("can_edit")
    assert_equal "asonas", auth.fetch("login")
    refute_empty auth.fetch("csrf_token")
  end

  def test_rejects_an_oauth_callback_with_mismatched_state
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "oauth",
      attributes: { "state" => "expected", "verifier" => "verifier", "return_to" => "/" },
      ttl: 600
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      oauth: FakeOAuth.new,
      session_codec: codec,
      redirect_uri: "https://weblog.ason.as/api/auth/github/callback",
      frontend_url: "https://weblog.ason.as",
      allowed_github_user_id: 630_181
    )

    response = api.call(event(
      "GET",
      "/api/auth/github/callback",
      query: { "code" => "temporary", "state" => "unexpected" },
      cookies: ["weblog_authoring_oauth=#{token}"]
    ))

    assert_equal 422, response.fetch(:statusCode)
  end

  def test_logout_accepts_the_csrf_token_from_a_form_body
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "session",
      attributes: { "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      frontend_url: "https://weblog.ason.as"
    )
    logout_event = event("POST", "/api/auth/logout", cookies: ["weblog_authoring_session=#{token}"])
    logout_event["body"] = URI.encode_www_form(csrf_token: "csrf-token")

    response = api.call(logout_event)

    assert_equal 302, response.fetch(:statusCode)
    assert_equal "https://weblog.ason.as", response.dig(:headers, "location")
    assert_includes response.fetch(:cookies), "weblog_authoring_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax"
  end

  private

  def page_document(id:, name:, body:)
    WeblogAuthoring::PageDocument.new(
      id:,
      page_type: "named",
      name:,
      page_date: nil,
      title: nil,
      status: "published",
      created_at: Time.iso8601("2026-08-22T10:00:00+09:00"),
      updated_at: Time.iso8601("2026-08-22T11:00:00+09:00"),
      published_at: Time.iso8601("2026-08-22T11:00:00+09:00"),
      path: Pathname("content/pages/#{id}.md"),
      body:,
      links: WeblogAuthoring.extract_wiki_links(body)
    )
  end

  def json_event(method, path, payload = {}, cookies: nil, headers: nil, path_parameters: nil)
    event(method, path, path_parameters, cookies:, headers: { "content-type" => "application/json", **headers.to_h }).merge(
      "body" => JSON.generate(payload)
    )
  end

  def event(method, path, path_parameters = nil, query: nil, cookies: nil, headers: nil)
    {
      "rawPath" => path,
      "pathParameters" => path_parameters,
      "queryStringParameters" => query,
      "cookies" => cookies,
      "headers" => headers,
      "requestContext" => { "http" => { "method" => method } },
    }
  end
end
