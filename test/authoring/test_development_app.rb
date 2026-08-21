# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_app"

require "fileutils"
require "rack/mock"

class TestDevelopmentApp < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-21T12:00:00+09:00")

  def test_root_shows_new_page_button_and_creates_the_development_database
    status, _headers, body = request("GET", "/")

    assert_equal 200, status
    assert_includes body, 'href="/editor/new"'
    assert_includes body, 'aria-label="新しい記事を作成"'
    assert database_path.file?
  end

  def test_new_editor_saves_and_reads_a_page_from_the_database
    status, _headers, body = request("GET", "/editor/new")

    assert_equal 200, status
    assert_includes body, '"mode":"editor"'
    assert_includes body, '"page_id":""'
    refute_includes body, "プレビュー"

    status, _headers, body = json_request(
      "POST",
      "/api/pages",
      page_type: "date",
      date: "2026-08-21",
      title: "最初の記事",
      body: "本文"
    )

    assert_equal 201, status
    page = JSON.parse(body)
    assert_equal "published", page.fetch("status")
    assert_equal "2026-08-21", page.fetch("route")

    status, _headers, body = request("PATCH", "/api/pages/#{page.fetch("id")}", payload: {
      page_type: "date",
      date: "2026-08-21",
      title: "最初の記事",
      body: "更新した本文",
      expected_updated_at: page.fetch("updated_at")
    })

    assert_equal 200, status
    assert_includes body, "2026-08-21"

    restarted_app = WeblogAuthoring::DevelopmentApp.application(root:, clock: -> { FIXED_TIME })
    status, _headers, body = request_with(restarted_app, "GET", "/editor/#{page.fetch("id")}")

    assert_equal 200, status
    assert_includes body, "更新した本文"
  end

  def test_get_api_bootstraps_home_and_editor_for_vite
    status, headers, body = request("GET", "/api/pages")

    assert_equal 200, status
    assert_equal "application/json", headers.fetch("content-type")
    assert_equal({ "mode" => "home", "pages" => [] }, JSON.parse(body))

    status, _headers, body = json_request(
      "POST",
      "/api/pages",
      page_type: "date",
      date: "2026-08-21",
      title: "Viteから開く記事",
      body: "本文"
    )
    page = JSON.parse(body)

    status, _headers, body = request("GET", "/api/pages/#{page.fetch("id")}")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal "editor", editor.fetch("mode")
    assert_equal page.fetch("id"), editor.fetch("page_id")
    assert_equal "本文", editor.fetch("body")

    status, _headers, body = request("GET", "/api/editor/new")

    assert_equal 200, status
    fresh_editor = JSON.parse(body)
    assert_equal "editor", fresh_editor.fetch("mode")
    assert_equal "2026-08-21", fresh_editor.fetch("date")
    assert_empty fresh_editor.fetch("page_id")
  end

  private

  def request(method, path, payload: nil)
    request_with(app, method, path, payload:)
  end

  def request_with(application, method, path, payload: nil)
    env = Rack::MockRequest.env_for(
      path,
      method:,
      input: payload.nil? ? nil : JSON.generate(payload),
      "CONTENT_TYPE" => payload.nil? ? nil : "application/json; charset=utf-8",
      "HTTP_HOST" => "127.0.0.1:8000"
    )
    status, headers, response_body = application.call(env)
    [status, headers.transform_keys(&:downcase), response_body.join]
  end

  def json_request(method, path, **payload)
    request(method, path, payload:)
  end

  def app
    @app ||= WeblogAuthoring::DevelopmentApp.application(root:, clock: -> { FIXED_TIME })
  end

  def root
    @root ||= Pathname(Dir.mktmpdir("weblog-development-app"))
  end

  def database_path
    root.join("data/development/authoring.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(root.to_s) if defined?(@root) && root.exist?
  end
end
