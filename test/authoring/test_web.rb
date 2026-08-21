# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/web"

require "fileutils"
require "json"
require "rack/mock"
require "tmpdir"

class TestWeb < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T12:00:00+09:00")

  def test_editor_today_renders_react_wysiwyg_shell_without_preview
    status, headers, body = request("GET", "/editor/today")

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
    assert_includes body, 'href="#main"'
    assert_includes body, 'id="authoring-root"'
    assert_includes body, 'id="authoring-data"'
    refute_includes body, 'id="preview"'
    refute_includes body, "プレビュー"
    refute_includes body, "下書きを保存"
  end

  def test_management_page_exposes_minimal_page_creation_and_filters
    status, _headers, body = request("GET", "/manage")

    assert_equal 200, status
    assert_includes body, 'href="/editor/new?type=named"'
    assert_includes body, 'href="/editor/today?template=daily"'
    assert_includes body, 'name="empty"'
    refute_includes body, 'name="status"'
    assert_includes body, "問題はありません"
  end

  def test_static_assets_are_allowlisted_and_keep_accessibility_behaviors
    status, headers, css = request("GET", "/static/authoring/app.css")
    assert_equal 200, status
    assert_equal "text/css; charset=utf-8", headers.fetch("content-type")
    assert_includes css, ":focus-visible"
    assert_includes css, ".wysiwyg-editor"
    refute_includes css, ".preview-panel"

    status, headers, javascript = request("GET", "/static/authoring/app.js")
    assert_equal 200, status
    assert_equal "application/javascript; charset=utf-8", headers.fetch("content-type")
    assert_includes javascript, "save-and-publish"
    assert_includes javascript, "aria-multiline"
    assert_includes javascript, "beforeunload"

    assert_equal 404, request("GET", "/static/authoring/secret.txt").first
  end

  def test_home_opens_unsaved_today_then_saved_today_editor
    status, headers, body = request("GET", "/")

    assert_equal 302, status
    assert_equal "/editor/today", headers.fetch("location")
    assert_empty body

    save_status, _save_headers, saved_body = json_request(
      "/api/save",
      page_type: "date",
      date: "2026-01-01",
      title: "今日",
      body: "本文"
    )
    assert_equal 200, save_status
    page = JSON.parse(saved_body)

    status, headers, = request("GET", "/")

    assert_equal 302, status
    assert_equal "/editor/#{page.fetch("id")}", headers.fetch("location")
  end

  def test_preview_renders_unsaved_links_without_writing_content_or_database
    status, headers, body = json_request(
      "/api/preview",
      page_type: "date",
      date: "2026-01-01",
      body: "[[page-a]]"
    )

    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
    payload = JSON.parse(body)
    assert_includes payload.fetch("html"), 'href="/page-a"'
    assert_includes payload.fetch("html"), 'target="_blank"'
    assert_empty payload.fetch("errors")
    refute content_dir.exist?
    refute database_path.exist?
  end

  def test_daily_template_is_generated_for_today
    status, _headers, body = request("GET", "/editor/today?template=daily")

    assert_equal 200, status
    assert_includes body, '"title":"2026-01-01"'
    assert_includes body, '[[木曜日]]'
    assert_includes body, '[[202601]] [[0101]] [[日記]]'
  end

  def test_title_confirmation_saves_and_publishes_a_named_page
    status, _headers, body = json_request(
      "/api/save-and-publish",
      page_type: "named",
      title: "page-b",
      body: "page-bの本文"
    )

    assert_equal 200, status
    page = JSON.parse(body)
    assert_equal "page-b", page.fetch("name")
    assert_equal "published", page.fetch("status")
    assert root_site_path("page-b").join("index.html").exist?
    assert_includes root_site_path("page-b").join("index.html").read(encoding: "UTF-8"), "page-bの本文"
  end

  def test_date_route_is_readable_after_title_confirmation
    status, _headers, body = json_request(
      "/api/save-and-publish",
      page_type: "date",
      date: "2026-01-01",
      title: "元日",
      body: "本文"
    )

    assert_equal 200, status
    assert_equal "2026-01-01", JSON.parse(body).fetch("route")

    status, _headers, body = request("GET", "/2026-01-01")
    assert_equal 200, status
    assert_includes body, "元日"
    assert_includes body, "本文"
  end

  def test_save_creates_empty_link_target_and_local_backlink
    status, _headers, body = json_request(
      "/api/save",
      page_type: "date",
      date: "2026-01-01",
      title: "今日",
      body: "[[page-a]]"
    )

    assert_equal 200, status
    JSON.parse(body)
    assert content_dir.join("2026-01-01.md").exist?
    assert content_dir.join("page-a.md").exist?

    status, _headers, body = request("GET", "/page-a")

    assert_equal 200, status
    assert_includes body, "page-a"
    assert_includes body, "まだ内容がありません"
    assert_includes body, "2026-01-01"
  end

  def test_local_missing_named_route_is_an_empty_page_without_persistence
    status, _headers, body = request("GET", "/page-b")

    assert_equal 200, status
    assert_includes body, "page-b"
    assert_includes body, "まだ内容がありません"
    refute content_dir.exist?
    refute database_path.exist?
  end

  def test_named_page_can_be_opened_from_management_and_has_a_safe_encoded_route
    status, _headers, body = request("GET", "/editor/new?type=named&name=hello%20world")

    assert_equal 200, status
    assert_includes body, '"page_type":"named"'
    assert_includes body, '"name":"hello world"'
    refute_includes body, 'id="title"'

    status, _headers, body = json_request(
      "/api/save",
      page_type: "named",
      name: "hello world",
      body: "本文"
    )
    assert_equal 200, status
    assert_equal "hello world", JSON.parse(body).fetch("name")

    status, _headers, body = request("GET", "/hello%20world")
    assert_equal 200, status
    assert_includes body, "本文"
  end

  def test_api_requires_json_and_loopback_origin
    status, _headers, body = request("POST", "/api/preview", body: "{}", content_type: "text/plain")

    assert_equal 415, status
    assert_equal "application/json; charset=utf-8", _headers.fetch("content-type")
    assert_includes JSON.parse(body).fetch("error"), "Content-Type"

    status, _headers, body = json_request("/api/preview", { body: "text" }, origin: "https://example.com")

    assert_equal 403, status
    assert_includes body, "loopback"

    status, _headers, body = json_request("/api/preview", { body: "text" }, host: "example.com")

    assert_equal 403, status
    assert_includes body, "localhost"
  end

  def test_api_validation_errors_identify_the_input_field
    status, _headers, body = json_request(
      "/api/save",
      page_type: "named",
      name: "bad/name",
      body: "本文"
    )

    assert_equal 422, status
    assert JSON.parse(body).fetch("errors").key?("name")
  end

  def test_route_decoding_rejects_slashes_and_does_not_decode_twice
    status, = request("GET", "/a%2Fb")
    assert_equal 404, status

    status, _headers, body = request("GET", "/a%252Fb")
    assert_equal 200, status
    assert_includes body, "a%2Fb"

    assert_equal 404, request("GET", "/%2e%2e").first
    assert_equal 404, request("GET", "/bad%ZZ").first
    assert_equal 404, request("GET", "/nested/path").first
  end

  def test_html_escapes_editor_values
    status, = json_request(
      "/api/save",
      page_type: "date",
      date: "2026-01-01",
      title: "<script>alert(1)</script>",
      body: "<script>alert(2)</script>"
    )
    assert_equal 200, status

    status, _headers, body = request("GET", "/editor/today")

    assert_equal 200, status
    refute_includes body, "<script>alert(1)</script>"
    refute_includes body, "<script>alert(2)</script>"
    assert_includes body, '\\u003cscript\\u003e'
  end

  private

  def request(method, path, body: nil, content_type: nil, origin: nil, host: "127.0.0.1:8000")
    env = Rack::MockRequest.env_for(
      path.match?(%r{%(?![0-9A-Fa-f]{2})}) ? "/" : path,
      method:,
      input: body,
      "CONTENT_TYPE" => content_type,
      "HTTP_HOST" => host,
      "HTTP_ORIGIN" => origin
    )
    env["PATH_INFO"] = path.split("?", 2).first
    status, headers, response_body = app.call(env)
    [status, headers.transform_keys(&:downcase), response_body.join]
  end

  def json_request(path, payload = nil, origin: nil, host: "127.0.0.1:8000", **keyword_payload)
    payload = keyword_payload if payload.nil?
    request(
      "POST",
      path,
      body: JSON.generate(payload),
      content_type: "application/json; charset=utf-8",
      origin:,
      host:
    )
  end

  def app
    @app ||= WeblogAuthoring::WebApp.new(service)
  end

  def service
    content_dir = tmpdir.join("content")
    repository = WeblogAuthoring::ContentRepository.new(
      content_dir,
      tmpdir.join("data/index/authoring.sqlite3"),
      -> { FIXED_TIME }
    )
    publisher = WeblogAuthoring::StaticPublisher.new(
      tmpdir.join("site"),
      release_manifest_path: content_dir.join(".authoring-release.json")
    )
    WeblogAuthoring::AuthoringService.new(repository, publisher, clock: -> { FIXED_TIME })
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("weblog-authoring-web"))
  end

  def content_dir
    tmpdir.join("content")
  end

  def database_path
    tmpdir.join("data/index/authoring.sqlite3")
  end

  def root_site_path(route)
    tmpdir.join("site", route)
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end
end
