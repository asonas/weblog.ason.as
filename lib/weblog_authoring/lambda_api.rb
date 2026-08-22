# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "rack/utils"
require "securerandom"
require "uri"

module WeblogAuthoring
  class LambdaApi
    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze

    AUTH_COOKIE = "weblog_authoring_session"
    OAUTH_COOKIE = "weblog_authoring_oauth"
    SESSION_TTL = 12 * 60 * 60
    OAUTH_TTL = 10 * 60

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
      return page_response(@database.find(event.dig("pathParameters", "id"))) if method == "GET" && page_id_path?(path)
      return route_response(event) if method == "GET" && route_path?(path)

      json_response(404, error: "Not Found")
    end

    private

    def health_response
      @database.healthy?
      json_response(200, status: "ok")
    end

    def auth_session_response(event)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      json_response(
        200,
        "authenticated" => !session.nil?,
        "authentication_required" => true,
        "can_edit" => !session.nil?,
        "login" => session&.fetch("login", nil),
        "csrf_token" => session&.fetch("csrf_token", "").to_s
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
  end
end
