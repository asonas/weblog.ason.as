# frozen_string_literal: true

require "uri"
require "digest"
require "json"
require_relative "draft_publisher"
require_relative "webmention_site_publisher"
require_relative "operation_metrics"

module WeblogAuthoring
  class DraftSite
    PUBLIC_HTML_CACHE_CONTROL = "public, max-age=0, s-maxage=180, stale-if-error=86400"

    def initialize(api:, reader:, s3_client:, bucket:, published:, store: nil, site_url: nil, dynamic_article_routes: [])
      @api = api
      @reader = reader
      @s3 = s3_client
      @bucket = bucket
      @published = published
      @store = store
      @site_url = site_url&.delete_suffix("/")
      @dynamic_article_routes = dynamic_article_routes.freeze
    end

    def call(event)
      method = event.dig("requestContext", "http", "method")
      path = event.fetch("rawPath", "")
      path = path.delete_suffix("/") if path != "/"
      return @api.call(event) unless %w[GET HEAD].include?(method) && !path.start_with?("/api/", "/oauth/")
      OperationMetrics.delivery("stored")
      read_event = event.merge("rawPath" => path, "requestContext" => event.fetch("requestContext").merge("http" => event.fetch("requestContext").fetch("http").merge("method" => "GET")))
      response = if ["/", "/index.html", "/search", "/authoring/articles", "/authoring/webmentions", "/draft-editor"].include?(path)
                   object("index.html", "text/html; charset=utf-8")
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
        if @reader.list_pages.any? { |page| page.links.any? { |link| link.name == route } }
          renderer = WebmentionSitePublisher.new(database: @reader, s3_client: nil, sqs_client: nil, site_bucket: nil, delivery_queue_url: nil)
          shell = object("static/authoring/public.html", "text/html; charset=utf-8")
          html = renderer.render_linked_page(route, shell: shell.fetch(:body))
          response = shell.merge(body: html) if html
          OperationMetrics.delivery("linked") if html
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

    def dynamic_article(path, event)
      route = URI::DEFAULT_PARSER.unescape(path.delete_prefix("/"))
      return nil unless @dynamic_article_routes.include?(route)

      resolution = @store.resolve_published_route(route)
      snapshot = resolution["snapshot"]
      return nil unless snapshot

      release = JSON.parse(@s3.get_object(bucket: @bucket, key: "display-releases/current.json").body.read)
      id = release.fetch("id")
      raise ArgumentError, "Invalid display release" unless /\A[0-9a-f]{40}\z/.match?(id)
      shell = @s3.get_object(bucket: @bucket, key: "display-releases/#{id}/public.html").body.read.force_encoding(Encoding::UTF_8)
      renderer = WebmentionSitePublisher.new(database: @reader, s3_client: nil, sqs_client: nil, site_bucket: nil, delivery_queue_url: nil)
      page = ArticleDocument.from_published_version(snapshot)
      html = renderer.render_document(page, shell:, source_url: "#{@site_url}/#{WeblogAuthoring.encoded_route(page.route)}")
      OperationMetrics.delivery("dynamic", release: id)
      etag = %("#{Digest::SHA256.hexdigest("#{id}\0#{html}")}")
      if event.fetch("headers", {})["if-none-match"] == etag
        return { statusCode: 304, headers: { "cache-control" => PUBLIC_HTML_CACHE_CONTROL, "etag" => etag }, body: "" }
      end
      { statusCode: 200, headers: { "content-type" => "text/html; charset=utf-8", "cache-control" => PUBLIC_HTML_CACHE_CONTROL, "etag" => etag }, body: html }
    rescue Aws::S3::Errors::NoSuchKey, JSON::ParserError, KeyError
      nil
    end

    def object(key, content_type)
      { statusCode: 200, headers: { "content-type" => content_type, "cache-control" => "no-store" }, body: @s3.get_object(bucket: @bucket, key:).body.read }
    end
  end
end
