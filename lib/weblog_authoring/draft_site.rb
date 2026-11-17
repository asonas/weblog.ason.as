# frozen_string_literal: true

require "uri"
require "digest"
require "json"
require_relative "draft_publisher"
require_relative "webmention_site_publisher"
require_relative "operation_metrics"
require_relative "sitemap"
require_relative "markdown_export"

module WeblogAuthoring
  class DraftSite
    PUBLIC_HTML_CACHE_CONTROL = "public, max-age=0, s-maxage=86400, stale-while-revalidate=300, stale-if-error=86400"
    SITEMAP_CACHE_CONTROL = "public, max-age=300, s-maxage=3600"
    HOME_PATHS = ["/", "/index.html"].freeze
    HOME_MARKDOWN_LIMIT = 30

    def initialize(api:, reader:, s3_client:, bucket:, published:, store: nil, site_url: nil, dynamic_article_routes: [], public_cache_enabled: false)
      @api = api
      @reader = reader
      @s3 = s3_client
      @bucket = bucket
      @published = published
      @store = store
      @site_url = site_url&.delete_suffix("/")
      @dynamic_article_routes = dynamic_article_routes.freeze
      @public_cache_control = public_cache_enabled ? PUBLIC_HTML_CACHE_CONTROL : "public, max-age=0, s-maxage=180, stale-if-error=86400"
    end

    def call(event)
      method = event.dig("requestContext", "http", "method")
      path = event.fetch("rawPath", "")
      path = path.delete_suffix("/") if path != "/"
      return @api.call(event) unless %w[GET HEAD].include?(method) && !path.start_with?("/api/", "/oauth/")
      OperationMetrics.delivery("stored")
      read_event = event.merge("rawPath" => path, "requestContext" => event.fetch("requestContext").merge("http" => event.fetch("requestContext").fetch("http").merge("method" => "GET")))
      response = if HOME_PATHS.include?(path)
                   home(event)
                 elsif ["/search", "/authoring/articles", "/authoring/webmentions", "/authoring/devices", "/draft-editor"].include?(path)
                   object("index.html", "text/html; charset=utf-8")
                 elsif path == "/sitemap.xml" && publishes_discovery?
                   sitemap
                 elsif @published
                   dynamic_article(path, event) || @api.call(read_event)
                 elsif path == "/feed.xml"
                   object("feed.xml", "application/atom+xml; charset=utf-8")
                 else
                   page = @reader.find_route(URI::DEFAULT_PARSER.unescape(path.delete_prefix("/").delete_suffix("/")))
                   page ? object(page.route, "text/html; charset=utf-8") : @api.call(read_event)
                 end
      if response.fetch(:statusCode) == 404
        route = URI::DEFAULT_PARSER.unescape(path.delete_prefix("/"))
        renderer = WebmentionSitePublisher.new(database: @reader, s3_client: nil, sqs_client: nil, site_bucket: nil, delivery_queue_url: nil)
        release = nil
        html = renderer.render_linked_page(route) do
          release = display_release if @dynamic_article_routes.include?("*")
          release ? release.fetch(:shell) : object("static/authoring/public.html", "text/html; charset=utf-8").fetch(:body)
        end
        if html
          response = if release
                       public_html(html, release.fetch(:id), event)
                     else
                       { statusCode: 200, headers: { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }, body: html }
                     end
          OperationMetrics.delivery("linked", release: release&.fetch(:id))
        end
        response = response.merge(headers: response.fetch(:headers, {}).merge("cache-control" => "no-store")) if response.fetch(:statusCode) == 404
      end
      method == "HEAD" ? response.merge(body: "") : response
    rescue Aws::S3::Errors::NoSuchKey
      { statusCode: 404, headers: { "cache-control" => "no-store" }, body: "Not Found" }
    end

    def backfill_inbox_thumbnails(limit: 100)
      @api.backfill_inbox_thumbnails(limit:)
    end

    private

    def publishes_discovery?
      @published && !@store.nil? && !@site_url.nil?
    end

    # Acceptは見ない。CloudFrontのキャッシュキーに入るのはx-weblog-formatだけで、Acceptで出し分けるとHTMLとMarkdownが同じキーに混ざる
    def markdown?(event)
      publishes_discovery? && event.fetch("headers", {})["x-weblog-format"] == "markdown"
    end

    def home(event)
      response = if markdown?(event)
                   markdown(MarkdownExport.new(site_url: @site_url).home(@reader.list_pages(limit: HOME_MARKDOWN_LIMIT)), "no-store", event)
                 else
                   object("index.html", "text/html; charset=utf-8")
                 end
      publishes_discovery? ? negotiable(response, "/") : response
    end

    def sitemap
      { statusCode: 200, headers: { "content-type" => "application/xml; charset=utf-8", "cache-control" => SITEMAP_CACHE_CONTROL },
        body: Sitemap.new(site_url: @site_url).render(@store.published_routes), }
    end

    def dynamic_article(path, event)
      route = URI::DEFAULT_PARSER.unescape(path.delete_prefix("/"))
      return nil unless @dynamic_article_routes.include?("*") || @dynamic_article_routes.include?(route)

      resolution = @store.resolve_published_route(route)
      snapshot = resolution["snapshot"]
      return nil unless snapshot

      page = ArticleDocument.from_published_version(snapshot)
      article_path = "/#{WeblogAuthoring.encoded_route(page.route)}"
      if markdown?(event)
        OperationMetrics.delivery("markdown")
        return negotiable(markdown(MarkdownExport.new(site_url: @site_url).article(page), @public_cache_control, event), article_path)
      end
      release = display_release
      return nil unless release
      id, shell = release.values_at(:id, :shell)
      renderer = WebmentionSitePublisher.new(database: @reader, s3_client: nil, sqs_client: nil, site_bucket: nil, delivery_queue_url: nil)
      html = renderer.render_document(page, shell:, source_url: "#{@site_url}#{article_path}")
      OperationMetrics.delivery("dynamic", release: id)
      negotiable(public_html(html, id, event), article_path)
    end

    def display_release
      release = JSON.parse(@s3.get_object(bucket: @bucket, key: "display-releases/current.json").body.read)
      id = release.fetch("id")
      return nil unless /\A[0-9a-f]{40}\z/.match?(id)
      shell = @s3.get_object(bucket: @bucket, key: "display-releases/#{id}/public.html").body.read.force_encoding(Encoding::UTF_8)
      { id:, shell: }
    rescue Aws::S3::Errors::NoSuchKey, JSON::ParserError, KeyError
      nil
    end

    def public_html(html, id, event)
      etag = %("#{Digest::SHA256.hexdigest("#{id}\0#{html}")}")
      if event.fetch("headers", {})["if-none-match"] == etag
        return { statusCode: 304, headers: { "cache-control" => @public_cache_control, "etag" => etag }, body: "" }
      end
      { statusCode: 200, headers: { "content-type" => "text/html; charset=utf-8", "cache-control" => @public_cache_control, "etag" => etag }, body: html }
    end

    def markdown(body, cache_control, event)
      etag = %("#{Digest::SHA256.hexdigest("markdown\0#{body}")}")
      if event.fetch("headers", {})["if-none-match"] == etag
        return { statusCode: 304, headers: { "cache-control" => cache_control, "etag" => etag }, body: "" }
      end
      { statusCode: 200, headers: { "content-type" => "text/markdown; charset=utf-8", "cache-control" => cache_control, "etag" => etag }, body: }
    end

    def negotiable(response, path)
      links = %(</feed.xml>; rel="alternate"; type="application/atom+xml", <#{path}>; rel="alternate"; type="text/markdown")
      response.merge(headers: response.fetch(:headers).merge("vary" => "Accept", "link" => links))
    end

    def object(key, content_type)
      { statusCode: 200, headers: { "content-type" => content_type, "cache-control" => "no-store" }, body: @s3.get_object(bucket: @bucket, key:).body.read }
    end
  end
end
