# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/app"

require "fileutils"
require "json"
require "rack/mock"
require "tmpdir"

class TestAuthoringEndToEnd < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T12:00:00+09:00")

  def test_write_and_read_wiki_links_and_backlinks_through_rack
    status, _headers, body = json_request(
      "/api/save",
      page_type: "date",
      date: "2026-01-01",
      title: "今日",
      body: "今日から[[page-a]]へリンク"
    )
    assert_equal 200, status
    date_page = JSON.parse(body)

    status, _headers, body = request("GET", "/page-a")
    assert_equal 200, status
    assert_includes body, "まだ内容がありません"
    assert_includes body, "2026-01-01"

    status, _headers, body = json_request(
      "/api/save",
      page_type: "named",
      name: "page-b",
      body: "page-bから[[page-a]]へリンク"
    )
    assert_equal 200, status

    status, _headers, body = request("GET", "/page-a")
    assert_equal 200, status
    assert_includes body, "2026-01-01"
    assert_includes body, "page-b"
    assert_equal "2026-01-01", date_page.fetch("route")
  end

  def test_preview_and_virtual_page_do_not_persist_their_target
    status, _headers, body = json_request(
      "/api/preview",
      page_type: "date",
      date: "2026-01-01",
      body: "未保存から[[page-c]]へ"
    )
    assert_equal 200, status
    assert_includes JSON.parse(body).fetch("html"), 'href="/page-c"'

    status, _headers, body = request("GET", "/page-c")
    assert_equal 200, status
    assert_includes body, "まだ内容がありません"
    refute root.join("content/page-c.md").exist?
    assert_empty WeblogAuthoring::AuthoringDatabase.new(database_path).search("page-c")
  end

  def test_publish_edit_restart_and_unpublish_keep_public_state_explicit
    status, _headers, body = json_request(
      "/api/save",
      page_type: "date",
      date: "2026-01-01",
      body: "最初の公開本文"
    )
    assert_equal 200, status
    page = JSON.parse(body)

    status, _headers, body = json_request(
      "/api/publish",
      page_id: page.fetch("id"),
      expected_updated_at: page.fetch("updated_at")
    )
    assert_equal 200, status
    assert_equal "published", JSON.parse(body).fetch("status")
    assert_includes root.join("site/2026-01-01/index.html").read(encoding: "UTF-8"), "最初の公開本文"

    status, _headers, body = json_request(
      "/api/save",
      page_id: page.fetch("id"),
      page_type: "date",
      date: "2026-01-01",
      body: "未公開の編集"
    )
    assert_equal 200, status
    assert_includes root.join("site/2026-01-01/index.html").read(encoding: "UTF-8"), "最初の公開本文"
    refute_includes root.join("site/2026-01-01/index.html").read(encoding: "UTF-8"), "未公開の編集"

    restarted_app = WeblogAuthoring::Application.build(root:, clock: -> { FIXED_TIME })
    restarted = request_with(restarted_app, "GET", "/editor/#{page.fetch("id")}")
    assert_equal 200, restarted.fetch(0)
    assert_includes restarted.fetch(2), "未公開の編集"

    status, _headers, body = json_request(
      "/api/publish",
      page_id: page.fetch("id")
    )
    assert_equal 200, status
    assert_includes root.join("site/2026-01-01/index.html").read(encoding: "UTF-8"), "未公開の編集"

    status, _headers, body = json_request("/api/unpublish", page_id: page.fetch("id"))
    assert_equal 200, status
    assert_equal "draft", JSON.parse(body).fetch("status")
    refute root.join("site/2026-01-01/index.html").exist?
  end

  def test_application_rebuilds_deleted_index_from_markdown
    status, _headers, body = json_request(
      "/api/save",
      page_type: "date",
      date: "2026-01-01",
      body: "本文"
    )
    assert_equal 200, status
    page_id = JSON.parse(body).fetch("id")
    database_path.delete

    restarted_app = WeblogAuthoring::Application.build(root:, clock: -> { FIXED_TIME })
    status, _headers, body = request_with(restarted_app, "GET", "/editor/#{page_id}")

    assert_equal 200, status
    assert_includes body, page_id
    assert database_path.file?
  end

  private

  def app
    @app ||= WeblogAuthoring::Application.build(root:, clock: -> { FIXED_TIME })
  end

  def request(method, path, body: nil, content_type: nil)
    request_with(app, method, path, body:, content_type:)
  end

  def request_with(application, method, path, body: nil, content_type: nil)
    env = Rack::MockRequest.env_for(
      path,
      method:,
      input: body,
      "CONTENT_TYPE" => content_type,
      "HTTP_HOST" => "127.0.0.1:8000"
    )
    status, headers, response_body = application.call(env)
    [status, headers.transform_keys(&:downcase), response_body.join]
  end

  def json_request(path, payload)
    request(
      "POST",
      path,
      body: JSON.generate(payload),
      content_type: "application/json; charset=utf-8"
    )
  end

  def root
    @root ||= Pathname(Dir.mktmpdir("weblog-authoring-e2e"))
  end

  def database_path
    root.join("data/index/authoring.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(root.to_s) if defined?(@root) && root.exist?
  end
end
