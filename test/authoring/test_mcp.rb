# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/mcp"
require "weblog_authoring/lambda_api"
require "weblog_authoring/draft_migration"
require "weblog_authoring/development_app"
require "rack/mock"

class McpTest < Minitest::Test
  ID = "dc802ad0b89946aeb6b7623c2ba7bc79"

  def setup
    @root = Pathname(Dir.mktmpdir("mcp-test"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    WeblogAuthoring::DraftMigration.new(store: @store).import(
      "format" => 1, "site_url" => "https://weblog.ason.as", "articles" => [{
        "id" => ID, "page_type" => "named", "route" => "DNS/日本語", "title" => "DNS/日本語", "body" => "公開本文",
        "cover_mode" => "none", "created_at" => "2026-09-01T01:02:03Z", "updated_at" => "2026-09-02T01:02:03Z", "published_at" => "2026-09-02T01:02:03Z",
      }]
    )
    @outputs = Object.new
    @outputs.define_singleton_method(:search) do |query:, limit:|
      raise "unbounded query" unless query == "DNS" && limit == 2
      WeblogAuthoring::SearchIndex::Result.new(results: [
        { "route" => "DNS/日本語", "title" => "古いタイトル", "excerpt" => "公開の検索抜粋" },
        { "route" => "非公開", "title" => "秘密", "excerpt" => "秘密の本文" },
      ], generated_at: "2026-09-02T01:02:03Z")
    end
    @api = WeblogAuthoring::LambdaApi.new(database: Object.new, draft_store: @store, draft_outputs: @outputs, frontend_url: "https://weblog.ason.as")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_legacy_initialization_notifications_and_tools
    response = rpc("initialize", { "protocolVersion" => "2099-01-01", "capabilities" => {}, "clientInfo" => { "name" => "test", "version" => "1" } })
    assert_equal "2025-11-25", parsed(response).dig("result", "protocolVersion")
    assert_equal false, parsed(response).dig("result", "capabilities", "tools", "listChanged")
    response = rpc("notifications/initialized", {}, notification: true)
    assert_equal 202, response.fetch(:statusCode)
    assert_empty response.fetch(:body)
    tools = parsed(rpc("tools/list")).dig("result", "tools")
    assert_equal(%w[search_articles get_article], tools.map { |tool| tool.fetch("name") })
    assert(tools.all? { |tool| tool.dig("annotations", "readOnlyHint") })
    assert_equal({}, parsed(rpc("ping")).fetch("result"))
  end

  def test_modern_discovery_tools_and_header_validation
    response = rpc("server/discover", modern: true)
    result = parsed(response).fetch("result")
    assert_equal "complete", result.fetch("resultType")
    assert_includes result.fetch("supportedVersions"), "2026-07-28"
    assert_equal "complete", parsed(rpc("tools/list", modern: true)).dig("result", "resultType")
    response = rpc("tools/call", { "name" => "get_article", "arguments" => { "route" => "DNS/日本語" } }, modern: true)
    assert_equal "complete", parsed(response).dig("result", "resultType")
    assert_equal "公開本文", tool_value(response).fetch("body")
    response = rpc("tools/call", { "name" => "get_article", "arguments" => { "route" => "DNS/日本語" } }, modern: true, headers: { "mcp-name" => "search_articles" })
    assert_equal 400, response.fetch(:statusCode)
    assert_equal(-32020, parsed(response).dig("error", "code"))
    response = rpc("tools/list", modern: true, headers: { "mcp-protocol-version" => "2025-11-25" })
    assert_equal 400, response.fetch(:statusCode)
  end

  def test_search_filters_unpublished_routes_and_returns_canonical_urls
    response = rpc("tools/call", { "name" => "search_articles", "arguments" => { "query" => " DNS ", "limit" => 2 } })
    results = tool_value(response).fetch("results")
    assert_equal 1, results.length
    assert_equal "DNS/日本語", results.first.fetch("title")
    assert_equal "https://weblog.ason.as/DNS%2F%E6%97%A5%E6%9C%AC%E8%AA%9E", results.first.fetch("url")
    refute_includes response.fetch(:body), "秘密"
  end

  def test_fetch_uses_published_snapshot_even_after_draft_title_edits
    @store.append(ID, { "protocol" => 1, "generation" => 1, "update_id" => "edit", "data" => "AAA=",
      "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "title" => { "value" => "秘密の下書き", "expected_revision" => 0 } }, })
    assert_equal "秘密の下書き", @store.read(ID, {}).dig("metadata", "title", "value")
    response = rpc("tools/call", { "name" => "get_article", "arguments" => { "route" => "DNS/日本語" } })
    assert_equal "公開本文", tool_value(response).fetch("body")
    assert_equal "DNS/日本語", tool_value(response).fetch("title")
    assert_equal "markdown", tool_value(response).fetch("format")
    assert_equal "no-store", response.dig(:headers, "cache-control")
    assert_equal true, parsed(rpc("tools/call", { "name" => "get_article", "arguments" => { "route" => "非公開" } })).dig("result", "isError")
    refute_includes response.fetch(:body), "秘密"
  end

  def test_invalid_requests_do_not_execute_tools
    assert_equal 405, @api.call(event.merge("requestContext" => { "http" => { "method" => "GET" } })).fetch(:statusCode)
    assert_equal 403, rpc("tools/list", headers: { "origin" => "https://attacker.example" }).fetch(:statusCode)
    assert_equal 200, rpc("tools/list", headers: { "origin" => "https://weblog.ason.as" }).fetch(:statusCode)
    assert_equal 415, rpc("tools/list", headers: { "content-type" => "text/plain" }).fetch(:statusCode)
    assert_equal(-32022, parsed(rpc("tools/list", headers: { "mcp-protocol-version" => "2099-01-01" })).dig("error", "code"))
    ["null", "[]", "42"].each do |body|
      assert_equal(-32600, parsed(@api.call(event.merge("body" => body))).dig("error", "code"))
    end
    assert_equal(-32700, parsed(@api.call(event.merge("body" => "{"))).dig("error", "code"))
    assert_equal 413, @api.call(event.merge("body" => "x" * ((WeblogAuthoring::Mcp::MAX_BODY_BYTES * 2) + 1))).fetch(:statusCode)
    assert_equal(-32601, parsed(rpc("drafts/list")).dig("error", "code"))
    assert_equal(-32602, parsed(rpc("tools/call", { "name" => "delete_article" })).dig("error", "code"))
    [0, 21, "2", 2.5].each do |limit|
      assert_equal true, parsed(rpc("tools/call", { "name" => "search_articles", "arguments" => { "query" => "DNS", "limit" => limit } })).dig("result", "isError")
    end
  end

  def test_discovery_and_unavailable_search
    response = @api.call(event.merge("rawPath" => "/api/agents", "requestContext" => { "http" => { "method" => "GET" } }))
    assert_equal "https://weblog.ason.as/api/mcp", parsed(response).fetch("services").first.fetch("url")
    @outputs.define_singleton_method(:search) { |**| raise WeblogAuthoring::SearchIndex::Unavailable }
    response = rpc("tools/call", { "name" => "search_articles", "arguments" => { "query" => "DNS" } }, modern: true)
    assert_equal true, parsed(response).dig("result", "isError")
    assert_equal "complete", parsed(response).dig("result", "resultType")
    legacy = WeblogAuthoring::LambdaApi.new(database: Object.new)
    assert_equal 503, legacy.call(event).fetch(:statusCode)
  end

  def test_development_mcp_is_public_but_authoring_remains_authenticated
    app = WeblogAuthoring::DevelopmentApp.application(root: @root, drafts_enabled: true, oauth_client: Object.new, inbox_sources: {})
    request = Rack::MockRequest.new(app)
    response = request.post("/api/mcp", "HTTP_HOST" => "127.0.0.1", "CONTENT_TYPE" => "application/json", input: JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"))
    assert_equal 200, response.status, response.body
    assert_equal(%w[search_articles get_article], JSON.parse(response.body).dig("result", "tools").map { |tool| tool.fetch("name") })
    response = request.post("/api/authoring/pages", "HTTP_HOST" => "127.0.0.1", "CONTENT_TYPE" => "application/json", input: "{}")
    assert_equal 401, response.status
  end

  private

  def event
    { "rawPath" => "/api/mcp", "headers" => { "content-type" => "application/json", "accept" => "application/json, text/event-stream" },
      "body" => "{}", "requestContext" => { "http" => { "method" => "POST" } }, }
  end

  def rpc(method, params = {}, modern: false, notification: false, headers: {})
    request = event
    message = { "jsonrpc" => "2.0", "method" => method, "params" => params }
    message["id"] = 1 unless notification
    if modern
      params["_meta"] = { "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                          "io.modelcontextprotocol/clientInfo" => { "name" => "test", "version" => "1" }, "io.modelcontextprotocol/clientCapabilities" => {}, }
      request["headers"].merge!("mcp-protocol-version" => "2026-07-28", "mcp-method" => method)
      request["headers"]["mcp-name"] = params["name"] if method == "tools/call"
    end
    request["headers"].merge!(headers)
    @api.call(request.merge("body" => JSON.generate(message)))
  end

  def parsed(response)
    JSON.parse(response.fetch(:body))
  end

  def tool_value(response)
    JSON.parse(parsed(response).dig("result", "content", 0, "text"))
  end
end
