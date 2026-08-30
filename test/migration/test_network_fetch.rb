# frozen_string_literal: true

require "webrick"
require "digest"
require_relative "../test_helper"

class NetworkFetchMigrationTest < Minitest::Test
  PNG_BYTES = "\x89PNG\r\n\x1a\nphase-zero".b
  IMAGE_BYTES = "\x89PNG\r\n\x1a\nurl-preview".b

  def with_server
    logger = WEBrick::Log.new(File::NULL, WEBrick::Log::WARN)
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: logger, AccessLog: [])
    server.mount_proc("/") do |request, response|
      path = WEBrick::HTTPUtils.unescape(request.path).force_encoding("UTF-8")
      case path
      when "/image.png", "/画像/日本語.png"
        response.status = 200
        response["Content-Type"] = "image/png"
        response.body = PNG_BYTES
      when "/abc123"
        response.status = 200
        response["Content-Type"] = "text/html"
        response.body = '<html><head><meta property="og:image" content="https://i.gyazo.com/abc123.jpg"></head></html>'
      when "/abc123.jpg"
        response.status = 200
        response["Content-Type"] = "image/jpeg"
        response.body = PNG_BYTES
      when "/html-as-image"
        response.status = 200
        response["Content-Type"] = "text/html"
        response.body = "<html>not an image</html>"
      when "/article"
        response.status = 200
        response["Content-Type"] = "text/html"
        response.body = '<html><head><title>Document title</title><meta property="og:title" content="Article &amp; title"><meta property="og:description" content="A useful description"><meta property="og:image" content="/preview.jpg"></head></html>'
      when "/preview.jpg"
        response.status = 200
        response["Content-Type"] = "image/jpeg"
        response.body = IMAGE_BYTES
      when "/no-ogp"
        response.status = 200
        response["Content-Type"] = "text/html"
        response.body = "<html><head><title>Fallback title</title></head></html>"
      when "/broken-image"
        response.status = 200
        response["Content-Type"] = "text/html"
        response.body = '<html><head><meta property="og:title" content="Broken preview"><meta property="og:image" content="/not-an-image"></head></html>'
      when "/not-an-image"
        response.status = 200
        response["Content-Type"] = "text/html"
        response.body = "<html>not an image</html>"
      else
        response.status = 404
        response["Content-Type"] = "text/plain"
        response.body = "missing"
      end
    end
    thread = Thread.new { server.start }
    sleep 0.01 until server.status == :Running
    yield "http://127.0.0.1:#{server.config[:Port]}"
  ensure
    server&.shutdown
    thread&.join
  end

  def test_fetch_assets_preserves_manifest_and_records_failures
    with_server do |base|
      root = Pathname(Dir.mktmpdir)
      manifest = root.join("asset-manifest.json")
      manifest.write(JSON.pretty_generate("assets" => [
        { "source_post_ids" => [], "id" => "asset-image", "url" => "#{base}/image.png", "kind" => "image" },
        { "source_post_ids" => [], "id" => "asset-missing", "url" => "#{base}/missing", "kind" => "url" },
      ]))
      before = manifest.binread
      report = WeblogMigration::Assets.fetch_assets(manifest, root.join("assets"), root.join("fetch.json"))
      assert_equal 1, report["downloaded"]
      assert_equal 1, report["failed"]
      assert_equal PNG_BYTES, root.join("assets", "asset-image.png").binread
      assert_equal Digest::SHA256.hexdigest(PNG_BYTES), report["results"].find { |item| item["id"] == "asset-image" }["sha256"]
      assert_equal before, manifest.binread
    end
  end

  def test_fetch_assets_encodes_unicode_and_resolves_gyazo
    with_server do |base|
      root = Pathname(Dir.mktmpdir)
      manifest = root.join("asset-manifest.json")
      manifest.write(JSON.generate("assets" => [{ "id" => "asset-unicode", "url" => "#{base}/画像/日本語.png", "kind" => "image" }, { "id" => "asset-gyazo", "url" => "https://gyazo.com/abc123", "kind" => "image" }]))
      original_get = WeblogMigration::HTTP.method(:get)
      WeblogMigration::HTTP.define_singleton_method(:get) do |url, **options|
        url = url.sub("https://gyazo.com", base).sub("https://i.gyazo.com", base)
        original_get.call(url, **options)
      end
      report = WeblogMigration::Assets.fetch_assets(manifest, root.join("assets"), root.join("fetch.json"))
      assert_equal 2, report["downloaded"]
      assert root.join("assets", "asset-unicode.png").file?
      gyazo = report["results"].find { |item| item["id"] == "asset-gyazo" }
      assert_equal "https://i.gyazo.com/abc123.jpg", gyazo["fetched_url"]
    ensure
      WeblogMigration::HTTP.define_singleton_method(:get, original_get) if original_get
    end
  end

  def test_fetch_url_metadata_records_ogp_and_fallback_cards
    with_server do |base|
      root = Pathname(Dir.mktmpdir)
      urls = %w[article no-ogp broken-image missing].map { |path| "#{base}/#{path}" }
      manifest = root.join("asset-manifest.json")
      manifest.write(JSON.generate("assets" => urls.map.with_index do |url, index|
        { "id" => WeblogMigration::AssetManifest.stable_url_asset_id(url), "url" => url, "kind" => "url", "source_post_ids" => ["post-#{index}"] }
      end))
      report = WeblogMigration::UrlMetadata.fetch_url_metadata(manifest, root.join("url-metadata.json"), root.join("assets"), root.join("url-metadata-report.json"))
      metadata = JSON.parse(root.join("url-metadata.json").read).fetch("assets").to_h { |item| [item["url"], item] }
      article = metadata.fetch(urls[0])
      assert_equal "ready", article["status"]
      assert_equal "Article & title", article["title"]
      assert_equal "A useful description", article["description"]
      assert_equal Digest::SHA256.hexdigest(IMAGE_BYTES), article.dig("image", "sha256")
      assert_equal "Fallback title", metadata.fetch(urls[1])["title"]
      assert_equal "Broken preview", metadata.fetch(urls[2])["title"]
      assert_includes metadata.fetch(urls[2])["error"], "expected image content"
      assert_equal 1, report["ready"]
      assert_equal 3, report["fallback"]
    end
  end
end
