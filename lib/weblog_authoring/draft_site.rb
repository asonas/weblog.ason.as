# frozen_string_literal: true

require "uri"

module WeblogAuthoring
  class DraftSite
    def initialize(api:, reader:, s3_client:, bucket:, published:)
      @api = api
      @reader = reader
      @s3 = s3_client
      @bucket = bucket
      @published = published
    end

    def call(event)
      method = event.dig("requestContext", "http", "method")
      path = event.fetch("rawPath", "")
      path = path.delete_suffix("/") if path != "/"
      return @api.call(event) unless %w[GET HEAD].include?(method) && !path.start_with?("/api/", "/oauth/")
      read_event = event.merge("rawPath" => path, "requestContext" => event.fetch("requestContext").merge("http" => event.fetch("requestContext").fetch("http").merge("method" => "GET")))
      response = if ["/", "/index.html", "/search", "/authoring/articles", "/authoring/webmentions", "/draft-editor"].include?(path)
                   object("index.html", "text/html; charset=utf-8")
                 elsif @published
                   @api.call(read_event)
                 elsif path == "/feed.xml"
                   object("feed.xml", "application/atom+xml; charset=utf-8")
                 else
                   page = @reader.find_route(URI::DEFAULT_PARSER.unescape(path.delete_prefix("/").delete_suffix("/")))
                   page ? object(page.route, "text/html; charset=utf-8") : @api.call(read_event)
                 end
      if response.fetch(:statusCode) == 404
        route = URI::DEFAULT_PARSER.unescape(path.delete_prefix("/"))
        response = object("index.html", "text/html; charset=utf-8") if @reader.list_pages.any? { |page| page.links.any? { |link| link.name == route } }
      end
      method == "HEAD" ? response.merge(body: "") : response
    rescue Aws::S3::Errors::NoSuchKey
      { statusCode: 404, headers: { "cache-control" => "no-store" }, body: "Not Found" }
    end

    def backfill_inbox_thumbnails(limit: 100)
      @api.backfill_inbox_thumbnails(limit:)
    end

    private

    def object(key, content_type)
      { statusCode: 200, headers: { "content-type" => content_type, "cache-control" => "no-store" }, body: @s3.get_object(bucket: @bucket, key:).body.read }
    end
  end
end
