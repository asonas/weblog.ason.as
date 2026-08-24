# frozen_string_literal: true

require "base64"
require "date"
require "digest"
require "json"
require "rack/utils"
require "securerandom"
require "time"
require "uri"
require "aws-sdk-s3"

require_relative "embed_metadata"
require_relative "image_inbox"
require_relative "image_upload"
require_relative "models"
require_relative "names"
require_relative "rss_feed"

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
    RELATED_PAGE_LIMIT = 50
    EMBED_CACHE_TTL = 7 * 24 * 60 * 60

    def initialize(database:, oauth: nil, session_codec: nil, redirect_uri: nil, frontend_url: nil,
                   allowed_github_user_id: nil, s3_client: nil, asset_bucket: nil, embed_fetcher: nil,
                   site_bucket: nil, clock: Time.method(:now))
      @database = database
      @oauth = oauth
      @session_codec = session_codec
      @redirect_uri = redirect_uri
      @frontend_url = frontend_url
      @allowed_github_user_id = allowed_github_user_id
      @s3_client = s3_client
      @asset_bucket = asset_bucket
      @site_bucket = site_bucket
      @embed_fetcher = embed_fetcher
      @clock = clock
    end

    def call(event)
      return publish_feed if event["source"] == "aws.events" && event["detail-type"] == "Scheduled Event"

      method = event.dig("requestContext", "http", "method").to_s
      path = event.fetch("rawPath", "")
      return health_response if method == "GET" && path == "/health"
      return auth_session_response(event) if method == "GET" && path == "/api/auth/session"
      return github_login_response(event) if method == "GET" && path == "/api/auth/github"
      return github_callback_response(event) if method == "GET" && path == "/api/auth/github/callback"
      return logout_response(event) if method == "POST" && path == "/api/auth/logout"
      return upload_response(event) if method == "POST" && path == "/api/uploads"
      return inbox_response(event) if method == "GET" && path == "/api/inbox"
      return adopt_inbox_response(event) if method == "POST" && path == "/api/inbox/adopt"
      return pages_response if method == "GET" && path == "/api/pages"
      return related_pages_response(event) if method == "GET" && path == "/api/related"
      return embed_response(event) if method == "GET" && path == "/api/embed"
      return new_editor_response(event) if method == "GET" && path == "/api/editor/new"
      return page_response(@database.find(event.dig("pathParameters", "id")), event:) if method == "GET" && page_id_path?(path)
      return route_response(event) if method == "GET" && route_path?(path)
      return save_response(event, status: 201) if method == "POST" && path == "/api/authoring/pages"
      if method == "PATCH" && authoring_page_id_path?(path)
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

    def publish_feed
      body = RssFeed.new(site_url: @frontend_url).render(@database.list_pages)
      @s3_client.put_object(
        bucket: @site_bucket,
        key: "feed.xml",
        body:,
        content_type: "application/rss+xml; charset=utf-8",
        cache_control: "public, max-age=300"
      )
      { statusCode: 200, body: JSON.generate("status" => "published") }
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
      return daily_editor_response(event) if event.dig("queryStringParameters", "template") == "daily"

      json_response(200, editor_json(title: "", name: "", body: ""))
    end

    def daily_editor_response(event)
      date = Time.now.getlocal(TOKYO_OFFSET).to_date
      title = date.iso8601
      page = @database.find_route(title)
      return page_response(page, event:) unless page.nil?

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

    def upload_response(event)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      return json_response(401, error: "GitHub login is required to upload") if session.nil?
      return json_response(403, error: "Editing is not allowed for this GitHub account") unless allowed_session?(session)
      expected_csrf_token = session.fetch("csrf_token", "")
      return json_response(403, error: "CSRF token mismatch") unless secure_equal?(expected_csrf_token, csrf_token_from(event))

      payload = parse_json(event)
      upload = ImageUpload.new(
        s3_client: @s3_client,
        bucket: @asset_bucket,
        clock: @clock
      ).create(
        content_type: payload["content_type"],
        size: payload["size"],
        inbox_date: payload["inbox_date"]
      )
      json_response(200, upload)
    end

    def inbox_response(event)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      return json_response(401, error: "GitHub login is required to view the inbox") if session.nil?
      return json_response(403, error: "Editing is not allowed for this GitHub account") unless allowed_session?(session)

      images = image_inbox.list(date: event.dig("queryStringParameters", "date"))
      json_response(200, "images" => images)
    end

    def adopt_inbox_response(event)
      session = read_cookie(event, AUTH_COOKIE, kind: "session")
      return json_response(401, error: "GitHub login is required to use the inbox") if session.nil?
      return json_response(403, error: "Editing is not allowed for this GitHub account") unless allowed_session?(session)
      expected_csrf_token = session.fetch("csrf_token", "")
      return json_response(403, error: "CSRF token mismatch") unless secure_equal?(expected_csrf_token, csrf_token_from(event))

      json_response(200, image_inbox.adopt(key: parse_json(event)["key"]))
    end

    def image_inbox
      ImageInbox.new(s3_client: @s3_client, bucket: @asset_bucket)
    end

    def page_response(page, event:)
      return json_response(404, error: "Page not found") if page.nil?

      conditional_json_response(event, editor_json(page:))
    end

    def related_pages_response(event)
      query = event.fetch("queryStringParameters", {}).to_h
      page = query["excluding_id"].to_s.empty? ? nil : @database.find(query["excluding_id"])
      result = related_page_result(
        query.fetch("route", ""),
        page&.body || query.fetch("body", ""),
        excluding_id: page&.id,
        offset: Integer(query.fetch("offset", 0))
      )
      json_response(200, result)
    rescue ArgumentError
      json_response(422, error: "Invalid offset")
    end

    def embed_response(event)
      url = event.dig("queryStringParameters", "url").to_s
      raise InputError.new("url is required", field: "url") if url.empty?

      json_response(200, embed_metadata(url))
    rescue EmbedMetadataFetcher::UnsafeUrlError => error
      json_response(422, error: error.message)
    end

    def embed_metadata(url)
      key = "assets/embed-cache/#{Digest::SHA256.hexdigest(url)}.json"
      cached = read_embed_cache(key, url)
      return cached unless cached.nil?

      metadata = @embed_fetcher.fetch(url)
      write_embed_cache(key, metadata.merge("fetched_at" => @clock.call.iso8601))
    rescue EmbedMetadataFetcher::FetchError
      fallback = {
        "url" => url,
        "canonical_url" => url,
        "title" => URI.parse(url).host || url,
        "description" => nil,
        "image_url" => nil,
        "site_name" => URI.parse(url).host,
        "status" => "fallback",
        "fetched_at" => @clock.call.iso8601,
      }
      write_embed_cache(key, fallback)
    end

    def read_embed_cache(key, url)
      object = @s3_client.get_object(bucket: @asset_bucket, key:)
      metadata = JSON.parse(object.body.read)
      return nil unless metadata["url"] == url

      fetched_at = Time.iso8601(metadata.fetch("fetched_at"))
      @clock.call - fetched_at <= EMBED_CACHE_TTL ? metadata : nil
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound, JSON::ParserError, KeyError, ArgumentError
      nil
    end

    def write_embed_cache(key, metadata)
      @s3_client.put_object(
        bucket: @asset_bucket,
        key:,
        body: JSON.generate(metadata),
        content_type: "application/json; charset=utf-8"
      )
      metadata
    end

    def route_response(event)
      route = event.dig("pathParameters", "route").to_s
      route = URI.decode_www_form_component(route)
      route = WeblogAuthoring.validate_page_name(route)
      page = @database.find_route(route)
      return page_response(page, event:) unless page.nil?

      json_response(200, editor_json(title: route, name: route, body: ""))
    rescue ArgumentError
      json_response(422, error: "Invalid route")
    end

    def page_id_path?(path)
      path.start_with?("/api/pages/")
    end

    def authoring_page_id_path?(path)
      path.start_with?("/api/authoring/pages/")
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
      resolved_name = page&.name.to_s.empty? ? name.to_s : page.name.to_s
      resolved_title = page ? page.display_title : title.to_s
      resolved_body = page ? page.body : body.to_s
      {
        "mode" => "editor",
        "page_id" => page&.id.to_s,
        "page_type" => page&.page_type || "named",
        "date" => page&.page_date&.iso8601.to_s,
        "name" => resolved_name,
        "title" => resolved_title,
        "body" => resolved_body,
        "expected_updated_at" => page&.updated_at&.iso8601(9).to_s,
        "save_message" => "",
        "linked_pages" => [],
        "linked_pages_has_more" => !page.nil?,
      }
    end

    def related_page_result(route, body, excluding_id: nil, offset: 0)
      pages = @database.list_pages
      outgoing_names = WeblogAuthoring.extract_wiki_links(body.to_s).map(&:name).uniq
      outgoing_urls = WeblogAuthoring.extract_external_urls(body.to_s)

      related = pages.each_with_index.filter_map do |page, index|
        next if page.id == excluding_id

        page_link_names = page.links.map(&:name)
        related_by = outgoing_names.filter do |name|
          next page.route == name if name == "日記"

          page.route == name || page_link_names.include?(name)
        end
        related_by << route if !route.to_s.empty? && page_link_names.include?(route)
        related_urls = WeblogAuthoring.extract_external_urls(page.body.to_s) & outgoing_urls
        next if related_by.empty? && related_urls.empty?

        direct_link_index = outgoing_names.index(page.route)
        priority = direct_link_index.nil? ? 1 : 0
        order = direct_link_index || index
        summary = page_summary(page).merge(
          "related_by" => related_by.uniq,
          "related_urls" => related_urls
        )
        [priority, order, summary]
      end.sort_by { |priority, order, _page| [priority, order] }.map(&:last)

      {
        "pages" => related.slice(offset, RELATED_PAGE_LIMIT) || [],
        "has_more" => offset + RELATED_PAGE_LIMIT < related.length,
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
      related = related_page_result(page.route, page.body, excluding_id: page.id)
      {
        "id" => page.id,
        "page_type" => page.page_type,
        "date" => page.page_date&.iso8601,
        "name" => page.name,
        "title" => page.title,
        "status" => page.status,
        "updated_at" => page.updated_at.iso8601(9),
        "route" => page.route,
        "linked_pages" => related.fetch("pages"),
        "linked_pages_has_more" => related.fetch("has_more"),
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

    def conditional_json_response(event, payload)
      body = JSON.generate(payload)
      etag = %Q("#{Digest::SHA256.hexdigest(body)}")
      headers = JSON_HEADERS.merge("cache-control" => "no-cache", "etag" => etag)
      return { statusCode: 304, headers:, body: "" } if event.fetch("headers", {}).to_h["if-none-match"] == etag

      { statusCode: 200, headers:, body: }
    end

    def json_error(status, message, field: nil)
      json_response(status, error: message, errors: { field || "form" => [message] })
    end
  end
end
