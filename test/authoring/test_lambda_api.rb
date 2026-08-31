# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/github_oauth"
require_relative "../../lib/weblog_authoring/lambda_api"
require_relative "../../lib/weblog_authoring/lambda_session"

class LambdaApiTest < Minitest::Test
  class FakeS3
    ObjectBody = Data.define(:body)

    attr_reader :objects, :put_requests

    def initialize
      @objects = {}
      @put_requests = []
    end

    def get_object(bucket:, key:)
      value = objects[[bucket, key]]
      raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") if value.nil?

      ObjectBody.new(StringIO.new(value))
    end

    def put_object(bucket:, key:, body:, content_type:, cache_control: nil)
      objects[[bucket, key]] = body
      put_requests << { bucket:, key:, content_type:, cache_control: }
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
    attr_reader :health_checks, :pages, :saved_requests, :inbox_filters
    attr_accessor :webmentions, :webmention_delivery_failures

    def initialize(pages, inbox_items: [], inbox_item_usages: [])
      @pages = pages
      @inbox_items = inbox_items
      @inbox_item_usages = inbox_item_usages
      @health_checks = 0
      @saved_requests = []
      @webmentions = []
      @webmention_delivery_failures = []
    end

    def healthy?
      @health_checks += 1
      true
    end

    def list_pages(limit: nil, before: nil, after: nil, kind: nil, timings: nil)
      timings&.merge!("db_checkout" => 1.0, "dsql_exec" => 2.0, "row_build" => 3.0, "wiki_parse" => 4.0)
      timestamp = ->(page) { kind == "diary" ? page.created_at : page.updated_at }
      selected = pages.sort_by { |page| [timestamp.call(page), page.id] }.reverse
      selected = selected.select do |page|
        is_diary = page.links.any? { |link| link.name == "日記" }
        kind == "diary" ? is_diary : !is_diary
      end if kind
      selected = selected.select do |page|
        ([timestamp.call(page), page.id] <=> [before.fetch(:timestamp), before.fetch(:id)]).negative?
      end if before
      selected = selected.select do |page|
        ([timestamp.call(page), page.id] <=> [after.fetch(:timestamp), after.fetch(:id)]).positive?
      end if after
      selected = selected.first(limit) if limit
      selected
    end

    def find(id, timings: nil)
      timings&.merge!("db_checkout" => 1.0, "dsql_exec" => 2.0, "row_build" => 3.0, "wiki_parse" => 4.0)
      pages.find { |page| page.id == id }
    end

    def find_route(route)
      pages.find { |page| page.route == route }
    end

    def save(request)
      saved_requests << request
      pages.fetch(0)
    end

    def scrapbox_line_metadata(_page_id)
      [{ updated_at: Time.iso8601("2026-08-29T13:23:44+00:00") }]
    end

    def list_inbox_items(source: nil, kind: nil)
      @inbox_filters = { source:, kind: }
      @inbox_items.select do |item|
        (source.nil? || item.source == source) && (kind.nil? || item.kind == kind)
      end
    end

    def find_inbox_item(id)
      @inbox_items.find { |item| item.id == id }
    end

    def list_inbox_item_usages
      @inbox_item_usages
    end

    def prepare_inbox_image_adoption(item_id:, inbox_key:, public_key:)
      WeblogAuthoring::InboxImageAdoption.new(
        item_id:, inbox_key:, public_key:,
        prepared_at: Time.iso8601("2026-08-26T12:00:00+09:00"),
        committed_at: nil,
        expires_at: Time.iso8601("2026-09-09T12:00:00+09:00")
      )
    end

    def queue_inbox_sync_run(run_id:, trigger:, queued_at:, sources:)
      return false if @inbox_sync_run && %w[queued running].include?(@inbox_sync_run.fetch("status"))

      @inbox_sync_run = {
        "id" => run_id, "trigger" => trigger, "status" => "queued",
        "started_at" => queued_at.iso8601, "completed_at" => nil,
        "sources" => sources.map { |source| { "source" => source, "status" => "queued" } },
      }
      true
    end

    def inbox_sync_run(run_id:)
      @inbox_sync_run if @inbox_sync_run&.fetch("id") == run_id
    end

    def list_webmentions(moderation_status: nil, verification_status: nil)
      webmentions.select do |mention|
        (moderation_status.nil? || mention.fetch("moderation_status") == moderation_status) &&
          (verification_status.nil? || mention.fetch("verification_status") == verification_status)
      end
    end

    def list_webmention_failures
      []
    end

    def list_webmention_delivery_failures
      webmention_delivery_failures
    end

    def webmention_delivery_retry(id)
      failure = webmention_delivery_failures.find { |item| item.fetch("id") == id }
      return nil unless failure

      {
        "delivery_id" => failure.fetch("id"), "page_id" => failure.fetch("page_id"),
        "source" => failure.fetch("source_url"), "target" => failure.fetch("target_url"),
      }
    end

    def webmention_reverification(id)
      mention = webmentions.find { |item| item.fetch("id") == id }
      return nil unless mention

      {
        "source" => mention.fetch("source_url"), "target" => mention.fetch("target_url"),
        "target_page_id" => mention.fetch("target_page_id"),
      }
    end

    def moderate_webmention(id:, decision:)
      mention = webmentions.find { |item| item.fetch("id") == id }
      raise KeyError unless mention

      mention.merge("moderation_status" => decision)
    end

    def delete_webmention(id:)
      index = webmentions.index { |item| item.fetch("id") == id }
      raise KeyError unless index

      webmentions.delete_at(index)
    end

    def approved_webmentions_for_page(page_id)
      webmentions.select do |mention|
        mention.fetch("target_page_id") == page_id && mention.fetch("moderation_status") == "approved"
      end
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

  class FakeSqs
    MoveTask = Data.define(:task_handle)

    attr_reader :messages, :move_tasks

    def initialize(error: nil)
      @error = error
      @messages = []
      @move_tasks = []
    end

    def send_message(**message)
      raise @error unless @error.nil?

      messages << message
    end

    def start_message_move_task(**request)
      move_tasks << request
      MoveTask.new("move-task")
    end
  end

  class FakeLambda
    attr_reader :invocations

    Response = Data.define(:payload, :function_error)

    def initialize(response: {})
      @invocations = []
      @response = response
    end

    def invoke(**request)
      invocations << request
      Response.new(payload: StringIO.new(JSON.generate(@response)), function_error: nil)
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

  def test_publishes_an_atom_feed_to_s3_for_a_scheduled_event
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
    assert_equal "application/atom+xml; charset=utf-8", s3.put_requests.fetch(0).fetch(:content_type)
    assert_includes feed, '<feed xmlns="http://www.w3.org/2005/Atom">'
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
    assert_match(/db;dur=.*summaries;dur=.*json;dur=/, response.fetch(:headers).fetch("server-timing"))
    refute JSON.parse(response.fetch(:body)).key?("tags")
    refute JSON.parse(response.fetch(:body)).key?("archive")
  end

  def test_page_summaries_identify_diary_links
    @database.pages.replace([page_document(id: "diary", name: "2026-08-28", body: "本文 [[日記]]")])

    response = @api.call(event("GET", "/api/pages"))
    page = JSON.parse(response.fetch(:body)).fetch("pages").fetch(0)

    assert_equal true, page.fetch("is_diary")
  end

  def test_page_windows_filter_diaries_and_articles_independently
    @database.pages.replace([
      page_document(id: "diary", name: "2026-08-28", body: "本文 [[日記]]"),
      page_document(id: "article", name: "article", body: "本文"),
    ])

    diaries = @api.call(event("GET", "/api/pages", query: { "kind" => "diary" }))
    articles = @api.call(event("GET", "/api/pages", query: { "kind" => "article" }))

    assert_equal(["2026-08-28"], JSON.parse(diaries.fetch(:body)).fetch("pages").map { |page| page.fetch("route") })
    assert_equal(["article"], JSON.parse(articles.fetch(:body)).fetch("pages").map { |page| page.fetch("route") })
  end

  def test_page_windows_order_diaries_by_creation_and_articles_by_update
    older = Time.iso8601("2026-08-20T10:00:00+09:00")
    newer = Time.iso8601("2026-08-21T10:00:00+09:00")
    @database.pages.replace([
      page_document(id: "new-diary", name: "2026-08-21", body: "[[日記]]", created_at: newer, updated_at: older),
      page_document(id: "edited-diary", name: "2026-08-20", body: "[[日記]]", created_at: older, updated_at: newer),
      page_document(id: "new-article", name: "new-article", body: "本文", created_at: newer, updated_at: older),
      page_document(id: "edited-article", name: "edited-article", body: "本文", created_at: older, updated_at: newer),
    ])

    diaries = @api.call(event("GET", "/api/pages", query: { "kind" => "diary" }))
    articles = @api.call(event("GET", "/api/pages", query: { "kind" => "article" }))

    assert_equal(%w[2026-08-21 2026-08-20], JSON.parse(diaries.fetch(:body)).fetch("pages").map { |page| page.fetch("route") })
    assert_equal(%w[edited-article new-article], JSON.parse(articles.fetch(:body)).fetch("pages").map { |page| page.fetch("route") })
  end

  def test_lists_home_tags_and_archive_separately
    @database.pages.replace([
      page_document(
        id: "diary",
        name: "日記",
        body: "[[日記]] [[月曜日]] [[火曜日]] [[2026-08-21]] [[202608]] [[0827]] #開発"
      ),
    ])
    tags = @api.call(event("GET", "/api/tags"))
    archive = @api.call(event("GET", "/api/archive"))

    assert_equal %w[開発], JSON.parse(tags.fetch(:body)).fetch("tags")
    assert_equal [{ "year" => 2026, "months" => [8] }], JSON.parse(archive.fetch(:body)).fetch("archive")
  end

  def test_reports_secondary_tag_timings_with_request_context
    log = StringIO.new
    api = WeblogAuthoring::LambdaApi.new(database: @database, logger: log)
    response = api.call(event("GET", "/api/tags"))
    warm_response = api.call(event("GET", "/api/archive"))

    assert_equal 200, response.fetch(:statusCode), response.fetch(:body)
    timing = response.fetch(:headers).fetch("server-timing")
    %w[db_checkout dsql_exec row_build wiki_parse tag_scan json].each do |name|
      assert_match(/(?:\A|, )#{name};dur=\d+(?:\.\d+)?/, timing)
    end
    entry, warm_entry = log.string.lines.map { |line| JSON.parse(line) }
    assert_equal "secondary_timing", entry.fetch("event")
    assert_equal "request-id", entry.fetch("request_id")
    assert_equal "/api/tags", entry.fetch("route")
    assert_equal true, entry.fetch("cold")
    assert_equal 200, entry.fetch("status")
    assert_equal 200, warm_response.fetch(:statusCode), warm_response.fetch(:body)
    assert_match(/archive_scan;dur=\d+(?:\.\d+)?/, warm_response.fetch(:headers).fetch("server-timing"))
    assert_equal "/api/archive", warm_entry.fetch("route")
    assert_equal false, warm_entry.fetch("cold")
  end

  def test_reports_related_processing_timings
    log = StringIO.new
    api = WeblogAuthoring::LambdaApi.new(database: @database, logger: log)
    response = api.call(event(
      "GET", "/api/related", query: { "route" => "記事名", "excluding_id" => "page-id" }
    ))

    assert_equal 200, response.fetch(:statusCode), response.fetch(:body)
    timing = response.fetch(:headers).fetch("server-timing")
    %w[db_checkout dsql_exec row_build wiki_parse related_input related_scan related_summary related_sort json].each do |name|
      assert_match(/(?:\A|, )#{name};dur=\d+(?:\.\d+)?/, timing)
    end
  end

  def test_lists_cacheable_page_names
    @database.pages.replace([
      page_document(id: "source", name: "source", body: "[[weblog.ason.asの書き心地]]"),
      @page,
    ])
    first = @api.call(event("GET", "/api/page-names"))
    etag = first.fetch(:headers).fetch("etag")
    unchanged = @api.call(event("GET", "/api/page-names", headers: { "if-none-match" => etag }))

    payload = JSON.parse(first.fetch(:body))

    assert_equal ["source", "記事名", "weblog.ason.asの書き心地"], payload.fetch("names")
    assert_equal([true, true, false], payload.fetch("entries").map { |entry| entry.fetch("materialized") })
    assert_match(/\Ahub-[0-9a-f]{32}\z/, payload.fetch("entries").last.fetch("id"))
    assert_equal "no-cache", first.fetch(:headers).fetch("cache-control")
    assert_equal 304, unchanged.fetch(:statusCode)
  end

  def test_finds_a_page_by_id
    response = @api.call(event("GET", "/api/pages/page-id", { "id" => "page-id" }))
    page = JSON.parse(response.fetch(:body))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "no-cache", response.fetch(:headers).fetch("cache-control")
    refute_empty response.fetch(:headers).fetch("etag")
    assert_equal "editor", page.fetch("mode")
    assert_equal "本文", page.fetch("body")
    assert_equal ["2026-08-29T13:23:44.000000000+00:00"], page.fetch("line_updated_at")
  end

  def test_page_without_line_history_uses_page_update_time
    @database.define_singleton_method(:scrapbox_line_metadata) { |_page_id| [] }
    @database.pages.replace([page_document(id: "page-id", name: "記事名", body: "一行目\n二行目")])

    response = @api.call(event("GET", "/api/pages/page-id", { "id" => "page-id" }))
    page = JSON.parse(response.fetch(:body))

    assert_equal Array.new(2, @database.pages.fetch(0).updated_at.iso8601(9)), page.fetch("line_updated_at")
  end

  def test_page_response_accepts_a_weak_matching_etag
    first = @api.call(event("GET", "/api/pages/page-id", { "id" => "page-id" }))
    weak_etag = "W/#{first.fetch(:headers).fetch("etag")}"
    unchanged = @api.call(event(
      "GET",
      "/api/pages/page-id",
      { "id" => "page-id" },
      headers: { "if-none-match" => weak_etag }
    ))

    assert_equal 304, unchanged.fetch(:statusCode)
    assert_empty unchanged.fetch(:body)
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

  def test_missing_route_is_not_cached
    response = @api.call(event(
      "GET",
      "/api/routes/missing-hub",
      { "route" => "missing-hub" }
    ))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "no-store", response.fetch(:headers).fetch("cache-control")
    assert_empty JSON.parse(response.fetch(:body)).fetch("page_id")
  end

  def test_missing_route_requests_its_related_pages
    response = @api.call(event("GET", "/api/routes/202608", { "route" => "202608" }))
    page = JSON.parse(response.fetch(:body))

    assert_equal 200, response.fetch(:statusCode)
    assert page.fetch("linked_pages_has_more")
  end

  def test_returns_pages_related_by_wiki_links
    source = page_document(id: "source", name: "source", body: "[[target]]")
    target = page_document(id: "target", name: "target", body: "")
    @database.pages.replace([source, target])

    response = @api.call(event(
      "GET",
      "/api/related",
      query: { "route" => "source", "excluding_id" => "source" }
    ))
    linked_pages = JSON.parse(response.fetch(:body)).fetch("pages")

    assert_equal(["target"], linked_pages.map { |page| page.fetch("route") })
  end

  def test_route_response_etag_does_not_include_deferred_related_pages
    target = page_document(id: "target", name: "target", body: "")
    @database.pages.replace([target])

    first = @api.call(event("GET", "/api/routes/target", { "route" => "target" }))
    etag = first.fetch(:headers).fetch("etag")
    unchanged = @api.call(event(
      "GET",
      "/api/routes/target",
      { "route" => "target" },
      headers: { "if-none-match" => etag }
    ))

    assert_equal 304, unchanged.fetch(:statusCode)
    assert_empty unchanged.fetch(:body)

    source = page_document(id: "source", name: "source", body: "[[target]]")
    @database.pages << source
    changed = @api.call(event(
      "GET",
      "/api/routes/target",
      { "route" => "target" },
      headers: { "if-none-match" => etag }
    ))

    assert_equal 304, changed.fetch(:statusCode)
    assert_empty changed.fetch(:body)
  end

  def test_returns_related_pages_from_the_pagination_endpoint
    target = page_document(id: "target", name: "target", body: "")
    sources = 51.times.map do |index|
      page_document(id: "source-#{index}", name: "source-#{index}", body: "[[target]]")
    end
    @database.pages.replace([target, *sources])

    first = @api.call(event(
      "GET",
      "/api/related",
      query: { "route" => "target", "excluding_id" => "target", "offset" => "0" }
    ))
    first_body = JSON.parse(first.fetch(:body))
    second = @api.call(event(
      "GET",
      "/api/related",
      query: { "route" => "target", "excluding_id" => "target", "offset" => "50" }
    ))
    second_body = JSON.parse(second.fetch(:body))

    assert_equal 50, first_body.fetch("pages").length
    assert first_body.fetch("has_more")
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

  def test_bluesky_oauth_routes_require_login_and_csrf_for_mutations
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    lambda_client = FakeLambda.new(response: { "authorization_url" => "https://bsky.social/oauth" })
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      allowed_github_user_id: 630_181,
      lambda_client:,
      bluesky_oauth_function_name: "bluesky-oauth"
    )
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )

    assert_equal 401, api.call(event("GET", "/api/inbox/sources/bluesky/status")).fetch(:statusCode)
    missing_csrf = api.call(event(
      "POST", "/api/inbox/sources/bluesky/connect", cookies: ["weblog_authoring_session=#{token}"]
    ))
    assert_equal 403, missing_csrf.fetch(:statusCode)
    missing_refresh_csrf = api.call(event(
      "POST", "/api/inbox/sources/bluesky/refresh", cookies: ["weblog_authoring_session=#{token}"]
    ))
    assert_equal 403, missing_refresh_csrf.fetch(:statusCode)

    refreshed = api.call(event(
      "POST",
      "/api/inbox/sources/bluesky/refresh",
      cookies: ["weblog_authoring_session=#{token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    assert_equal 200, refreshed.fetch(:statusCode)
    assert_equal "refresh", JSON.parse(lambda_client.invocations.last.fetch(:payload)).fetch("action")

    connected = api.call(event(
      "POST",
      "/api/inbox/sources/bluesky/connect",
      cookies: ["weblog_authoring_session=#{token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    assert_equal 200, connected.fetch(:statusCode)
    assert_equal "https://bsky.social/oauth", JSON.parse(connected.fetch(:body)).fetch("authorization_url")
    assert_equal "RequestResponse", lambda_client.invocations.last.fetch(:invocation_type)
  end

  def test_bluesky_oauth_callback_forwards_query_and_redirects_after_authenticated_state_validation
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    lambda_client = FakeLambda.new(response: { "status" => "connected" })
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      frontend_url: "https://weblog.ason.as",
      allowed_github_user_id: 630_181,
      lambda_client:,
      bluesky_oauth_function_name: "bluesky-oauth"
    )
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )

    response = api.call(event(
      "GET",
      "/api/inbox/sources/bluesky/callback",
      query: { "state" => "one-time", "code" => "authorization-code" },
      cookies: ["weblog_authoring_session=#{token}"]
    ))

    assert_equal 302, response.fetch(:statusCode)
    assert_equal "https://weblog.ason.as/?bluesky=connected", response.dig(:headers, "location")
    payload = JSON.parse(lambda_client.invocations.last.fetch(:payload))
    assert_equal "callback", payload.fetch("action")
    assert_equal({ "state" => "one-time", "code" => "authorization-code" }, URI.decode_www_form(payload.fetch("query")).to_h)
  end

  def test_retries_expired_fallback_embed_metadata
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
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    key = "assets/embed-cache/#{Digest::SHA256.hexdigest(url)}.json"
    s3.objects[["production-assets", key]] = JSON.generate(
      "url" => url,
      "title" => "www.youtube.com",
      "status" => "fallback",
      "fetched_at" => "2026-08-22T11:54:00+09:00"
    )

    response = api.call(event("GET", "/api/embed", query: { "url" => url }))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal "Example", JSON.parse(response.fetch(:body)).fetch("title")
    assert_equal [url], fetcher.requests
  end

  def test_mutations_require_an_allowed_session_and_csrf_token
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      allowed_github_user_id: 630_181
    )

    unauthorized = api.call(json_event("POST", "/api/authoring/pages", { title: "new", body: "本文" }))
    assert_equal 401, unauthorized.fetch(:statusCode)

    denied_token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 999, "login" => "other", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    denied = api.call(json_event(
      "POST",
      "/api/authoring/pages",
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
      "/api/authoring/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{allowed_token}"]
    ))
    assert_equal 403, missing_csrf.fetch(:statusCode)

    invalid = event(
      "POST",
      "/api/authoring/pages",
      cookies: ["weblog_authoring_session=#{allowed_token}"],
      headers: { "content-type" => "application/json", "x-csrf-token" => "csrf-token" }
    ).merge("body" => "{")
    invalid_response = api.call(invalid)
    assert_equal 422, invalid_response.fetch(:statusCode)
    assert_equal "no-store", invalid_response.fetch(:headers).fetch("cache-control")

    allowed = api.call(json_event(
      "POST",
      "/api/authoring/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{allowed_token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    assert_equal 201, allowed.fetch(:statusCode)
    assert_equal "no-store", allowed.fetch(:headers).fetch("cache-control")
    assert_equal "本文", @database.saved_requests.fetch(0).body
    assert_equal ["2026-08-29T13:23:44.000000000+00:00"],
                 JSON.parse(allowed.fetch(:body)).fetch("line_updated_at")
  end

  def test_saved_page_is_read_back_from_the_route_without_stale_content
    api, token = authenticated_api(sqs: FakeSqs.new)
    saved_page = page_document(id: "page-id", name: "記事名", body: "更新後の本文")
    before = api.call(event(
      "GET",
      "/api/routes/%E8%A8%98%E4%BA%8B%E5%90%8D",
      { "route" => "%E8%A8%98%E4%BA%8B%E5%90%8D" }
    ))
    previous_etag = before.fetch(:headers).fetch("etag")
    @database.define_singleton_method(:save) do |request|
      saved_requests << request
      pages.replace([saved_page])
      saved_page
    end

    saved = api.call(json_event(
      "PATCH",
      "/api/authoring/pages/page-id",
      { title: "記事名", body: "更新後の本文" },
      path_parameters: { "id" => "page-id" },
      cookies: ["weblog_authoring_session=#{token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    reloaded = api.call(event(
      "GET",
      "/api/routes/%E8%A8%98%E4%BA%8B%E5%90%8D",
      { "route" => "%E8%A8%98%E4%BA%8B%E5%90%8D" },
      headers: { "if-none-match" => previous_etag }
    ))

    assert_equal 200, saved.fetch(:statusCode)
    assert_equal "no-store", saved.fetch(:headers).fetch("cache-control")
    assert_equal 200, reloaded.fetch(:statusCode)
    refute_equal previous_etag, reloaded.fetch(:headers).fetch("etag")
    assert_equal "更新後の本文", JSON.parse(reloaded.fetch(:body)).fetch("body")
    assert_equal "no-cache", reloaded.fetch(:headers).fetch("cache-control")
  end

  def test_successful_save_requests_a_debounced_search_index_update
    sqs = FakeSqs.new
    api, token = authenticated_api(sqs:)

    response = api.call(json_event(
      "POST",
      "/api/authoring/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))

    assert_equal 201, response.fetch(:statusCode)
    assert_equal "search-index", sqs.messages.fetch(0).fetch(:message_group_id)
    assert_equal "search-index", sqs.messages.fetch(0).fetch(:message_deduplication_id)
  end

  def test_search_notification_failure_does_not_fail_the_save
    error = Aws::SQS::Errors::ServiceError.new(nil, "unavailable")
    sqs = FakeSqs.new(error:)
    log = StringIO.new
    api, token = authenticated_api(sqs:, logger: log)

    response = api.call(json_event(
      "POST",
      "/api/authoring/pages",
      { title: "new", body: "本文" },
      cookies: ["weblog_authoring_session=#{token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))

    assert_equal 201, response.fetch(:statusCode)
    assert_equal "search_index_notification_failed", JSON.parse(log.string).fetch("event")
  end

  def test_creates_an_authenticated_presigned_image_upload
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      allowed_github_user_id: 630_181,
      s3_client: s3,
      asset_bucket: "production-assets",
      clock: -> { Time.iso8601("2026-08-24T12:00:00+09:00") }
    )

    unauthorized = api.call(json_event(
      "POST",
      "/api/uploads",
      { content_type: "image/webp", size: 1024 }
    ))
    assert_equal 401, unauthorized.fetch(:statusCode)

    response = api.call(json_event(
      "POST",
      "/api/uploads",
      { content_type: "image/webp", size: 1024 },
      cookies: ["weblog_authoring_session=#{token}"],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    body = JSON.parse(response.fetch(:body))

    assert_equal 200, response.fetch(:statusCode)
    assert_match(%r{\A/assets/uploads/2026/08/[0-9a-f-]+\.webp\z}, body.fetch("public_url"))
    assert_equal "image/webp", body.dig("fields", "Content-Type")
  end

  def test_lists_and_adopts_an_inbox_image
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    key = "assets/inbox/2026/08/23/11111111-2222-3333-4444-555555555555.webp"
    s3 = Aws::S3::Client.new(region: "ap-northeast-1", stub_responses: true)
    item = WeblogAuthoring::InboxItem.new(
      id: "item-1", source: "photo", kind: "photo", source_id: "photo-1",
      occurred_at: Time.iso8601("2026-08-23T12:00:00Z"),
      ingested_at: Time.iso8601("2026-08-23T12:01:00Z"),
      expires_at: Time.iso8601("2026-08-30T12:01:00Z"),
      payload: { "inbox_key" => key, "preview_url" => "/#{key}", "captured_at_source" => "exif" },
      created_at: Time.iso8601("2026-08-23T12:01:00Z"),
      updated_at: Time.iso8601("2026-08-23T12:01:00Z")
    )
    usage = WeblogAuthoring::InboxItemUsage.new(
      item_id: "item-1", page_id: @page.id, page_route: "2026-08-27",
      used_at: Time.iso8601("2026-08-27T12:00:00Z")
    )
    database = FakeDatabase.new([@page], inbox_items: [item], inbox_item_usages: [usage])
    api = WeblogAuthoring::LambdaApi.new(
      database:,
      session_codec: codec,
      allowed_github_user_id: 630_181,
      s3_client: s3,
      asset_bucket: "production-assets"
    )
    cookie = ["weblog_authoring_session=#{token}"]

    listed = api.call(event("GET", "/api/inbox", cookies: cookie))
    adopted = api.call(json_event(
      "POST",
      "/api/inbox/adopt",
      { item_id: "item-1" },
      cookies: cookie,
      headers: { "x-csrf-token" => "csrf-token" }
    ))

    assert_equal(["item-1"], JSON.parse(listed.fetch(:body)).fetch("items").map { |inbox_item| inbox_item.fetch("id") })
    assert_equal [{ "id" => @page.id, "route" => "2026-08-27" }],
                 JSON.parse(listed.fetch(:body)).dig("items", 0, "used_in_pages")
    assert_equal "/assets/uploads/2026/08/11111111-2222-3333-4444-555555555555.webp",
                 JSON.parse(adopted.fetch(:body)).fetch("public_url")
    assert_equal(%i[copy_object], s3.api_requests.map { |request| request.fetch(:operation_name) })
    assert_equal "weblog-inbox-adoption=pending", s3.api_requests.fetch(0).fetch(:params).fetch(:tagging)
  end

  def test_lists_common_inbox_items_with_kind_filter
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    item = WeblogAuthoring::InboxItem.new(
      id: "item-1", source: "photo", kind: "photo", source_id: "photo-1",
      occurred_at: Time.iso8601("2026-08-26T10:00:00+09:00"),
      ingested_at: Time.iso8601("2026-08-26T11:00:00+09:00"),
      expires_at: Time.iso8601("2026-09-02T11:00:00+09:00"),
      payload: { "inbox_key" => "assets/inbox/photo.jpg", "preview_url" => "/assets/inbox/photo.jpg", "captured_at_source" => "exif" },
      created_at: Time.iso8601("2026-08-26T11:00:00+09:00"),
      updated_at: Time.iso8601("2026-08-26T11:00:00+09:00")
    )
    database = FakeDatabase.new([@page], inbox_items: [item])
    api = WeblogAuthoring::LambdaApi.new(
      database:, session_codec: codec, allowed_github_user_id: 630_181
    )

    response = api.call(event(
      "GET", "/api/inbox", query: { "source" => "photo", "kind" => "photo" },
      cookies: ["weblog_authoring_session=#{token}"]
    ))
    body = JSON.parse(response.fetch(:body))

    assert_equal 200, response.fetch(:statusCode)
    assert_equal({ source: "photo", kind: "photo" }, database.inbox_filters)
    assert_equal "item-1", body.fetch("items").fetch(0).fetch("id")
    assert_equal "2026-08-26T10:00:00+09:00", body.fetch("items").fetch(0).fetch("occurred_at")
    assert_equal "photo", body.fetch("items").fetch(0).fetch("kind")
  end

  def test_authenticated_editor_starts_and_reads_an_asynchronous_inbox_sync
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    lambda_client = FakeLambda.new
    database = FakeDatabase.new([@page])
    api = WeblogAuthoring::LambdaApi.new(
      database:, session_codec: codec, allowed_github_user_id: 630_181,
      lambda_client:, inbox_sync_function_name: "weblog-inbox-sync-production",
      clock: -> { Time.iso8601("2026-08-28T12:00:00Z") }
    )
    cookie = ["weblog_authoring_session=#{token}"]

    started = api.call(json_event(
      "POST", "/api/inbox/sync", {}, cookies: cookie,
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    started_body = JSON.parse(started.fetch(:body))
    duplicate = api.call(json_event(
      "POST", "/api/inbox/sync", {}, cookies: cookie,
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    status = api.call(event(
      "GET", "/api/inbox/sync/#{started_body.fetch('run_id')}",
      { "run_id" => started_body.fetch("run_id") }, cookies: cookie
    ))

    assert_equal 202, started.fetch(:statusCode)
    assert_match(/\A[0-9a-f]{32}\z/, started_body.fetch("run_id"))
    assert_equal "Event", lambda_client.invocations.fetch(0).fetch(:invocation_type)
    invocation = JSON.parse(lambda_client.invocations.fetch(0).fetch(:payload))
    assert_equal "manual", invocation.fetch("trigger")
    assert_equal %w[bluesky raindrop c4p], invocation.fetch("sources")
    assert_equal 409, duplicate.fetch(:statusCode)
    assert_equal 1, lambda_client.invocations.length
    assert_equal "queued", JSON.parse(status.fetch(:body)).fetch("status")
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
    assert_equal "no-store", login.fetch(:headers).fetch("cache-control")
    assert_equal "no-store", callback.fetch(:headers).fetch("cache-control")
    assert_equal "no-store", session.fetch(:headers).fetch("cache-control")
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
    assert_equal "no-store", response.fetch(:headers).fetch("cache-control")
    assert_equal "https://weblog.ason.as", response.dig(:headers, "location")
    assert_includes response.fetch(:cookies), "weblog_authoring_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax"
  end

  def test_webmention_moderation_requires_authentication_and_csrf
    @database.webmentions = [webmention]
    sqs = FakeSqs.new
    api, token = authenticated_api(sqs:)

    unauthorized = @api.call(event("GET", "/api/webmentions"))
    listed = api.call(event("GET", "/api/webmentions", cookies: ["weblog_authoring_session=#{token}"]))
    moderated = api.call(json_event(
      "PATCH", "/api/authoring/webmentions/mention-id", { "decision" => "approved" },
      cookies: ["weblog_authoring_session=#{token}"], headers: { "x-csrf-token" => "csrf-token" },
      path_parameters: { "id" => "mention-id" }
    ))

    assert_equal 401, unauthorized.fetch(:statusCode)
    assert_equal "mention-id", JSON.parse(listed.fetch(:body)).fetch("mentions").fetch(0).fetch("id")
    assert_equal "approved", JSON.parse(moderated.fetch(:body)).fetch("mention").fetch("moderation_status")
  end

  def test_webmention_complete_deletion_requires_authentication_and_csrf
    @database.webmentions = [webmention]
    api, token = authenticated_api(sqs: FakeSqs.new)

    unauthorized = api.call(event("DELETE", "/api/authoring/webmentions/mention-id", { "id" => "mention-id" }))
    forbidden = api.call(event(
      "DELETE", "/api/authoring/webmentions/mention-id", { "id" => "mention-id" },
      cookies: ["weblog_authoring_session=#{token}"]
    ))
    deleted = api.call(event(
      "DELETE", "/api/authoring/webmentions/mention-id", { "id" => "mention-id" },
      cookies: ["weblog_authoring_session=#{token}"], headers: { "x-csrf-token" => "csrf-token" }
    ))

    assert_equal 401, unauthorized.fetch(:statusCode)
    assert_equal 403, forbidden.fetch(:statusCode)
    assert_equal 200, deleted.fetch(:statusCode)
    assert_empty @database.webmentions
  end

  def test_reverification_queues_the_existing_relation
    @database.webmentions = [webmention]
    sqs = FakeSqs.new
    api, token = authenticated_api(sqs:)

    response = api.call(event(
      "POST", "/api/authoring/webmentions/mention-id/reverify", { "id" => "mention-id" },
      cookies: ["weblog_authoring_session=#{token}"], headers: { "x-csrf-token" => "csrf-token" }
    ))
    payload = JSON.parse(sqs.messages.fetch(0).fetch(:message_body))

    assert_equal 202, response.fetch(:statusCode)
    assert_equal "https://example.com/post", payload.fetch("source")
    assert_equal "page-id", payload.fetch("target_page_id")
  end

  def test_failed_delivery_can_be_requeued_from_the_management_api
    @database.webmention_delivery_failures = [{
      "id" => "delivery-id", "page_id" => "page-id",
      "source_url" => "https://weblog.ason.as/article", "target_url" => "https://example.com/post",
    }]
    sqs = FakeSqs.new
    api, token = authenticated_api(sqs:)

    response = api.call(event(
      "POST", "/api/authoring/webmention-deliveries/delivery-id/retry", { "id" => "delivery-id" },
      cookies: ["weblog_authoring_session=#{token}"], headers: { "x-csrf-token" => "csrf-token" }
    ))
    message = sqs.messages.fetch(0)
    payload = JSON.parse(message.fetch(:message_body))

    assert_equal 202, response.fetch(:statusCode)
    assert_equal "deliver", payload.fetch("type")
    assert_equal "delivery-id", payload.fetch("delivery_id")
    assert_equal "https://example.com/post", payload.fetch("target")
  end

  def test_dead_letters_can_be_redriven_from_the_management_api
    sqs = FakeSqs.new
    api, token = authenticated_api(sqs:)

    response = api.call(event(
      "POST", "/api/authoring/webmention-dead-letters/verification/retry", { "kind" => "verification" },
      cookies: ["weblog_authoring_session=#{token}"], headers: { "x-csrf-token" => "csrf-token" }
    ))

    assert_equal 202, response.fetch(:statusCode)
    assert_equal({ source_arn: "arn:verification-dlq", destination_arn: "arn:verification" }, sqs.move_tasks.fetch(0))
    assert_equal "move-task", JSON.parse(response.fetch(:body)).fetch("task_handle")
  end

  def test_public_page_payload_contains_only_approved_webmentions
    @database.webmentions = [webmention.merge("moderation_status" => "approved")]

    response = @api.call(event("GET", "/api/routes/article", { "route" => "記事名" }))
    mention = JSON.parse(response.fetch(:body)).fetch("external_mentions").fetch(0)

    assert_equal "mention-id", mention.fetch("id")
  end

  private

  def authenticated_api(sqs:, logger: $stderr)
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: codec,
      allowed_github_user_id: 630_181,
      sqs_client: sqs,
      search_queue_url: "https://sqs.example/search.fifo",
      webmention_queue_url: "https://sqs.example/webmention.fifo",
      webmention_dead_letter_arn: "arn:verification-dlq",
      webmention_queue_arn: "arn:verification",
      webmention_publish_dead_letter_arn: "arn:publishing-dlq",
      webmention_publish_queue_arn: "arn:publishing",
      logger:
    )
    [api, token]
  end

  def webmention
    {
      "id" => "mention-id", "source_url" => "https://example.com/post",
      "target_url" => "https://weblog.ason.as/article", "target_page_id" => "page-id",
      "verification_status" => "verified", "moderation_status" => "pending",
      "candidate" => { "title" => "Example", "site_name" => "Example Site" }, "approved" => nil,
    }
  end

  def page_document(id:, name:, body:, created_at: Time.iso8601("2026-08-22T10:00:00+09:00"),
                    updated_at: Time.iso8601("2026-08-22T11:00:00+09:00"))
    WeblogAuthoring::PageDocument.new(
      id:,
      page_type: "named",
      name:,
      page_date: nil,
      title: nil,
      status: "published",
      created_at:,
      updated_at:,
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
      "requestContext" => { "requestId" => "request-id", "http" => { "method" => method } },
    }
  end
end
