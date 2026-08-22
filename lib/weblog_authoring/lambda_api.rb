# frozen_string_literal: true

require "json"
require "uri"

module WeblogAuthoring
  class LambdaApi
    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze

    def initialize(database:)
      @database = database
    end

    def call(event)
      method = event.dig("requestContext", "http", "method").to_s
      path = event.fetch("rawPath", "")
      return health_response if method == "GET" && path == "/health"
      return pages_response if method == "GET" && path == "/api/pages"
      return page_response(@database.find(event.dig("pathParameters", "id"))) if method == "GET" && page_id_path?(path)
      return route_response(event) if method == "GET" && route_path?(path)

      json_response(404, error: "Not Found")
    end

    private

    def health_response
      @database.healthy?
      json_response(200, status: "ok")
    end

    def pages_response
      json_response(200, pages: @database.list_pages.map { |page| page_summary(page) })
    end

    def page_response(page)
      return json_response(404, error: "Page not found") if page.nil?

      json_response(200, page: page_json(page))
    end

    def route_response(event)
      route = event.dig("pathParameters", "route").to_s
      route = URI.decode_www_form_component(route)
      page_response(@database.find_route(route))
    rescue ArgumentError
      json_response(422, error: "Invalid route")
    end

    def page_id_path?(path)
      path.start_with?("/api/pages/")
    end

    def route_path?(path)
      path.start_with?("/api/routes/")
    end

    def page_summary(page)
      {
        "id" => page.id,
        "title" => page.display_title,
        "route" => page.route,
        "created_at" => page.created_at.iso8601(9),
        "updated_at" => page.updated_at.iso8601(9),
      }
    end

    def page_json(page)
      page_summary(page).merge(
        "page_type" => page.page_type,
        "date" => page.page_date&.iso8601,
        "name" => page.name,
        "body" => page.body,
        "status" => page.status,
        "published_at" => page.published_at&.iso8601(9)
      )
    end

    def json_response(status, payload)
      {
        statusCode: status,
        headers: JSON_HEADERS,
        body: JSON.generate(payload),
      }
    end
  end
end
