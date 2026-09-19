# frozen_string_literal: true

require "tmpdir"
require "rackup"
require "rack/handler/puma"
require_relative "../../../lib/weblog_authoring/development_app"

Dir.mktmpdir("draft-browser-test") do |root|
  app = WeblogAuthoring::DevelopmentApp.application(
    root:, oauth_client: nil, inbox_sources: {}, drafts_enabled: true
  )
  token = ENV.fetch("DRAFT_TEST_TOKEN")
  isolated_app = lambda do |env|
    if env["PATH_INFO"] == "/api/draft-test-health"
      [200, { "content-type" => "text/plain" }, [token]]
    else
      app.call(env)
    end
  end
  Rackup::Handler::Puma.run(isolated_app, Host: "127.0.0.1", Port: 18082)
end
