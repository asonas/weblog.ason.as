# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_app"

require "fileutils"
require "rack/mock"

class TestDevelopmentApp < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-21T12:00:00+09:00")

  FakeS3Response = Data.define(:content_type, :body)
  FakeS3Object = Data.define(:key)
  FakeS3List = Data.define(:contents)

  StaticInboxSource = Data.define(:snapshot) do
    def fetch(**)
      snapshot
    end
  end

  def test_lists_cacheable_page_names
    status, headers, body = request("GET", "/api/page-names")
    unchanged_status, = request_with(
      app,
      "GET",
      "/api/page-names",
      headers: { "HTTP_IF_NONE_MATCH" => headers.fetch("etag") }
    )

    assert_equal 200, status
    assert_equal [], JSON.parse(body).fetch("names")
    assert_equal "no-cache", headers.fetch("cache-control")
    assert_equal 304, unchanged_status
  end

  def test_reports_page_generation_timings
    status, headers, _body = request("GET", "/api/pages")
    server_timing = headers.fetch("server-timing")
    entry = JSON.parse(root.join("log/authoring-development.log").read.lines.last)

    assert_equal 200, status
    %w[db summaries json].each do |name|
      assert_match(/(?:\A|, )#{name};dur=\d+(?:\.\d+)?/, server_timing)
    end
    assert_equal server_timing, entry.fetch("server_timing")
  end

  class FakeEmbedFetcher
    attr_reader :requests

    def initialize
      @requests = []
    end

    def fetch(url)
      @requests << url
      {
        "url" => url,
        "canonical_url" => url,
        "title" => "Example article",
        "description" => "Cached description",
        "image_url" => "https://example.com/card.jpg",
        "site_name" => "Example",
        "status" => "ready",
      }
    end
  end

  class FakeS3Client
    attr_reader :requests

    def initialize
      @requests = []
      @objects = {}
    end

    def get_object(bucket:, key:)
      @requests << { bucket:, key: }
      if key.start_with?("assets/embed-cache/") || key.start_with?("assets/inbox/.metadata/")
        body = @objects[key]
        raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") if body.nil?

        return FakeS3Response.new(content_type: "application/json", body: StringIO.new(body))
      end

      FakeS3Response.new(content_type: "image/jpeg", body: StringIO.new("image-data"))
    end

    def list_objects_v2(bucket:, prefix:)
      @requests << { bucket:, prefix: }
      FakeS3List.new(@objects.keys.grep(/^#{Regexp.escape(prefix)}/).sort.map { |key| FakeS3Object.new(key) })
    end

    def put_object(bucket:, key:, body:, content_type:)
      @requests << { bucket:, key:, body:, content_type: }
      @objects[key] = body
    end

    def add_object(key, body)
      @objects[key] = body
    end
  end

  class FakeOAuthClient
    attr_reader :authorization_request, :authentication_request

    def initialize(user_id: 630_181)
      @user_id = user_id
    end

    def authorization_url(**request)
      @authorization_request = request
      "https://github.com/login/oauth/authorize?#{URI.encode_www_form(state: request.fetch(:state))}"
    end

    def authenticate(**request)
      @authentication_request = request
      { "id" => @user_id, "login" => "asonas" }
    end
  end

  def test_oauth_login_authenticates_the_allowed_github_user
    oauth_client = FakeOAuthClient.new
    application = authenticated_app(oauth_client:)

    status, headers, _body = request_with(application, "GET", "/api/auth/github?return_to=%2F2026-08-21")
    cookie = response_cookie(headers)
    state = oauth_client.authorization_request.fetch(:state)

    assert_equal 302, status
    assert_equal "http://127.0.0.1:5173/api/auth/github/callback",
                 oauth_client.authorization_request.fetch(:redirect_uri)
    refute_empty oauth_client.authorization_request.fetch(:code_challenge)

    status, headers, _body = request_with(
      application,
      "GET",
      "/api/auth/github/callback?code=temporary-code&state=#{CGI.escape(state)}",
      headers: { "HTTP_COOKIE" => cookie }
    )
    cookie = response_cookie(headers)

    assert_equal 302, status
    assert cookie.start_with?("weblog.authoring.development.session=")
    assert_equal "http://127.0.0.1:5173/2026-08-21", headers.fetch("location")
    assert_equal "temporary-code", oauth_client.authentication_request.fetch(:code)
    refute_empty oauth_client.authentication_request.fetch(:code_verifier)

    status, _headers, body = request_with(
      application,
      "GET",
      "/api/auth/session",
      headers: { "HTTP_COOKIE" => cookie }
    )

    assert_equal 200, status
    assert_equal true, JSON.parse(body).fetch("authenticated")
    assert_equal "asonas", JSON.parse(body).fetch("login")
  end

  def test_mobile_upload_uses_bearer_auth_without_weakening_other_mutations
    oauth_client = FakeOAuthClient.new
    upload_s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    application = WeblogAuthoring::DevelopmentApp.application(
      root:, clock: -> { FIXED_TIME }, s3_client: upload_s3,
      oauth_client:, allowed_github_user_id: 630_181,
      session_secret: "test-session-secret-#{'x' * 64}"
    )
    cookie = login(application, oauth_client)
    _status, session_headers, session_body = request_with(
      application, "GET", "/api/auth/session", headers: { "HTTP_COOKIE" => cookie }
    )
    cookie = response_cookie(session_headers, fallback: cookie)
    csrf_token = JSON.parse(session_body).fetch("csrf_token")
    pairing_status, _headers, pairing_body = request_with(
      application, "POST", "/api/mobile/pairings", payload: {},
      headers: { "HTTP_COOKIE" => cookie, "HTTP_X_CSRF_TOKEN" => csrf_token }
    )
    assert_equal 201, pairing_status, pairing_body
    exchange_status, _headers, exchange_body = request_with(
      application, "POST", "/api/mobile/pairings/exchange",
      payload: { code: JSON.parse(pairing_body).fetch("code"), device_name: "iPhone" }
    )
    token = JSON.parse(exchange_body).fetch("token")
    upload_status, = request_with(
      application, "POST", "/api/mobile/uploads", payload: {
        client_upload_id: "11111111-2222-4333-8444-555555555555",
        content_type: "image/jpeg", size: 1024, sha256: "a" * 64,
        captured_at: FIXED_TIME.iso8601, captured_at_source: "photos",
      }, headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    )
    ordinary_mutation_status, = request_with(
      application, "POST", "/api/authoring/pages", payload: { title: "blocked", body: "body" }
    )

    assert_equal 201, exchange_status
    assert_equal 201, upload_status
    assert_equal 401, ordinary_mutation_status
  end

  def test_mobile_upload_validation_uses_problem_details
    oauth_client = FakeOAuthClient.new
    upload_s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    application = WeblogAuthoring::DevelopmentApp.application(
      root:, clock: -> { FIXED_TIME }, s3_client: upload_s3,
      oauth_client:, allowed_github_user_id: 630_181,
      session_secret: "test-session-secret-#{'x' * 64}"
    )
    cookie = login(application, oauth_client)
    _status, session_headers, session_body = request_with(
      application, "GET", "/api/auth/session", headers: { "HTTP_COOKIE" => cookie }
    )
    cookie = response_cookie(session_headers, fallback: cookie)
    csrf_token = JSON.parse(session_body).fetch("csrf_token")
    _status, _headers, pairing_body = request_with(
      application, "POST", "/api/mobile/pairings", payload: {},
      headers: { "HTTP_COOKIE" => cookie, "HTTP_X_CSRF_TOKEN" => csrf_token }
    )
    _status, _headers, exchange_body = request_with(
      application, "POST", "/api/mobile/pairings/exchange",
      payload: { code: JSON.parse(pairing_body).fetch("code"), device_name: "iPhone" }
    )
    token = JSON.parse(exchange_body).fetch("token")

    status, headers, body = request_with(
      application, "POST", "/api/mobile/uploads", payload: {
        client_upload_id: "11111111-2222-4333-8444-555555555555",
        content_type: "image/heic", size: 1024, sha256: "a" * 64,
        captured_at: FIXED_TIME.iso8601, captured_at_source: "photos",
      }, headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    )
    problem = JSON.parse(body)

    assert_equal 415, status
    assert_equal "application/problem+json", headers.fetch("content-type")
    assert_equal "unsupported_content_type", problem.fetch("code")

    status, headers, body = request_with(
      application, "POST", "/api/mobile/uploads", payload: {},
      headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "text/plain" }
    )
    assert_equal 415, status
    assert_equal "application/problem+json", headers.fetch("content-type")
    assert_equal "invalid_content_type", JSON.parse(body).fetch("code")

    env = Rack::MockRequest.env_for(
      "/api/mobile/uploads", method: "POST", input: "{",
      "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1:8000",
      "HTTP_AUTHORIZATION" => "Bearer #{token}"
    )
    status, headers, response_body = application.call(env)
    assert_equal 422, status
    assert_equal "application/problem+json", headers.fetch("content-type")
    assert_equal "invalid_json_body", JSON.parse(response_body.join).fetch("code")
  end

  def test_inbox_imports_recent_development_s3_manifests_idempotently
    key = "assets/inbox/2026/08/21/photo.jpg"
    s3_client.add_object(
      "assets/inbox/.metadata/upload-1.json",
      JSON.generate(
        "source" => "photo",
        "kind" => "photo",
        "source_id" => "upload-1",
        "occurred_at" => "2026-08-21T11:00:00+09:00",
        "payload" => {
          "inbox_key" => key,
          "preview_url" => "/#{key}",
          "captured_at_source" => "photos",
        }
      )
    )
    s3_client.add_object(
      "assets/inbox/.metadata/expired.json",
      JSON.generate(
        "source" => "photo",
        "kind" => "photo",
        "source_id" => "expired",
        "occurred_at" => "2026-08-14T11:59:59+09:00",
        "payload" => {
          "inbox_key" => "assets/inbox/2026/08/14/expired.jpg",
          "preview_url" => "/assets/inbox/2026/08/14/expired.jpg",
          "captured_at_source" => "photos",
        }
      )
    )

    first_status, _headers, first_body = request("GET", "/api/inbox")
    second_status, _headers, second_body = request("GET", "/api/inbox")

    assert_equal 200, first_status
    assert_equal 200, second_status
    first_items = JSON.parse(first_body).fetch("items")
    second_items = JSON.parse(second_body).fetch("items")
    assert_equal 1, first_items.length
    assert_equal first_items, second_items
    assert_equal "upload-1", first_items.fetch(0).fetch("source_id")
    assert_equal key, first_items.fetch(0).dig("payload", "inbox_key")
  end

  def test_oauth_session_survives_a_development_app_restart
    oauth_client = FakeOAuthClient.new
    first_application = WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:,
      oauth_client:,
      allowed_github_user_id: 630_181
    )
    cookie = login(first_application, oauth_client)

    restarted_application = WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:,
      oauth_client: FakeOAuthClient.new,
      allowed_github_user_id: 630_181
    )
    status, _headers, body = request_with(
      restarted_application,
      "GET",
      "/api/auth/session",
      headers: { "HTTP_COOKIE" => cookie }
    )

    assert_equal 200, status
    assert_equal true, JSON.parse(body).fetch("authenticated")
    assert_equal "asonas", JSON.parse(body).fetch("login")
    assert_equal 0o600, root.join("data/development/session-secret").stat.mode & 0o777
  end

  def test_oauth_callback_rejects_an_unexpected_state
    oauth_client = FakeOAuthClient.new
    application = authenticated_app(oauth_client:)
    _status, headers, _body = request_with(application, "GET", "/api/auth/github")

    status, _headers, body = request_with(
      application,
      "GET",
      "/api/auth/github/callback?code=temporary-code&state=unexpected",
      headers: { "HTTP_COOKIE" => response_cookie(headers) }
    )

    assert_equal 422, status
    assert_includes body, "stateが一致しません"
    assert_nil oauth_client.authentication_request
  end

  def test_oauth_callback_rejects_a_github_user_without_edit_permission
    oauth_client = FakeOAuthClient.new(user_id: 999)
    application = authenticated_app(oauth_client:)
    _status, headers, _body = request_with(application, "GET", "/api/auth/github")
    cookie = response_cookie(headers)
    state = oauth_client.authorization_request.fetch(:state)

    status, _headers, body = request_with(
      application,
      "GET",
      "/api/auth/github/callback?code=temporary-code&state=#{CGI.escape(state)}",
      headers: { "HTTP_COOKIE" => cookie }
    )

    assert_equal 403, status
    assert_includes body, "編集権限がありません"
  end

  def test_mutations_require_login_and_a_csrf_token
    oauth_client = FakeOAuthClient.new
    application = authenticated_app(oauth_client:)

    status, _headers, body = request_with(
      application,
      "POST",
      "/api/authoring/pages",
      payload: { page_type: "named", title: "private", body: "" }
    )

    assert_equal 401, status
    assert_includes body, "GitHubでログイン"

    cookie = login(application, oauth_client)
    status, _headers, body = request_with(
      application,
      "POST",
      "/api/authoring/pages",
      payload: { page_type: "named", title: "private", body: "" },
      headers: { "HTTP_COOKIE" => cookie }
    )

    assert_equal 403, status
    assert_includes body, "CSRFトークン"

    _, headers, body = request_with(
      application,
      "GET",
      "/api/auth/session",
      headers: { "HTTP_COOKIE" => cookie }
    )
    cookie = response_cookie(headers, fallback: cookie)
    csrf_token = JSON.parse(body).fetch("csrf_token")
    status, _headers, body = request_with(
      application,
      "POST",
      "/api/authoring/pages",
      payload: { page_type: "named", title: "private", body: "" },
      headers: { "HTTP_COOKIE" => cookie, "HTTP_X_CSRF_TOKEN" => csrf_token }
    )

    assert_equal 201, status
    assert_equal "private", JSON.parse(body).fetch("route")
  end

  def test_embed_metadata_is_fetched_once_and_cached_in_s3
    url = "https://example.com/article"

    status, _headers, first_body = request("GET", "/api/embed?url=#{CGI.escape(url)}")
    status2, _headers, second_body = request("GET", "/api/embed?url=#{CGI.escape(url)}")

    assert_equal 200, status
    assert_equal 200, status2
    assert_equal "Example article", JSON.parse(first_body).fetch("title")
    assert_equal JSON.parse(first_body), JSON.parse(second_body)
    assert_equal [url], embed_fetcher.requests
    cache_write = s3_client.requests.find { |entry| entry[:key].start_with?("assets/embed-cache/") && entry.key?(:body) }
    assert_equal "application/json; charset=utf-8", cache_write.fetch(:content_type)
  end

  def test_root_redirects_to_the_vite_frontend
    status, headers, body = request("GET", "/")

    assert_equal 307, status
    assert_equal "http://127.0.0.1:5173/", headers.fetch("location")
    assert_empty body
    assert database_path.file?
  end

  def test_root_redirect_does_not_depend_on_the_oauth_callback_url
    oauth_app = WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      oauth_client: Object.new,
      github_redirect_uri: "https://oauth.example/api/auth/github/callback"
    )

    status, headers, _body = request_with(oauth_app, "GET", "/")

    assert_equal 307, status
    assert_equal "http://127.0.0.1:5173/", headers.fetch("location")
  end

  def test_backend_does_not_serve_frontend_routes_or_bundled_assets
    frontend_paths = [
      "/editor/new",
      "/design-system",
      "/example-page",
      "/static/authoring/app.js",
      "/static/authoring/assets/imageUpload.worker.js",
    ]

    frontend_paths.each do |path|
      status, _headers, _body = request("GET", path)

      assert_equal 404, status, path
    end
  end

  def test_daily_button_opens_the_japanese_daily_template
    status, _headers, body = request("GET", "/api/editor/new?template=daily")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal "2026-08-21", editor.fetch("title")
    assert_equal "[[金曜日]] [[202608]] [[0821]] [[日記]]", editor.fetch("body")
    assert_empty editor.fetch("page_id")

  end

  def test_assets_are_read_from_the_development_bucket
    status, headers, body = request("GET", "/assets/asset_00685adfb0b588d4.jpg")

    assert_equal 200, status
    assert_equal "image/jpeg", headers.fetch("content-type")
    assert_includes headers.fetch("cache-control"), "immutable"
    assert_equal "image-data", body
    assert_equal [{
      bucket: "weblog-asonas-assets-dev-282782318939",
      key: "assets/asset_00685adfb0b588d4.jpg",
    }], s3_client.requests
  end

  def test_inbox_images_with_generated_hex_names_are_read_from_the_development_bucket
    filename = "becf3f799d14482090060d487cb9b952.png"

    status, headers, body = request("GET", "/assets/inbox/2026/08/28/#{filename}")

    assert_equal 200, status
    assert_equal "image/jpeg", headers.fetch("content-type")
    assert_equal "image-data", body
    assert_equal [{
      bucket: "weblog-asonas-assets-dev-282782318939",
      key: "assets/inbox/2026/08/28/#{filename}",
    }], s3_client.requests
  end

  def test_manually_runs_the_same_inbox_sync_contract_in_development
    status, _headers, body = request("POST", "/api/inbox/sync", payload: {})
    run_id = JSON.parse(body).fetch("run_id")

    sync_status, _headers, sync_body = request("GET", "/api/inbox/sync/#{run_id}")
    run = JSON.parse(sync_body)

    assert_equal 202, status
    assert_equal 200, sync_status
    assert_equal "succeeded", run.fetch("status")
    assert_equal(%w[bluesky raindrop c4p], run.fetch("sources").map { |source| source.fetch("source") })
  end

  def test_manually_syncs_configured_development_inbox_sources_into_local_storage
    item = WeblogAuthoring::InboxSync::Item.new(
      kind: "bookmark",
      source_id: "42",
      occurred_at: FIXED_TIME,
      payload: { "url" => "https://example.com", "title" => "Example" }
    )
    empty = WeblogAuthoring::InboxSync::Snapshot.new(items: [], complete: true, watermark: nil)
    application = WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:,
      inbox_sources: {
        "bluesky" => StaticInboxSource.new(empty),
        "raindrop" => StaticInboxSource.new(
          WeblogAuthoring::InboxSync::Snapshot.new(items: [item], complete: true, watermark: nil)
        ),
        "c4p" => StaticInboxSource.new(empty),
      }
    )

    status, = request_with(application, "POST", "/api/inbox/sync", payload: { "sources" => ["raindrop"] })
    list_status, _headers, body = request_with(application, "GET", "/api/inbox?source=raindrop")

    assert_equal 202, status
    assert_equal 200, list_status
    assert_equal ["42"], (JSON.parse(body).fetch("items").map { |listed| listed.fetch("source_id") })
  end

  def test_uploaded_images_with_generated_hex_names_are_read_from_the_development_bucket
    filename = "becf3f799d14482090060d487cb9b952.png"

    status, headers, body = request("GET", "/assets/uploads/2026/08/#{filename}")

    assert_equal 200, status
    assert_equal "image/jpeg", headers.fetch("content-type")
    assert_equal "image-data", body
    assert_equal [{
      bucket: "weblog-asonas-assets-dev-282782318939",
      key: "assets/uploads/2026/08/#{filename}",
    }], s3_client.requests
  end

  def test_first_downloaded_image_is_used_for_the_page_card
    FileUtils.mkdir_p(root.join("data/normalized"))
    FileUtils.mkdir_p(root.join("data/reports"))
    root.join("data/normalized/asset-manifest.json").write(JSON.generate("assets" => [{
      "id" => "asset_00685adfb0b588d4",
      "kind" => "image",
      "url" => "https://gyazo.com/example",
    }]))
    root.join("data/reports/asset-fetch-report.json").write(JSON.generate("results" => [{
      "id" => "asset_00685adfb0b588d4",
      "local_path" => "asset_00685adfb0b588d4.jpg",
    }]))
    application = WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:
    )
    json_request_with(
      application,
      "POST",
      "/api/authoring/pages",
      page_type: "named",
      title: "画像の記事",
      body: "[https://gyazo.com/example]"
    )

    status, _headers, body = request_with(application, "GET", "/api/pages")

    assert_equal 200, status
    assert_equal "/assets/asset_00685adfb0b588d4.jpg", JSON.parse(body).fetch("pages").fetch(0).fetch("image_url")
  end

  def test_first_uploaded_markdown_image_is_used_for_the_page_card
    json_request(
      "POST",
      "/api/authoring/pages",
      page_type: "named",
      title: "アップロード画像の記事",
      body: "本文\n\n![](/assets/uploads/2026/08/example.webp)"
    )

    status, _headers, body = request("GET", "/api/pages")

    assert_equal 200, status
    assert_equal "/assets/uploads/2026/08/example.webp",
                 JSON.parse(body).fetch("pages").fetch(0).fetch("image_url")
  end

  def test_unsafe_asset_filenames_are_rejected_before_s3
    status, _headers, _body = request("GET", "/assets/not-an-asset.jpg")

    assert_equal 404, status
    assert_empty s3_client.requests
  end

  def test_new_editor_saves_and_reads_a_page_from_the_database
    status, _headers, body = json_request(
      "POST",
      "/api/authoring/pages",
      page_type: "date",
      date: "2026-08-21",
      title: "最初の記事",
      body: "本文"
    )

    assert_equal 201, status
    page = JSON.parse(body)
    assert_equal "published", page.fetch("status")
    assert_equal "最初の記事", page.fetch("route")

    status, _headers, body = request("PATCH", "/api/authoring/pages/#{page.fetch("id")}", payload: {
      page_type: "date",
      date: "2026-08-21",
      title: "最初の記事",
      body: "更新した本文",
      expected_updated_at: page.fetch("updated_at"),
    })

    assert_equal 200, status
    assert_includes body, "最初の記事"

    restarted_app = WeblogAuthoring::DevelopmentApp.application(root:, clock: -> { FIXED_TIME })
    status, _headers, body = request_with(restarted_app, "GET", "/api/pages/#{page.fetch("id")}")

    assert_equal 200, status
    assert_equal "更新した本文", JSON.parse(body).fetch("body")
  end

  def test_get_api_bootstraps_home_and_editor_for_vite
    status, headers, body = request("GET", "/api/pages")

    assert_equal 200, status
    assert_equal "application/json", headers.fetch("content-type")
    home = JSON.parse(body)
    assert_equal "home", home.fetch("mode")
    assert_equal [], home.fetch("pages")
    assert_equal false, home.fetch("has_newer")
    assert_equal false, home.fetch("has_older")

    _, _headers, body = json_request(
      "POST",
      "/api/authoring/pages",
      page_type: "date",
      date: "2026-08-21",
      title: "Viteから開く記事",
      body: "本文 [[日記]] [[水曜日]] [[2026-08-21]] [[202608]] [[0827]] #開発\n[https://example.com/photo.jpg#.png]"
    )
    page = JSON.parse(body)

    status, _headers, body = request("GET", "/api/pages")
    summary = JSON.parse(body).fetch("pages").fetch(0)
    assert_equal 200, status
    assert_equal "2026-08-21T12:00:00.000000000+09:00", summary.fetch("created_at")
    assert_equal "本文 日記 水曜日 2026-08-21 202608 0827", summary.fetch("excerpt")
    assert_nil summary.fetch("image_url")
    assert_equal ["開発"], JSON.parse(request("GET", "/api/tags").last).fetch("tags")
    assert_equal [{ "year" => 2026, "months" => [8] }], JSON.parse(request("GET", "/api/archive").last).fetch("archive")

    status, _headers, body = request("GET", "/api/pages/#{page.fetch("id")}")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal "editor", editor.fetch("mode")
    assert_equal page.fetch("id"), editor.fetch("page_id")
    assert_equal "本文 [[日記]] [[水曜日]] [[2026-08-21]] [[202608]] [[0827]] #開発\n[https://example.com/photo.jpg#.png]", editor.fetch("body")

    status, _headers, body = request("GET", "/api/editor/new")

    assert_equal 200, status
    fresh_editor = JSON.parse(body)
    assert_equal "editor", fresh_editor.fetch("mode")
    assert_equal "named", fresh_editor.fetch("page_type")
    assert_empty fresh_editor.fetch("date")
    assert_empty fresh_editor.fetch("page_id")
  end

  def test_cover_selection_is_returned_by_save_and_editor_apis
    status, _headers, body = json_request(
      "POST",
      "/api/authoring/pages",
      page_type: "named",
      name: "カバー記事",
      body: "本文",
      cover_mode: "explicit",
      cover_image_url: "/assets/uploads/cover.jpg"
    )
    saved = JSON.parse(body)

    assert_equal 201, status
    assert_equal "explicit", saved.fetch("cover_mode")
    assert_equal "/assets/uploads/cover.jpg", saved.fetch("resolved_cover_image_url")

    status, _headers, body = request("GET", "/api/pages/#{saved.fetch('id')}")
    editor = JSON.parse(body)

    assert_equal 200, status
    assert_equal "/assets/uploads/cover.jpg", editor.fetch("cover_image_url")
    assert_equal "/assets/uploads/cover.jpg", editor.fetch("resolved_cover_image_url")
  end

  def test_editor_api_includes_imported_line_update_times
    page = app_database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named",
      name: "Scrapboxからの記事",
      body: "最初の行\n次の行"
    ))
    app_database.replace_scrapbox_line_metadata(
      page.id,
      body_hash: Digest::SHA256.hexdigest(page.body),
      lines: [
        { created_at: Time.at(1_700_000_000).utc, updated_at: Time.at(1_700_000_001).utc, user_id: "user-1" },
        { created_at: Time.at(1_700_000_010).utc, updated_at: Time.at(1_700_000_011).utc, user_id: "user-1" },
      ]
    )

    status, _headers, body = request("GET", "/api/routes/#{URI.encode_uri_component("Scrapboxからの記事")}")

    assert_equal 200, status
    assert_equal ["2023-11-15T07:13:21.000000000+09:00", "2023-11-15T07:13:31.000000000+09:00"],
                 JSON.parse(body).fetch("line_updated_at")
  end

  def test_atom_feed_contains_article_body_and_excludes_empty_pages
    json_request("POST", "/api/authoring/pages", page_type: "named", title: "記事", body: "本文 **です**")
    json_request("POST", "/api/authoring/pages", page_type: "named", title: "空のハブ", body: "")

    status, headers, body = request("GET", "/feed.xml")

    assert_equal 200, status
    assert_equal "application/atom+xml; charset=utf-8", headers.fetch("content-type")
    assert_includes body, '<feed xmlns="http://www.w3.org/2005/Atom">'
    assert_includes body, "<title>記事</title>"
    assert_includes body, "本文 &lt;strong&gt;です&lt;/strong&gt;"
    refute_includes body, "空のハブ"
  end

  def test_home_returns_only_thirty_recent_pages_and_a_month_archive
    31.times do |index|
      app_database.save(WeblogAuthoring::SaveRequest.new(
        page_type: "named",
        name: "article-#{index}",
        body: ""
      ))
    end

    status, _headers, body = request("GET", "/api/pages")
    home = JSON.parse(body)

    assert_equal 200, status
    assert_equal 30, home.fetch("pages").length
    assert_equal [{ "year" => 2026, "months" => [8] }], JSON.parse(request("GET", "/api/archive").last).fetch("archive")
  end

  def test_month_window_can_page_toward_newer_and_older_articles
    january = app_database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "january", body: ""))
    february = app_database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "february", body: ""))
    march = app_database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "march", body: ""))
    SQLite3::Database.new(database_path.to_s) do |sqlite|
      sqlite.execute("UPDATE pages SET updated_at = ? WHERE id = ?", ["2025-01-31T12:00:00.000000000+09:00", january.id])
      sqlite.execute("UPDATE pages SET updated_at = ? WHERE id = ?", ["2025-02-01T12:00:00.000000000+09:00", february.id])
      sqlite.execute("UPDATE pages SET updated_at = ? WHERE id = ?", ["2025-03-01T12:00:00.000000000+09:00", march.id])
    end

    status, _headers, body = request("GET", "/api/pages?month=2025-01")
    january_window = JSON.parse(body)

    assert_equal 200, status
    assert_equal(["january"], january_window.fetch("pages").map { |page| page.fetch("title") })
    assert_equal true, january_window.fetch("has_newer")
    assert_equal false, january_window.fetch("has_older")

    cursor = CGI.escape(january_window.fetch("newer_cursor"))
    newer_window = JSON.parse(request("GET", "/api/pages?after=#{cursor}").last)
    assert_equal(%w[march february], newer_window.fetch("pages").map { |page| page.fetch("title") })
    assert_equal false, newer_window.fetch("has_newer")
  end

  def test_named_page_accepts_an_empty_body_and_can_be_loaded_by_route
    status, _headers, body = json_request(
      "POST",
      "/api/authoring/pages",
      page_type: "named",
      title: "test2",
      body: ""
    )

    assert_equal 201, status
    page = JSON.parse(body)
    assert_equal "test2", page.fetch("route")

    status, _headers, body = request("GET", "/api/routes/test2")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal page.fetch("id"), editor.fetch("page_id")
    assert_equal "", editor.fetch("body")
  end

  def test_missing_route_opens_an_unpersisted_editor_with_the_route_as_its_title
    status, _headers, body = request("GET", "/api/routes/foobar")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal "editor", editor.fetch("mode")
    assert_equal "foobar", editor.fetch("name")
    assert_equal "foobar", editor.fetch("title")
    assert_empty editor.fetch("page_id")
    assert_nil app_database.find_route("foobar")

  end

  def test_editor_returns_cards_for_existing_wiki_link_targets
    _status, _headers, target_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "target", body: ""
    )
    target = JSON.parse(target_body)
    _status, _headers, source_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "source", body: "[[target]] [[missing]]"
    )
    source = JSON.parse(source_body)

    assert_equal(["target"], source.fetch("linked_pages").map { |page| page.fetch("title") })
    refute source.fetch("linked_pages_has_more")

    status, _headers, body = request(
      "GET", "/api/related?route=source&excluding_id=#{source.fetch("id")}&offset=0"
    )

    assert_equal 200, status
    linked_page = JSON.parse(body).fetch("pages").fetch(0)
    assert_equal target.fetch("id"), linked_page.fetch("id")
    assert_equal "target", linked_page.fetch("route")

    status, _headers, body = request(
      "GET", "/api/related?route=target&excluding_id=#{target.fetch("id")}&offset=0"
    )

    assert_equal 200, status
    related_page = JSON.parse(body).fetch("pages").fetch(0)
    assert_equal source.fetch("id"), related_page.fetch("id")
    assert_equal "source", related_page.fetch("route")
  end

  def test_missing_route_returns_pages_that_link_to_its_name
    _status, _headers, source_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "source", body: "[[202608]]"
    )
    source = JSON.parse(source_body)

    status, _headers, body = request("GET", "/api/related?route=202608&offset=0")

    assert_equal 200, status
    related = JSON.parse(body)
    assert_equal([source.fetch("id")], related.fetch("pages").map { |page| page.fetch("id") })
  end

  def test_missing_route_requests_its_related_pages
    status, _headers, body = request("GET", "/api/routes/202608")

    assert_equal 200, status
    assert JSON.parse(body).fetch("linked_pages_has_more")
  end

  def test_editor_returns_other_pages_that_share_its_wiki_links
    json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "日記", body: ""
    )
    json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "2026-08-08",
      body: "[[202608]] [[0808]] [[日記]]"
    )
    _status, _headers, sibling_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "2026-08-07",
      body: "[[202608]] [[0807]] [[日記]]"
    )
    sibling = JSON.parse(sibling_body)
    json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "unrelated", body: "[[other]]"
    )

    page = app_database.find_route("2026-08-08")
    status, _headers, body = request(
      "GET", "/api/related?route=2026-08-08&excluding_id=#{page.id}&offset=0"
    )

    assert_equal 200, status
    related = JSON.parse(body).fetch("pages")
    assert_includes related.map { |page| page.fetch("id") }, sibling.fetch("id")
    assert_equal ["202608"], related.find { |page| page.fetch("id") == sibling.fetch("id") }.fetch("related_by")
    assert_equal ["日記"], related.find { |page| page.fetch("route") == "日記" }.fetch("related_by")
    refute_includes related.map { |page| page.fetch("route") }, "unrelated"
  end

  def test_editor_returns_other_pages_that_share_an_external_url
    shared_url = "https://example.com/articles/one"
    json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "source", body: "[#{shared_url}]"
    )
    _status, _headers, sibling_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "sibling", body: "also #{shared_url}"
    )
    sibling = JSON.parse(sibling_body)
    json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "unrelated", body: "https://example.net/other"
    )

    page = app_database.find_route("source")
    status, _headers, body = request(
      "GET", "/api/related?route=source&excluding_id=#{page.id}&offset=0"
    )

    assert_equal 200, status
    related = JSON.parse(body).fetch("pages")
    assert_equal([sibling.fetch("id")], related.map { |page| page.fetch("id") })
    assert_equal [shared_url], related.fetch(0).fetch("related_urls")
  end

  def test_page_api_returns_not_modified_for_a_matching_etag
    _status, _headers, body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "target", body: "本文"
    )
    page = JSON.parse(body)

    status, headers, _body = request("GET", "/api/pages/#{page.fetch("id")}")
    unchanged_status, _unchanged_headers, unchanged_body = request_with(
      app,
      "GET",
      "/api/pages/#{page.fetch("id")}",
      headers: { "HTTP_IF_NONE_MATCH" => headers.fetch("etag") }
    )

    assert_equal 200, status
    assert_equal 304, unchanged_status
    assert_empty unchanged_body
  end

  def test_related_pages_are_returned_fifty_at_a_time
    _status, _headers, target_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "target", body: ""
    )
    target = JSON.parse(target_body)
    51.times do |index|
      json_request(
        "POST", "/api/authoring/pages", page_type: "named", title: "source-#{index}", body: "[[target]]"
      )
    end

    status, _headers, body = request(
      "GET", "/api/related?route=target&excluding_id=#{target.fetch("id")}&offset=0"
    )

    assert_equal 200, status
    first_page = JSON.parse(body)
    assert_equal 50, first_page.fetch("pages").length
    assert first_page.fetch("has_more")

    status, _headers, body = request(
      "GET", "/api/related?route=target&excluding_id=#{target.fetch("id")}&offset=50"
    )

    assert_equal 200, status
    second_page = JSON.parse(body)
    assert_equal 1, second_page.fetch("pages").length
    refute second_page.fetch("has_more")
  end

  def test_rename_api_updates_the_route_and_existing_references
    _status, _headers, target_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "old", body: ""
    )
    target = JSON.parse(target_body)
    _status, _headers, source_body = json_request(
      "POST", "/api/authoring/pages", page_type: "named", title: "source", body: "[[old]]"
    )
    source = JSON.parse(source_body)

    status, _headers, body = json_request(
      "POST",
      "/api/rename",
      page_id: target.fetch("id"),
      name: "new",
      body: "",
      expected_updated_at: target.fetch("updated_at")
    )

    assert_equal 200, status
    assert_equal "new", JSON.parse(body).fetch("route")
    assert_equal "[[new]]", app_database.find(source.fetch("id")).body
  end

  def test_html_like_routes_are_rejected_without_reflection_or_persistence
    status, _headers, body = request("GET", "/api/routes/%3Cscript%3Ealert(1)%3Cscript%3E")

    assert_equal 404, status
    refute_includes body, "<script>"
    assert_nil app_database.find_route("<script>alert(1)<script>")

    status, _headers, body = request("GET", "/%3Cscript%3Ealert(1)%3Cscript%3E")

    assert_equal 404, status
    refute_includes body, "<script>"
  end

  def test_failed_requests_are_written_to_the_development_log
    status, _headers, _body = json_request(
      "POST",
      "/api/authoring/pages",
      page_type: "named",
      title: "broken"
    )

    assert_equal 422, status
    entry = JSON.parse(root.join("log/authoring-development.log").read.lines.last)
    assert_equal "POST", entry.fetch("method")
    assert_equal "/api/authoring/pages", entry.fetch("path")
    assert_equal 422, entry.fetch("status")
    assert_includes entry.fetch("error"), "body は必須です"
  end

  private

  def request(method, path, payload: nil)
    request_with(app, method, path, payload:)
  end

  def request_with(application, method, path, payload: nil, headers: {})
    env = Rack::MockRequest.env_for(
      path,
      method:,
      input: payload.nil? ? nil : JSON.generate(payload),
      "CONTENT_TYPE" => payload.nil? ? nil : "application/json; charset=utf-8",
      "HTTP_HOST" => "127.0.0.1:8000"
    )
    env.merge!(headers)
    status, headers, response_body = application.call(env)
    [status, headers.transform_keys(&:downcase), response_body.join]
  end

  def authenticated_app(oauth_client:)
    WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:,
      oauth_client:,
      allowed_github_user_id: 630_181,
      session_secret: "test-session-secret-#{'x' * 64}"
    )
  end

  def login(application, oauth_client)
    _status, headers, _body = request_with(application, "GET", "/api/auth/github")
    cookie = response_cookie(headers)
    state = oauth_client.authorization_request.fetch(:state)
    _status, headers, _body = request_with(
      application,
      "GET",
      "/api/auth/github/callback?code=temporary-code&state=#{CGI.escape(state)}",
      headers: { "HTTP_COOKIE" => cookie }
    )
    response_cookie(headers)
  end

  def response_cookie(headers, fallback: nil)
    headers.fetch("set-cookie", fallback).to_s.split(";", 2).first
  end

  def json_request(method, path, **payload)
    request(method, path, payload:)
  end

  def json_request_with(application, method, path, **payload)
    request_with(application, method, path, payload:)
  end

  def app
    @app ||= WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:,
      asset_bucket: "weblog-asonas-assets-dev-282782318939",
      embed_fetcher:
    )
  end

  def s3_client
    @s3_client ||= FakeS3Client.new
  end

  def embed_fetcher
    @embed_fetcher ||= FakeEmbedFetcher.new
  end

  def root
    @root ||= Pathname(Dir.mktmpdir("weblog-development-app"))
  end

  def database_path
    root.join("data/development/authoring.sqlite3")
  end

  def app_database
    WeblogAuthoring::DevelopmentDatabase.new(database_path, content_dir: root.join("content"), clock: -> { FIXED_TIME })
  end

  def teardown
    FileUtils.remove_entry(root.to_s) if defined?(@root) && root.exist?
  end
end
