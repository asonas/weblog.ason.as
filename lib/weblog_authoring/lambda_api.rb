# frozen_string_literal: true

require "base64"
require "date"
require "digest"
require "json"
require "rack/utils"
require "securerandom"
require "time"
require "uri"

require_relative "models"
require_relative "names"

module WeblogAuthoring
  class LambdaApi
    class InputError < StandardError
      attr_reader :field, :status

      def initialize(message, status: 422, field: nil)
        super(message)
        @status = status
        @field = field
      end
    end

    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze

    AUTH_COOKIE = "weblog_authoring_session"
    OAUTH_COOKIE = "weblog_authoring_oauth"
    SESSION_TTL = 12 * 60 * 60
    OAUTH_TTL = 10 * 60
    TOKYO_OFFSET = "+09:00"
    HASHTAG_PATTERN = /(?:\A|\s)#([^\s#\[\]]+)/
    JAPANESE_WEEKDAYS = %w[日曜日 月曜日 火曜日 水曜日 木曜日 金曜日 土曜日].freeze

    def initialize(database:, oauth: nil, session_codec: nil, redirect_uri: nil, frontend_url: nil,
                   allowed_github_user_id: nil)
      @database = database
      @oauth = oauth
      @session_codec = session_codec
      @redirect_uri = redirect_uri
      @frontend_url = frontend_url
      @allowed_github_user_id = allowed_github_user_id
    end

    def call(event)
      method = event.dig("requestContext", "http", "method").to_s
      path = event.fetch("rawPath", "")
      return health_response if method == "GET" && path == "/health"
      return auth_session_response(event) if method == "GET" && path == "/api/auth/session"
      return github_login_response(event) if method == "GET" && path == "/api/auth/github"
      return github_callback_response(event) if method == "GET" && path == "/api/auth/github/callback"
      return logout_response(event) if method == "POST" && path == "/api/auth/logout"
      return pages_response if method == "GET" && path == "/api/pages"
      return new_editor_response(event) if method == "GET" && path == "/api/editor/new"
      return page_response(@database.find(event.dig("pathParameters", "id"))) if method == "GET" && page_id_path?(path)
      return route_response(event) if method == "GET" && route_path?(path)
      return save_response(event, status: 201) if method == "POST" && path == "/api/pages"
      if method == "PATCH" && page_id_path?(path)
        return save_response(event, page_id: event.dig("pathParameters", "id"))
      end

      json_response(404, error: "Not Found")
    rescue InputError => error
      json_error(error.status, error.message, field: error.field)
    rescue ConflictError => error
      json_error(409, error.message)
    rescue ArgumentError, TypeError => error
      json_error(422, error.message)
    end

    private

    def health_response
      @database.healthy?
      json_response(200, status: "ok")
    end

    def auth_session_response(event)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      can_edit = allowed_session?(session)
      json_response(
        200,
        "authenticated" => !session.nil?,
        "authentication_required" => true,
        "can_edit" => can_edit,
        "login" => session&.fetch("login", nil),
        "csrf_token" => can_edit ? session.fetch("csrf_token", "").to_s : ""
      )
    end

    def github_login_response(event)
      state = SecureRandom.urlsafe_base64(32)
      verifier = SecureRandom.urlsafe_base64(64)
      token = @session_codec.issue(
        kind: "oauth",
        attributes: {
          "state" => state,
          "verifier" => verifier,
          "return_to" => safe_return_to(event.dig("queryStringParameters", "return_to")),
        },
        ttl: OAUTH_TTL
      )
      redirect_response(
        @oauth.authorization_url(
          redirect_uri: @redirect_uri,
          state:,
          code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        ),
        cookie(OAUTH_COOKIE, token, max_age: OAUTH_TTL)
      )
    end

    def github_callback_response(event)
      oauth_session = read_cookie(event, OAUTH_COOKIE, kind: "oauth")
      supplied_state = event.dig("queryStringParameters", "state").to_s
      unless secure_equal?(oauth_session&.fetch("state", ""), supplied_state)
        return json_response(422, error: "GitHub OAuth state mismatch")
      end

      user = @oauth.authenticate(
        code: event.dig("queryStringParameters", "code").to_s,
        redirect_uri: @redirect_uri,
        code_verifier: oauth_session.fetch("verifier")
      )
      unless user.fetch("id") == @allowed_github_user_id
        return json_response(403, error: "Editing is not allowed for this GitHub account")
      end

      session = @session_codec.issue(
        kind: "session",
        attributes: {
          "github_user_id" => user.fetch("id"),
          "login" => user.fetch("login"),
          "csrf_token" => SecureRandom.urlsafe_base64(32),
        },
        ttl: SESSION_TTL
      )
      redirect_response(
        "#{@frontend_url}#{oauth_session.fetch("return_to")}",
        cookie(AUTH_COOKIE, session, max_age: SESSION_TTL),
        expired_cookie(OAUTH_COOKIE)
      )
    rescue GitHubOAuthError => error
      json_response(502, error: error.message)
    end

    def logout_response(event)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      supplied = csrf_token_from(event)
      return json_response(403, error: "CSRF token mismatch") unless secure_equal?(session&.fetch("csrf_token", ""), supplied)

      redirect_response(@frontend_url, expired_cookie(AUTH_COOKIE))
    end

    def pages_response
      pages = @database.list_pages
      json_response(
        200,
        "mode" => "home",
        "tags" => recent_tags(pages),
        "pages" => pages.first(30).map { |page| page_summary(page) },
        "archive" => archive_years(pages)
      )
    end

    def new_editor_response(event)
      return daily_editor_response if event.dig("queryStringParameters", "template") == "daily"

      json_response(200, editor_json(title: "", name: "", body: ""))
    end

    def daily_editor_response
      date = Time.now.getlocal(TOKYO_OFFSET).to_date
      title = date.iso8601
      page = @database.find_route(title)
      return page_response(page) unless page.nil?

      links = [
        JAPANESE_WEEKDAYS.fetch(date.wday),
        date.strftime("%Y%m"),
        date.strftime("%m%d"),
        "日記",
      ].map { |name| "[[#{name}]]" }.join(" ")
      json_response(200, editor_json(title:, name: title, body: links))
    end

    def save_response(event, page_id: nil, status: 200)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      return json_response(401, error: "GitHub login is required to edit") if session.nil?
      return json_response(403, error: "Editing is not allowed for this GitHub account") unless allowed_session?(session)
      expected_csrf_token = session.fetch("csrf_token", "")
      return json_response(403, error: "CSRF token mismatch") unless secure_equal?(expected_csrf_token, csrf_token_from(event))
      return json_response(404, error: "Page not found") if page_id && @database.find(page_id).nil?

      page = @database.save(save_request(parse_json(event), page_id:))
      json_response(status, saved_page_json(page))
    end

    def page_response(page)
      return json_response(404, error: "Page not found") if page.nil?

      json_response(200, editor_json(page:))
    end

    def route_response(event)
      route = event.dig("pathParameters", "route").to_s
      route = URI.decode_www_form_component(route)
      route = WeblogAuthoring.validate_page_name(route)
      page = @database.find_route(route)
      return page_response(page) unless page.nil?

      json_response(200, editor_json(title: route, name: route, body: ""))
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
        "excerpt" => page_excerpt(page),
        "image_url" => page_image_url(page),
      }
    end

    def editor_json(page: nil, title: nil, name: nil, body: nil)
      {
        "mode" => "editor",
        "page_id" => page&.id.to_s,
        "page_type" => page&.page_type || "named",
        "date" => page&.page_date&.iso8601.to_s,
        "name" => page&.name.to_s.empty? ? name.to_s : page.name.to_s,
        "title" => page ? page.display_title : title.to_s,
        "body" => page ? page.body : body.to_s,
        "expected_updated_at" => page&.updated_at&.iso8601(9).to_s,
        "save_message" => "",
        "linked_pages" => [],
        "linked_pages_has_more" => false,
      }
    end

    def recent_tags(pages)
      pages.sort_by(&:updated_at).reverse_each.each_with_object([]) do |page, tags|
        names = page.links.map(&:name)
        names.concat(page.body.to_s.scan(HASHTAG_PATTERN).flatten)
        names.each do |name|
          tag = name.strip
          tags << tag unless tag.empty? || tags.include?(tag)
          return tags if tags.length == 20
        end
      end
    end

    def archive_years(pages)
      months_by_year = pages.each_with_object(Hash.new { |hash, year| hash[year] = [] }) do |page, result|
        date = page.created_at.getlocal(TOKYO_OFFSET)
        result[date.year] << date.month unless result[date.year].include?(date.month)
      end
      return [] if months_by_year.empty?

      newest_year = [Time.now.getlocal(TOKYO_OFFSET).year, months_by_year.keys.max].max
      newest_year.downto(months_by_year.keys.min).map do |year|
        { "year" => year, "months" => months_by_year.fetch(year, []).sort }
      end
    end

    def page_excerpt(page)
      page.body.to_s.lines.map(&:strip)
        .reject { |line| line.empty? || line.match?(/\A!\[/) }
        .join(" ")
        .gsub(/\[\[([^\]]+)\]\]/, "\\1")
        .gsub(/(?:\A|\s)#[^\s#\[\]]+/, " ")
        .gsub(/\s+/, " ")
        .strip
        .slice(0, 600)
    end

    def page_image_url(page)
      page.body.to_s[/!\[[^\]]*\]\((https?:\/\/[^\s)]+|\/assets\/[^\s)]+)(?:\s+[^)]*)?\)/, 1]
    end

    def saved_page_json(page)
      {
        "id" => page.id,
        "page_type" => page.page_type,
        "date" => page.page_date&.iso8601,
        "name" => page.name,
        "title" => page.title,
        "status" => page.status,
        "updated_at" => page.updated_at.iso8601(9),
        "route" => page.route,
        "linked_pages" => [],
        "linked_pages_has_more" => false,
      }
    end

    def parse_json(event)
      media_type = event.fetch("headers", {}).to_h.fetch("content-type", "").split(";", 2).first
      raise InputError.new("Content-Type: application/json is required", status: 415) unless media_type == "application/json"

      body = event.fetch("body", "").to_s
      body = Base64.decode64(body) if event["isBase64Encoded"]
      payload = JSON.parse(body)
      raise InputError, "JSON body must be an object" unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError => error
      raise InputError, "Invalid JSON body: #{error.message}"
    end

    def save_request(payload, page_id: nil)
      page_type = optional_string(payload, "page_type") || "named"
      raise InputError.new("Invalid page_type", field: "page_type") unless %w[date named].include?(page_type)

      body = payload.fetch("body") { raise InputError.new("body is required", field: "body") }
      raise InputError.new("body must be a string", field: "body") unless body.is_a?(String)

      title = optional_string(payload, "title")
      name = optional_string(payload, "name")
      if page_type == "named" && name.nil? && title.nil?
        raise InputError.new("title or name is required", field: "title")
      end

      SaveRequest.new(
        page_type:,
        body:,
        page_id:,
        name:,
        page_date: page_type == "date" ? parse_date(optional_string(payload, "date"), "date") : nil,
        title:,
        expected_updated_at: parse_time(optional_string(payload, "expected_updated_at"), "expected_updated_at")
      )
    end

    def optional_string(payload, key)
      value = payload[key]
      return nil if value.nil?
      raise InputError.new("#{key} must be a string", field: key) unless value.is_a?(String)

      value.empty? ? nil : value
    end

    def parse_date(value, field)
      return nil if value.nil?

      Date.iso8601(value)
    rescue ArgumentError
      raise InputError.new("Invalid #{field}", field:)
    end

    def parse_time(value, field)
      return nil if value.nil?

      Time.iso8601(value)
    rescue ArgumentError
      raise InputError.new("Invalid #{field}", field:)
    end

    def allowed_session?(session)
      return false if session.nil?

      Integer(session.fetch("github_user_id")) == @allowed_github_user_id
    rescue ArgumentError, KeyError, TypeError
      false
    end

    def read_cookie(event, name, kind:)
      raw = Array(event["cookies"]).find { |value| value.start_with?("#{name}=") }
      @session_codec&.read(raw.to_s.delete_prefix("#{name}="), kind:)
    end

    def csrf_token_from(event)
      header = event.fetch("headers", {}).to_h.fetch("x-csrf-token", "")
      return header unless header.empty?

      body = event.fetch("body", "").to_s
      body = Base64.decode64(body) if event["isBase64Encoded"]
      URI.decode_www_form(body).to_h.fetch("csrf_token", "")
    rescue ArgumentError
      ""
    end

    def safe_return_to(value)
      candidate = value.to_s
      candidate.start_with?("/") && !candidate.start_with?("//") ? candidate : "/"
    end

    def secure_equal?(expected, supplied)
      return false if expected.to_s.empty? || expected.bytesize != supplied.bytesize

      Rack::Utils.secure_compare(expected, supplied)
    end

    def cookie(name, value, max_age:)
      "#{name}=#{value}; Path=/; Max-Age=#{max_age}; Secure; HttpOnly; SameSite=Lax"
    end

    def expired_cookie(name)
      "#{name}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax"
    end

    def redirect_response(location, *cookies)
      {
        statusCode: 302,
        headers: { "location" => location },
        cookies:,
        body: "",
      }
    end

    def json_response(status, payload)
      {
        statusCode: status,
        headers: JSON_HEADERS,
        body: JSON.generate(payload),
      }
    end

    def json_error(status, message, field: nil)
      json_response(status, error: message, errors: { field || "form" => [message] })
    end
  end
end
