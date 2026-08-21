# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_app"

require "fileutils"
require "rack/mock"

class TestDevelopmentApp < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-21T12:00:00+09:00")

  FakeS3Response = Data.define(:content_type, :body)

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
        "status" => "ready"
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
      if key.start_with?("assets/embed-cache/")
        body = @objects[key]
        raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") if body.nil?

        return FakeS3Response.new(content_type: "application/json", body: StringIO.new(body))
      end

      FakeS3Response.new(content_type: "image/jpeg", body: StringIO.new("image-data"))
    end

    def put_object(bucket:, key:, body:, content_type:)
      @requests << { bucket:, key:, body:, content_type: }
      @objects[key] = body
    end
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

  def test_root_shows_new_page_button_and_creates_the_development_database
    status, _headers, body = request("GET", "/")

    assert_equal 200, status
    assert_includes body, '"mode":"home"'
    refute_includes body, 'href="/editor/new"'
    assert_includes body, 'href="/?new=1"'
    assert_includes body, 'href="/?new=daily"'
    assert_includes body, 'id="theme-toggle"'
    assert database_path.file?
  end

  def test_daily_button_opens_the_japanese_daily_template
    status, _headers, body = request("GET", "/api/editor/new?template=daily")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal "2026-08-21", editor.fetch("title")
    assert_equal "[[金曜日]] [[202608]] [[0821]] [[日記]]", editor.fetch("body")
    assert_empty editor.fetch("page_id")

    status, _headers, body = request("GET", "/?new=daily")

    assert_equal 200, status
    assert_includes body, '"title":"2026-08-21"'
    assert_includes body, '[[金曜日]] [[202608]] [[0821]] [[日記]]'
  end

  def test_assets_are_read_from_the_development_bucket
    status, headers, body = request("GET", "/assets/asset_00685adfb0b588d4.jpg")

    assert_equal 200, status
    assert_equal "image/jpeg", headers.fetch("content-type")
    assert_includes headers.fetch("cache-control"), "immutable"
    assert_equal "image-data", body
    assert_equal [{
      bucket: "weblog-asonas-assets-dev-282782318939",
      key: "assets/asset_00685adfb0b588d4.jpg"
    }], s3_client.requests
  end

  def test_first_downloaded_image_is_used_for_the_page_card
    FileUtils.mkdir_p(root.join("data/normalized"))
    FileUtils.mkdir_p(root.join("data/reports"))
    root.join("data/normalized/asset-manifest.json").write(JSON.generate("assets" => [{
      "id" => "asset_00685adfb0b588d4",
      "kind" => "image",
      "url" => "https://gyazo.com/example"
    }]))
    root.join("data/reports/asset-fetch-report.json").write(JSON.generate("results" => [{
      "id" => "asset_00685adfb0b588d4",
      "local_path" => "asset_00685adfb0b588d4.jpg"
    }]))
    application = WeblogAuthoring::DevelopmentApp.application(
      root:,
      clock: -> { FIXED_TIME },
      s3_client:
    )
    json_request_with(
      application,
      "POST",
      "/api/pages",
      page_type: "named",
      title: "画像の記事",
      body: "[https://gyazo.com/example]"
    )

    status, _headers, body = request_with(application, "GET", "/api/pages")

    assert_equal 200, status
    assert_equal "/assets/asset_00685adfb0b588d4.jpg", JSON.parse(body).fetch("pages").fetch(0).fetch("image_url")
  end

  def test_unsafe_asset_filenames_are_rejected_before_s3
    status, _headers, _body = request("GET", "/assets/not-an-asset.jpg")

    assert_equal 404, status
    assert_empty s3_client.requests
  end

  def test_new_editor_saves_and_reads_a_page_from_the_database
    status, _headers, body = request("GET", "/editor/new")

    assert_equal 200, status
    assert_includes body, '"mode":"editor"'
    assert_includes body, '"page_id":""'
    assert_includes body, '"page_type":"named"'
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
    assert_equal "最初の記事", page.fetch("route")

    status, _headers, body = request("PATCH", "/api/pages/#{page.fetch("id")}", payload: {
      page_type: "date",
      date: "2026-08-21",
      title: "最初の記事",
      body: "更新した本文",
      expected_updated_at: page.fetch("updated_at")
    })

    assert_equal 200, status
    assert_includes body, "最初の記事"

    restarted_app = WeblogAuthoring::DevelopmentApp.application(root:, clock: -> { FIXED_TIME })
    status, _headers, body = request_with(restarted_app, "GET", "/editor/#{page.fetch("id")}")

    assert_equal 200, status
    assert_includes body, "更新した本文"
  end

  def test_get_api_bootstraps_home_and_editor_for_vite
    status, headers, body = request("GET", "/api/pages")

    assert_equal 200, status
    assert_equal "application/json", headers.fetch("content-type")
    assert_equal({ "mode" => "home", "tags" => [], "pages" => [], "archive" => [] }, JSON.parse(body))

    status, _headers, body = json_request(
      "POST",
      "/api/pages",
      page_type: "date",
      date: "2026-08-21",
      title: "Viteから開く記事",
      body: "本文 [[日記]] #開発\n[https://example.com/photo.jpg#.png]"
    )
    page = JSON.parse(body)

    status, _headers, body = request("GET", "/api/pages")
    summary = JSON.parse(body).fetch("pages").fetch(0)
    assert_equal 200, status
    assert_equal "2026-08-21T12:00:00.000000000+09:00", summary.fetch("created_at")
    assert_equal "本文 日記", summary.fetch("excerpt")
    assert_equal "https://example.com/photo.jpg", summary.fetch("image_url")
    assert_equal ["日記", "開発"], JSON.parse(body).fetch("tags")
    assert_equal [{ "year" => 2026, "months" => [8] }], JSON.parse(body).fetch("archive")

    status, _headers, body = request("GET", "/api/pages/#{page.fetch("id")}")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_equal "editor", editor.fetch("mode")
    assert_equal page.fetch("id"), editor.fetch("page_id")
    assert_equal "本文 [[日記]] #開発\n[https://example.com/photo.jpg#.png]", editor.fetch("body")

    status, _headers, body = request("GET", "/api/editor/new")

    assert_equal 200, status
    fresh_editor = JSON.parse(body)
    assert_equal "editor", fresh_editor.fetch("mode")
    assert_equal "named", fresh_editor.fetch("page_type")
    assert_empty fresh_editor.fetch("date")
    assert_empty fresh_editor.fetch("page_id")
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
    assert_equal [{ "year" => 2026, "months" => [8] }], home.fetch("archive")
  end

  def test_named_page_accepts_an_empty_body_and_can_be_loaded_by_route
    status, _headers, body = json_request(
      "POST",
      "/api/pages",
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

    status, _headers, body = request("GET", "/foobar")

    assert_equal 200, status
    assert_includes body, '"title":"foobar"'
  end

  def test_editor_returns_cards_for_existing_wiki_link_targets
    _status, _headers, target_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "target", body: ""
    )
    target = JSON.parse(target_body)
    _status, _headers, source_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "source", body: "[[target]] [[missing]]"
    )
    source = JSON.parse(source_body)

    assert_equal ["target"], source.fetch("linked_pages").map { |page| page.fetch("title") }
    refute source.fetch("linked_pages_has_more")

    status, _headers, body = request("GET", "/api/routes/source")

    assert_equal 200, status
    linked_page = JSON.parse(body).fetch("linked_pages").fetch(0)
    assert_equal target.fetch("id"), linked_page.fetch("id")
    assert_equal "target", linked_page.fetch("route")

    status, _headers, body = request("GET", "/api/routes/target")

    assert_equal 200, status
    related_page = JSON.parse(body).fetch("linked_pages").fetch(0)
    assert_equal source.fetch("id"), related_page.fetch("id")
    assert_equal "source", related_page.fetch("route")
  end

  def test_missing_route_returns_pages_that_link_to_its_name
    _status, _headers, source_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "source", body: "[[202608]]"
    )
    source = JSON.parse(source_body)

    status, _headers, body = request("GET", "/api/routes/202608")

    assert_equal 200, status
    editor = JSON.parse(body)
    assert_empty editor.fetch("page_id")
    assert_equal [source.fetch("id")], editor.fetch("linked_pages").map { |page| page.fetch("id") }
  end

  def test_editor_returns_other_pages_that_share_its_wiki_links
    json_request(
      "POST", "/api/pages", page_type: "named", title: "日記", body: ""
    )
    json_request(
      "POST", "/api/pages", page_type: "named", title: "2026-08-08",
      body: "[[202608]] [[0808]] [[日記]]"
    )
    _status, _headers, sibling_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "2026-08-07",
      body: "[[202608]] [[0807]] [[日記]]"
    )
    sibling = JSON.parse(sibling_body)
    json_request(
      "POST", "/api/pages", page_type: "named", title: "unrelated", body: "[[other]]"
    )

    status, _headers, body = request("GET", "/api/routes/2026-08-08")

    assert_equal 200, status
    related = JSON.parse(body).fetch("linked_pages")
    assert_includes related.map { |page| page.fetch("id") }, sibling.fetch("id")
    assert_equal ["202608"], related.find { |page| page.fetch("id") == sibling.fetch("id") }.fetch("related_by")
    assert_equal ["日記"], related.find { |page| page.fetch("route") == "日記" }.fetch("related_by")
    refute_includes related.map { |page| page.fetch("route") }, "unrelated"
  end

  def test_editor_returns_other_pages_that_share_an_external_url
    shared_url = "https://example.com/articles/one"
    json_request(
      "POST", "/api/pages", page_type: "named", title: "source", body: "[#{shared_url}]"
    )
    _status, _headers, sibling_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "sibling", body: "also #{shared_url}"
    )
    sibling = JSON.parse(sibling_body)
    json_request(
      "POST", "/api/pages", page_type: "named", title: "unrelated", body: "https://example.net/other"
    )

    status, _headers, body = request("GET", "/api/routes/source")

    assert_equal 200, status
    related = JSON.parse(body).fetch("linked_pages")
    assert_equal [sibling.fetch("id")], related.map { |page| page.fetch("id") }
    assert_equal [shared_url], related.fetch(0).fetch("related_urls")
  end

  def test_related_pages_are_returned_fifty_at_a_time
    _status, _headers, target_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "target", body: ""
    )
    target = JSON.parse(target_body)
    51.times do |index|
      json_request(
        "POST", "/api/pages", page_type: "named", title: "source-#{index}", body: "[[target]]"
      )
    end

    status, _headers, body = request("GET", "/api/routes/target")

    assert_equal 200, status
    first_page = JSON.parse(body)
    assert_equal 50, first_page.fetch("linked_pages").length
    assert first_page.fetch("linked_pages_has_more")

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
      "POST", "/api/pages", page_type: "named", title: "old", body: ""
    )
    target = JSON.parse(target_body)
    _status, _headers, source_body = json_request(
      "POST", "/api/pages", page_type: "named", title: "source", body: "[[old]]"
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
      "/api/pages",
      page_type: "named",
      title: "broken"
    )

    assert_equal 422, status
    entry = JSON.parse(root.join("log/authoring-development.log").read.lines.last)
    assert_equal "POST", entry.fetch("method")
    assert_equal "/api/pages", entry.fetch("path")
    assert_equal 422, entry.fetch("status")
    assert_includes entry.fetch("error"), "body は必須です"
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
