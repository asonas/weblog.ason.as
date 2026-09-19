# frozen_string_literal: true

require "tmpdir"
require "rackup"
require "rack/handler/puma"
require_relative "../../../lib/weblog_authoring/development_app"

class DraftTestSearchRunner < WeblogAuthoring::SearchIndexer::QmdRunner
  attr_accessor :fail_next

  def build(**options)
    if fail_next
      self.fail_next = false
      raise IOError, "search process temporarily unavailable"
    end
    super
  end
end

Dir.mktmpdir("draft-browser-test") do |root|
  search_runner = DraftTestSearchRunner.new
  app = WeblogAuthoring::DevelopmentApp.application(
    root:, oauth_client: nil, inbox_sources: {}, drafts_enabled: true, draft_search_runner: search_runner
  )
  token = ENV.fetch("DRAFT_TEST_TOKEN")
  isolated_app = lambda do |env|
    if env["PATH_INFO"] == "/api/draft-test-health"
      [200, { "content-type" => "text/plain" }, [token]]
    elsif env["PATH_INFO"] == "/api/draft-test-search-failure" && env["REQUEST_METHOD"] == "POST" && env["HTTP_X_DRAFT_TEST_TOKEN"] == token
      search_runner.fail_next = true
      [204, {}, []]
    else
      app.call(env)
    end
  end
  Rackup::Handler::Puma.run(isolated_app, Host: "127.0.0.1", Port: 18082)
end
