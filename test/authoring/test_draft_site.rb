# frozen_string_literal: true

require_relative "../test_helper"
require "rexml/document"
require "weblog_authoring/draft_site"
require "weblog_authoring/lambda_api"
require "weblog_authoring/development_database"
require "weblog_authoring/draft_migration"
require "weblog_authoring/published_article_reader"
require "weblog_authoring/local_publication_objects"

class DraftSiteTest < Minitest::Test
  def test_home_and_agent_guide_are_readable_in_the_initial_response
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:get_object, body: File.binread(File.expand_path("../../index.html", __dir__)))
    missing = ->(_event) { { statusCode: 404, body: "" } }
    site = WeblogAuthoring::DraftSite.new(api: missing, reader: nil, s3_client: s3, bucket: "site", published: true)
    request = ->(path, method = "GET") { site.call("rawPath" => path, "requestContext" => { "http" => { "method" => method } }) }

    response = request.call("/")
    assert_equal 200, response.fetch(:statusCode)
    assert_equal "text/html; charset=utf-8", response.dig(:headers, "content-type")
    home = response.fetch(:body)
    main = home[/<main\b.*?<\/main>/m]
    assert_operator main.gsub(/<[^>]*>|\s+/, "").size, :>=, 500
    assert_equal %w[1 2 2], main.scan(/<h([1-6])\b/).flatten
    # rootに本文があるとcreateRootが置き換えて消すので、rootは空にして紹介文を外に置く
    assert_includes main, '<div id="authoring-root"></div>'
    assert_includes home, '<link rel="describedby" href="/llms.txt">'
    head = request.call("/", "HEAD")
    assert_equal response.fetch(:headers), head.fetch(:headers)
    assert_equal "", head.fetch(:body)
    assert_equal home, request.call("/index.html").fetch(:body)
    assert_includes home, '<html lang="ja"'
    assert_includes home, '<link rel="canonical" href="https://weblog.ason.as/">'
    assert_includes home, '<meta property="og:type" content="website">'
    assert_includes home, '<meta property="og:image" content="https://weblog.ason.as/assets/og/home-v1.png">'
    graph = JSON.parse(home[/<script type="application\/ld\+json">(.*?)<\/script>/m, 1]).fetch("@graph")
    refute_empty graph.find { |entity| entity["@type"] == "Blog" }.fetch("description")
    %w[/about /feed.xml /sitemap.xml /weblog.ason.asのしくみ].each { |path| assert_includes home, %(href="#{path}") }
    refute_includes request.call("/search").fetch(:body), "このサイトができるまで"

    guide = request.call("/llms.txt")
    assert_equal 200, guide.fetch(:statusCode)
    assert_equal "text/plain; charset=utf-8", guide.dig(:headers, "content-type")
    assert_match(/\A# weblog\.ason\.as\n\n> /, guide.fetch(:body))
    assert_includes guide.fetch(:body), "## When to use this"
    assert_includes guide.fetch(:body), "Accept: text/markdown"
    assert_includes guide.fetch(:body), "search_articles"
    assert_empty request.call("/llms.txt", "HEAD").fetch(:body)
    assert_equal "llms.txt", WeblogAuthoring.encoded_route("llms.txt")
  end

  def test_mobile_device_settings_serves_the_application_shell
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:get_object, body: "<html>management</html>")
    site = WeblogAuthoring::DraftSite.new(api: nil, reader: nil, s3_client: s3, bucket: "site", published: true)
    event = { "rawPath" => "/authoring/devices", "requestContext" => { "http" => { "method" => "GET" } } }

    response = site.call(event)
    assert_equal 200, response.fetch(:statusCode)
    assert_equal "<html>management</html>", response.fetch(:body)
    assert_equal "index.html", s3.api_requests.last.fetch(:params).fetch(:key)
  end

  def test_linked_topics_render_their_title_and_backlinks_in_the_public_shell
    Dir.mktmpdir("draft-site") do |directory|
      root = Pathname(directory)
      database = WeblogAuthoring::DevelopmentDatabase.new(root.join("articles.sqlite3"), content_dir: root.join("content"))
      database.setup!
      database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", title: "紹介記事", body: "[[KORG multi/poly]]"))
      s3 = Aws::S3::Client.new(stub_responses: true)
      s3.stub_responses(:get_object, body: File.read(File.expand_path("../../public.html", __dir__)))
      site = WeblogAuthoring::DraftSite.new(api: WeblogAuthoring::LambdaApi.new(database:), reader: database, s3_client: s3, bucket: "site", published: true)
      event = { "rawPath" => "/KORG%20multi%2Fpoly", "requestContext" => { "http" => { "method" => "GET" } } }

      response = site.call(event)
      assert_equal 200, response.fetch(:statusCode)
      html = response.fetch(:body)
      assert_includes html, '<h1 class="p-name">KORG multi/poly</h1>'
      assert_includes html, "href=\"/#{WeblogAuthoring.encoded_route('紹介記事')}\""
      assert_includes html, '/frontend/authoring/publicArticle.ts'
      assert_equal "static/authoring/public.html", s3.api_requests.last.fetch(:params).fetch(:key)
      requests_before_missing = s3.api_requests.length
      assert_equal 404, site.call(event.merge("rawPath" => "/unknown")).fetch(:statusCode)
      assert_equal requests_before_missing, s3.api_requests.length
      assert_equal "", site.call(event.merge("requestContext" => { "http" => { "method" => "HEAD" } })).fetch(:body)
    end
  end

  def test_selected_article_uses_published_snapshot_and_switchable_display_release
    Dir.mktmpdir("dynamic-draft-site") do |directory|
      root = Pathname(directory)
      database = WeblogAuthoring::DevelopmentDatabase.new(root.join("articles.sqlite3"), content_dir: root.join("content"))
      database.setup!
      store = WeblogAuthoring::DraftStore.sqlite(root.join("drafts.sqlite3"))
      store.setup!
      ids = %w[dc802ad0b89946aeb6b7623c2ba7bc79 ff802ad0b89946aeb6b7623c2ba7bc79 ab802ad0b89946aeb6b7623c2ba7bc79]
      articles = %w[選定記事 従来記事 about].each_with_index.map do |route, index|
        { "id" => ids.fetch(index), "page_type" => "named", "route" => route, "title" => route,
          "body" => index.zero? ? "公開本文 [[従来記事]] ![写真](/assets/photo.jpg)" : "従来本文",
          "cover_mode" => "none", "cover_image_url" => nil, "created_at" => "2026-09-01T01:00:00Z",
          "updated_at" => "2026-09-01T01:00:00Z", "published_at" => "2026-09-01T01:00:00Z", }
      end
      WeblogAuthoring::DraftMigration.new(store:).import("format" => 1, "site_url" => "https://example.com", "articles" => articles)
      reader = WeblogAuthoring::PublishedArticleReader.new(store:, database:)
      objects = WeblogAuthoring::LocalPublicationObjects.new(root.join("objects"))
      objects.put_object(bucket: "site", key: "static/authoring/public.html", body: '<html><head><title>Old</title></head><body><div id="authoring-root"></div></body></html>')
      ids.each do |id|
        snapshot = store.published_snapshot(id)
        objects.put_object(bucket: "site", key: "published/#{id}/#{snapshot.fetch('id')}.html", body: "Saved HTML #{snapshot.fetch('route')}")
      end
      release_a = "a" * 40
      release_b = "b" * 40
      [release_a, release_b].each do |id|
        shell = %(<html><head><title>サイト</title><link rel="stylesheet" href="/static/authoring/assets/public-#{id}.css"></head><body><div id="authoring-root"></div><script src="/static/authoring/assets/public-#{id}.js"></script></body></html>)
        objects.put_object(bucket: "site", key: "display-releases/#{id}/public.html", body: shell)
      end
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => release_a))
      publisher = WeblogAuthoring::DraftPublisher.s3(publication: nil, database: reader, s3_client: objects,
        site_bucket: "site", site_url: "https://example.com", shell_key: "static/authoring/public.html")
      api = WeblogAuthoring::LambdaApi.new(database:, reader_database: reader, draft_store: store, draft_publisher: publisher)
      site = WeblogAuthoring::DraftSite.new(api:, reader:, s3_client: objects, bucket: "site", published: true,
        store:, site_url: "https://example.com", dynamic_article_routes: ["選定記事"], public_cache_enabled: true)
      get = ->(route, method = "GET") { site.call("rawPath" => "/#{WeblogAuthoring.encoded_route(route)}", "requestContext" => { "http" => { "method" => method } }) }

      first = get.call("選定記事")
      assert_equal 200, first.fetch(:statusCode)
      assert_equal "public, max-age=0, s-maxage=86400, stale-while-revalidate=300, stale-if-error=86400", first.dig(:headers, "cache-control")
      assert_includes first.fetch(:body), "公開本文"
      assert_includes first.fetch(:body), '<meta property="og:title" content="選定記事"'
      assert_includes first.fetch(:body), 'src="/assets/photo.jpg"'
      assert_includes first.fetch(:body), WeblogAuthoring.encoded_route("従来記事")
      assert_includes first.fetch(:body), "data-public-universe="
      assert_includes first.fetch(:body), "public-#{release_a}.js"
      old_response = get.call("従来記事")
      assert_equal "Saved HTML 従来記事", old_response.fetch(:body)
      assert_equal "no-store", old_response.dig(:headers, "cache-control")
      missing = get.call("存在しない記事")
      assert_equal 404, missing.fetch(:statusCode)
      assert_equal "public, max-age=0, s-maxage=60", missing.dig(:headers, "cache-control")
      head = get.call("選定記事", "HEAD")
      assert_equal "", head.fetch(:body)
      assert_equal first.fetch(:headers), head.fetch(:headers)
      request = { "rawPath" => "/#{WeblogAuthoring.encoded_route('選定記事')}", "requestContext" => { "http" => { "method" => "GET" } } }
      assert_equal first, site.call(request.merge("rawPath" => "#{request.fetch('rawPath')}/"))
      assert_equal first, site.call(request.merge("rawQueryString" => "ref=feed", "cookies" => ["session=private"]))
      not_modified = site.call("rawPath" => "/#{WeblogAuthoring.encoded_route('選定記事')}",
        "requestContext" => { "http" => { "method" => "GET" } }, "headers" => { "if-none-match" => first.dig(:headers, "etag") })
      assert_equal 304, not_modified.fetch(:statusCode)
      assert_equal "", not_modified.fetch(:body)
      assert_equal first.dig(:headers, "cache-control"), not_modified.dig(:headers, "cache-control")
      api_response = site.call("rawPath" => "/api/pages/#{ids.first}", "pathParameters" => { "id" => ids.first },
        "requestContext" => { "http" => { "method" => "GET" } })
      assert_equal 200, api_response.fetch(:statusCode)
      assert_includes api_response.fetch(:body), "公開本文"

      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => release_b))
      second = get.call("選定記事")
      assert_includes second.fetch(:body), "public-#{release_b}.css"
      refute_equal first.dig(:headers, "etag"), second.dig(:headers, "etag")
      assert_equal "Saved HTML 従来記事", get.call("従来記事").fetch(:body)

      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => release_a))
      assert_equal first, get.call("選定記事")

      all_pages = WeblogAuthoring::DraftSite.new(api:, reader:, s3_client: objects, bucket: "site", published: true,
        store:, site_url: "https://example.com", dynamic_article_routes: ["*"], public_cache_enabled: true)
      %w[選定記事 従来記事 about].each do |route|
        response = all_pages.call("rawPath" => "/#{WeblogAuthoring.encoded_route(route)}", "requestContext" => { "http" => { "method" => "GET" } })
        assert_equal 200, response.fetch(:statusCode)
        assert_includes response.fetch(:body), "public-#{release_a}.js"
        assert_includes response.fetch(:body), %(<meta property="og:title" content="#{route}")
        assert_equal WeblogAuthoring::DraftSite::PUBLIC_HTML_CACHE_CONTROL, response.dig(:headers, "cache-control")
        refute_includes response.fetch(:body), "Saved HTML"
      end
      objects.put_object(bucket: "site", key: "index.html", body: "Management and home shell")
      # 管理画面と検索のシェルは共有キャッシュに載せない。トップページと同じindex.htmlを返すが、キャッシュ可能にするのはトップページのパスだけ
      { "/" => "public, max-age=0, s-maxage=60", "/index.html" => "public, max-age=0, s-maxage=60", "/search" => "no-store", "/draft-editor" => "no-store",
        "/authoring/devices" => "no-store", "/authoring/articles" => "no-store", "/authoring/webmentions" => "no-store", }.each do |path, cache_control|
        response = all_pages.call("rawPath" => path, "requestContext" => { "http" => { "method" => "GET" } })
        assert_equal "Management and home shell", response.fetch(:body)
        assert_equal cache_control, response.dig(:headers, "cache-control"), path
      end
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => "c" * 40))
      assert_includes get.call("選定記事").fetch(:body), "Saved HTML 選定記事"
      fallback = all_pages.call("rawPath" => "/about", "requestContext" => { "http" => { "method" => "GET" } })
      assert_equal "Saved HTML about", fallback.fetch(:body)
      assert_equal "no-store", fallback.dig(:headers, "cache-control")
    end
  end

  def test_markdown_is_served_only_for_the_edge_normalized_format_header
    Dir.mktmpdir("negotiated-draft-site") do |directory|
      root = Pathname(directory)
      database = WeblogAuthoring::DevelopmentDatabase.new(root.join("articles.sqlite3"), content_dir: root.join("content"))
      database.setup!
      store = WeblogAuthoring::DraftStore.sqlite(root.join("drafts.sqlite3"))
      store.setup!
      articles = { "紹介 記事" => "本文 [[関連/話題]]\n\n[embed:https://example.com/video]\n\n```\n[embed:https://example.com/code]\n```", "空の記事" => "" }.each_with_index.map do |(route, body), index|
        { "id" => "#{index}c802ad0b89946aeb6b7623c2ba7bc79", "page_type" => "named", "route" => route, "title" => route, "body" => body,
          "cover_mode" => "none", "cover_image_url" => nil, "created_at" => "2026-09-01T01:00:00Z",
          "updated_at" => "2026-09-02T01:00:00Z", "published_at" => "2026-09-01T01:00:00Z", }
      end
      WeblogAuthoring::DraftMigration.new(store:).import("format" => 1, "site_url" => "https://example.com", "articles" => articles)
      reader = WeblogAuthoring::PublishedArticleReader.new(store:, database:)
      objects = WeblogAuthoring::LocalPublicationObjects.new(root.join("objects"))
      objects.put_object(bucket: "site", key: "index.html", body: "Management and home shell")
      objects.put_object(bucket: "site", key: "display-releases/#{'a' * 40}/public.html", body: '<html><head><title>サイト</title></head><body><div id="authoring-root"></div></body></html>')
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => "a" * 40))
      api = WeblogAuthoring::LambdaApi.new(database:, reader_database: reader, draft_store: store)
      site = WeblogAuthoring::DraftSite.new(api:, reader:, s3_client: objects, bucket: "site", published: true,
        store:, site_url: "https://example.com", dynamic_article_routes: ["*"], public_cache_enabled: true)
      get = ->(path, headers = {}) { site.call("rawPath" => path, "headers" => headers, "requestContext" => { "http" => { "method" => "GET" } }) }
      article_path = "/#{WeblogAuthoring.encoded_route('紹介 記事')}"
      markdown = { "x-weblog-format" => "markdown" }

      # CloudFrontのキャッシュキーに入らないAcceptで出し分けると、HTMLのキーにMarkdownが保存される
      html = get.call(article_path, "accept" => "text/markdown", "x-weblog-format" => "html")
      assert_equal "text/html; charset=utf-8", html.dig(:headers, "content-type")
      assert_equal "Accept", html.dig(:headers, "vary")
      assert_equal %(</feed.xml>; rel="alternate"; type="application/atom+xml", <#{article_path}>; rel="alternate"; type="text/markdown"), html.dig(:headers, "link")
      assert_includes html.fetch(:body), '<script type="application/ld+json">'

      article = get.call(article_path, markdown)
      assert_equal "text/markdown; charset=utf-8", article.dig(:headers, "content-type")
      assert_equal html.dig(:headers, "cache-control"), article.dig(:headers, "cache-control")
      assert_equal "Accept", article.dig(:headers, "vary")
      assert_equal "# 紹介 記事\n\n本文 [関連/話題](https://example.com/#{WeblogAuthoring.encoded_route('関連/話題')})\n\n<https://example.com/video>\n\n```\n[embed:https://example.com/code]\n```\n", article.fetch(:body)
      assert_equal 304, get.call(article_path, markdown.merge("if-none-match" => article.dig(:headers, "etag"))).fetch(:statusCode)
      refute_equal html.dig(:headers, "etag"), article.dig(:headers, "etag")

      home = get.call("/", markdown)
      assert_equal "text/markdown; charset=utf-8", home.dig(:headers, "content-type")
      assert_equal "public, max-age=0, s-maxage=60", home.dig(:headers, "cache-control")
      assert_includes home.fetch(:body), "- [紹介 記事](https://example.com#{article_path}) (2026-09-02)"
      refute_includes home.fetch(:body), "空の記事"
      assert_equal "Management and home shell", get.call("/").fetch(:body)
      assert_equal "Accept", get.call("/").dig(:headers, "vary")
      %w[/search /draft-editor /authoring/articles].each do |path|
        shell = get.call(path, markdown)
        assert_equal "Management and home shell", shell.fetch(:body)
        assert_equal "no-store", shell.dig(:headers, "cache-control")
      end

      sitemap = get.call("/sitemap.xml")
      assert_equal "application/xml; charset=utf-8", sitemap.dig(:headers, "content-type")
      assert_equal "public, max-age=300, s-maxage=3600", sitemap.dig(:headers, "cache-control")
      locations = REXML::Document.new(sitemap.fetch(:body)).get_elements("//loc").map(&:text)
      assert_equal ["https://example.com/", "https://example.com#{article_path}"], locations
      assert_includes sitemap.fetch(:body), "<lastmod>2026-09-02T01:00:00Z</lastmod>"
    end
  end

  def test_linked_topics_follow_the_display_release_when_all_articles_are_enabled
    Dir.mktmpdir("dynamic-linked-site") do |directory|
      root = Pathname(directory)
      database = WeblogAuthoring::DevelopmentDatabase.new(root.join("articles.sqlite3"), content_dir: root.join("content"))
      database.setup!
      queries = []
      store = WeblogAuthoring::DraftStore.new do |&block|
        connection = SQLite3::Database.new(root.join("drafts.sqlite3").to_s)
        connection.results_as_hash = true
        connection.trace { |sql| queries << sql }
        block.call(WeblogAuthoring::DraftStore::SqliteConnection.new(connection))
      ensure
        connection&.close
      end
      store.setup!
      article = { "id" => "dc802ad0b89946aeb6b7623c2ba7bc79", "page_type" => "named", "route" => "紹介記事", "title" => "紹介記事",
        "body" => "[[KORG multi/poly]]", "cover_mode" => "none", "cover_image_url" => nil,
        "created_at" => "2026-09-01T01:00:00Z", "updated_at" => "2026-09-01T01:00:00Z", "published_at" => "2026-09-01T01:00:00Z", }
      WeblogAuthoring::DraftMigration.new(store:).import("format" => 1, "site_url" => "https://example.com", "articles" => [article])
      reader = WeblogAuthoring::PublishedArticleReader.new(store:, database:)
      objects = WeblogAuthoring::LocalPublicationObjects.new(root.join("objects"))
      old_shell = '<html><head><title>Old</title></head><body><div id="authoring-root"></div></body></html>'
      objects.put_object(bucket: "site", key: "static/authoring/public.html", body: old_shell)
      %w[a b].each do |letter|
        id = letter * 40
        objects.put_object(bucket: "site", key: "display-releases/#{id}/public.html", body: old_shell.sub("</head>", %(<link rel="stylesheet" href="/#{letter}.css"></head>)))
      end
      api = WeblogAuthoring::LambdaApi.new(database:, reader_database: reader, draft_store: store)
      site = WeblogAuthoring::DraftSite.new(api:, reader:, s3_client: objects, bucket: "site", published: true,
        store:, site_url: "https://example.com", dynamic_article_routes: ["*"], public_cache_enabled: true)
      event = { "rawPath" => "/KORG%20multi%2Fpoly", "requestContext" => { "http" => { "method" => "GET" } } }
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => "a" * 40))
      queries.clear
      first = site.call(event)
      assert_operator queries.count { |sql| sql.include?("FROM article_publication_heads h") && !sql.include?(" WHERE ") }, :<=, 1
      assert_equal 200, first.fetch(:statusCode)
      assert_includes first.fetch(:body), '<h1 class="p-name">KORG multi/poly</h1>'
      assert_includes first.fetch(:body), WeblogAuthoring.encoded_route("紹介記事")
      assert_includes first.fetch(:body), "/a.css"
      assert_equal WeblogAuthoring::DraftSite::PUBLIC_HTML_CACHE_CONTROL, first.dig(:headers, "cache-control")
      assert_equal "", site.call(event.merge("requestContext" => { "http" => { "method" => "HEAD" } })).fetch(:body)
      assert_equal 304, site.call(event.merge("headers" => { "if-none-match" => first.dig(:headers, "etag") })).fetch(:statusCode)
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => "b" * 40))
      second = site.call(event)
      assert_includes second.fetch(:body), "/b.css"
      refute_equal first.dig(:headers, "etag"), second.dig(:headers, "etag")
      missing = site.call(event.merge("rawPath" => "/unknown"))
      assert_equal 404, missing.fetch(:statusCode)
      assert_equal "public, max-age=0, s-maxage=60", missing.dig(:headers, "cache-control")
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => "c" * 40))
      fallback = site.call(event)
      assert_equal 200, fallback.fetch(:statusCode)
      assert_includes fallback.fetch(:body), "KORG multi/poly"
      assert_equal "no-store", fallback.dig(:headers, "cache-control")
    end
  end
end
