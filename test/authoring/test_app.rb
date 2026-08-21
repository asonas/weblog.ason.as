# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/app"

require "fileutils"
require "rack/mock"
require "tmpdir"

class TestApplication < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T12:00:00+09:00")

  def test_build_uses_repository_root_paths_and_returns_the_rack_app
    root = Pathname(Dir.mktmpdir("weblog-authoring-app"))
    app = WeblogAuthoring::Application.build(root:, clock: -> { FIXED_TIME })

    assert root.join("content").directory?
    assert root.join("data/index/authoring.sqlite3").file?

    env = Rack::MockRequest.env_for(
      "/editor/today",
      method: "GET",
      "HTTP_HOST" => "127.0.0.1:8000"
    )
    status, headers, body = app.call(env)

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
    assert_includes body.join, "authoring-root"
    refute_includes body.join, "preview"
  ensure
    FileUtils.remove_entry(root.to_s) if defined?(root) && root&.exist?
  end
end
