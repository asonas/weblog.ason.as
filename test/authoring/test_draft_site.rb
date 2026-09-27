# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_site"
require "weblog_authoring/lambda_api"
require "weblog_authoring/development_database"
require "weblog_authoring/draft_migration"
require "weblog_authoring/draft_reader"
require "weblog_authoring/local_publication_objects"

class DraftSiteTest < Minitest::Test
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
      assert_equal 404, site.call(event.merge("rawPath" => "/unknown")).fetch(:statusCode)
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
      ids = %w[dc802ad0b89946aeb6b7623c2ba7bc79 ff802ad0b89946aeb6b7623c2ba7bc79]
      articles = %w[選定記事 従来記事].each_with_index.map do |route, index|
        { "id" => ids.fetch(index), "page_type" => "named", "route" => route, "title" => route,
          "body" => index.zero? ? "公開本文 [[従来記事]] ![写真](/assets/photo.jpg)" : "従来本文",
          "cover_mode" => "none", "cover_image_url" => nil, "created_at" => "2026-09-01T01:00:00Z",
          "updated_at" => "2026-09-01T01:00:00Z", "published_at" => "2026-09-01T01:00:00Z", }
      end
      WeblogAuthoring::DraftMigration.new(store:).import("format" => 1, "site_url" => "https://example.com", "articles" => articles)
      reader = WeblogAuthoring::DraftReader.new(store:, database:)
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
        store:, site_url: "https://example.com", dynamic_article_routes: ["選定記事"])
      get = ->(route, method = "GET") { site.call("rawPath" => "/#{WeblogAuthoring.encoded_route(route)}", "requestContext" => { "http" => { "method" => method } }) }

      first = get.call("選定記事")
      assert_equal 200, first.fetch(:statusCode)
      assert_equal WeblogAuthoring::DraftSite::PUBLIC_HTML_CACHE_CONTROL, first.dig(:headers, "cache-control")
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
      assert_equal "no-store", missing.dig(:headers, "cache-control")
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
      objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => "c" * 40))
      assert_includes get.call("選定記事").fetch(:body), "Saved HTML 選定記事"
    end
  end
end
