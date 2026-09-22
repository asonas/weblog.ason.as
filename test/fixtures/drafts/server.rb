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
  if ENV["DRAFT_TEST_LEGACY_DIARY"] == "1"
    id = "dc802ad0b89946aeb6b7623c2ba7bc79"
    scope = { "protocol" => 1, "generation" => 1 }
    store = WeblogAuthoring::DraftStore.sqlite(File.join(root, "data/development/drafts.sqlite3"))
    store.create(id, scope)
    date = Time.now.getlocal("+09:00").strftime("%Y-%m-%d")
    store.append(id, scope.merge("update_id" => "legacy-diary", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
                                "metadata" => { "title" => { "value" => date, "expected_revision" => 0 },
                                                "page_type" => { "value" => "date", "expected_revision" => 0 },
                                                "page_date" => { "value" => date, "expected_revision" => 0 }, }))
  end
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
