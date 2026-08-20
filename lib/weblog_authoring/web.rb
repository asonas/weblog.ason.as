# frozen_string_literal: true

require "cgi"
require "date"
require "erb"
require "json"
require "pathname"
require "rack"
require "time"
require "uri"

require_relative "models"
require_relative "service"

module WeblogAuthoring
  class WebForbiddenError < StandardError
  end

  class WebNotFoundError < StandardError
  end

  class WebInputError < StandardError
    attr_reader :field, :status

    def initialize(message, status: 422, field: nil)
      super(message)
      @status = status
      @field = field
    end
  end

  class WebApp
    TEMPLATE_DIR = Pathname(__dir__).join("../../templates/authoring").expand_path.freeze
    STATIC_DIR = Pathname(__dir__).join("../../static/authoring").expand_path.freeze
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    STATIC_FILES = {
      "/static/authoring/app.css" => ["app.css", "text/css"],
      "/static/authoring/app.js" => ["app.js", "application/javascript"]
    }.freeze
    ALLOWED_PAGE_TYPES = %w[date named].freeze

    def initialize(service, template_dir: TEMPLATE_DIR, static_dir: STATIC_DIR)
      @service = service
      @template_dir = Pathname(template_dir)
      @static_dir = Pathname(static_dir)
    end

    def call(env)
      request = Rack::Request.new(env)
      validate_loopback_host!(request)
      dispatch(request)
    rescue WebForbiddenError => error
      text_response(403, error.message)
    rescue WebNotFoundError => error
      text_response(404, error.message)
    rescue WebInputError => error
      json_response(error.status, error_payload(error.message, field: error.field))
    rescue ArgumentError, TypeError => error
      json_response(422, error_payload(error.message))
    rescue ConflictError, PublishError => error
      json_response(409, error_payload(error.message))
    end

    private

    def dispatch(request)
      path = request.path_info.to_s

      if path.start_with?("/static/authoring/")
        return method_not_allowed_response unless request.get?

        return static_response(path)
      end
      return api_response(request, path) if path.start_with?("/api/")
      return method_not_allowed_response if path == "/api" && !request.get?
      return method_not_allowed_response unless request.get?

      case path
      when "/"
        home_response
      when "/manage"
        management_response(request)
      when "/editor/today"
        editor_response(today_page)
      when "/editor/new"
        new_editor_response(request)
      else
        if path.start_with?("/editor/")
          editor_response(find_page(decode_segment(path.delete_prefix("/editor/"), "page id")))
        else
          local_page_response(decode_route(path))
        end
      end
    end

    def validate_loopback_host!(request)
      unless LOOPBACK_HOSTS.include?(request.host)
        raise WebForbiddenError, "localhostからのアクセスだけを許可しています"
      end

      return if request.get? || request.options?

      origin = request.get_header("HTTP_ORIGIN")
      return if origin.nil? || origin.empty?

      origin_uri = URI.parse(origin)
      valid_origin = %w[http https].include?(origin_uri.scheme) && LOOPBACK_HOSTS.include?(origin_uri.host)
      raise WebForbiddenError, "loopbackのOriginだけを許可しています" unless valid_origin
    rescue URI::InvalidURIError
      raise WebForbiddenError, "Originが不正です"
    end

    def home_response
      page = today_page
      location = page.nil? ? "/editor/today" : "/editor/#{Rack::Utils.escape_path(page.id)}"
      redirect_response(location)
    end

    def today_page
      @service.repository.list_pages.find { |page| page.page_date == @service.today }
    end

    def management_response(request)
      query = request.params.fetch("q", "")
      status = request.params.fetch("status", "")
      status = nil if status.empty?
      unless status.nil? || %w[draft published].include?(status)
        raise ArgumentError, "status は draft または published を指定してください"
      end

      empty_only = request.params.fetch("empty", "") == "1"
      pages = @service.repository.list_pages(query:, status:, empty_only:)
      problems = @service.repository.refresh.problems
      values = {
        title: "管理",
        search: html_attribute(query),
        draft_selected: status == "draft" ? " selected" : "",
        published_selected: status == "published" ? " selected" : "",
        empty_checked: empty_only ? " checked" : "",
        rows: management_rows(pages),
        problems: management_problems(problems),
        today: html_attribute(@service.today.iso8601)
      }
      html_response(render_template("manage.html", values))
    end

    def management_rows(pages)
      return '<tr><td colspan="5">該当するページはありません</td></tr>' if pages.empty?

      pages.map do |page|
        identity = page.page_type == "named" ? page.name : page.page_date.iso8601
        editor_href = "/editor/#{Rack::Utils.escape_path(page.id)}"
        view_href = "/#{WeblogAuthoring.encoded_route(page.route)}"
        <<~HTML
          <tr>
            <td>#{CGI.escapeHTML(page.page_type)}</td>
            <td><a href="#{html_attribute(editor_href)}">#{CGI.escapeHTML(identity)}</a></td>
            <td>#{CGI.escapeHTML(page.status)}</td>
            <td>#{page.empty? ? "空" : "内容あり"}</td>
            <td><a href="#{html_attribute(view_href)}" target="_blank" rel="noopener noreferrer">閲覧</a></td>
          </tr>
        HTML
      end.join
    end

    def management_problems(problems)
      return "<p>問題はありません。</p>" if problems.empty?

      items = problems.map do |problem|
        "<li>#{CGI.escapeHTML(problem.path.basename.to_s)}: #{CGI.escapeHTML(problem.detail)}</li>"
      end.join
      "<ul>#{items}</ul>"
    end

    def editor_response(page, draft: {})
      values = {
        title: "編集",
        page_id: html_attribute(page&.id.to_s),
        page_type: html_attribute(page&.page_type || draft.fetch(:page_type, "date")),
        page_date: html_attribute((page&.page_date || draft[:page_date] || @service.today).iso8601),
        page_name: html_attribute(page&.name || draft.fetch(:name, "")),
        document_title: html_attribute(page&.title || draft.fetch(:title, "")),
        body: CGI.escapeHTML(page&.body || draft.fetch(:body, "")),
        status: CGI.escapeHTML(page&.status || "未保存"),
        saved_at: CGI.escapeHTML(page ? format_time(page.updated_at) : "未保存"),
        expected_updated_at: html_attribute(page&.updated_at&.iso8601.to_s),
        rename_hidden: page&.page_type == "named" ? "" : " hidden",
        title_hidden: (page&.page_type || draft.fetch(:page_type, "date")) == "named" ? " hidden" : ""
      }
      html_response(render_template("editor.html", values))
    end

    def new_editor_response(request)
      page_type = request.params.fetch("type", "date")
      raise ArgumentError, "page_type が不正です" unless ALLOWED_PAGE_TYPES.include?(page_type)

      if page_type == "named"
        name = WeblogAuthoring.validate_page_name(request.params.fetch("name", ""))
        return editor_response(nil, draft: { page_type:, name: })
      end

      page_date = parse_date(request.params.fetch("date", @service.today.iso8601), "date")
      editor_response(nil, draft: { page_type:, page_date: })
    end

    def find_page(page_id)
      page = @service.repository.get_page(page_id)
      raise WebNotFoundError, "ページが見つかりません" if page.nil?

      page
    end

    def local_page_response(route)
      page = @service.repository.find_route_read_only(route)
      backlinks = []
      if page.nil?
        return text_response(404, "ページが見つかりません") if WeblogAuthoring::DATE_NAME.match?(route)

        page = temporary_page(route)
      else
        page = @service.repository.refresh.pages.find { |candidate| candidate.id == page.id } || page
        backlinks = @service.repository.database.backlinks(page.id, public_only: false)
      end

      renderer = MarkdownRenderer.new
      page_html = renderer.render_page(page, backlinks:, mode: "local")
      html_response(render_template("page.html", title: page.display_title, page_html:))
    end

    def temporary_page(name)
      PageDocument.new(
        id: nil,
        page_type: "named",
        name:,
        page_date: nil,
        title: nil,
        status: "draft",
        created_at: nil,
        updated_at: nil,
        published_at: nil,
        path: WeblogAuthoring.page_path(@service.repository.content_dir, "named", name:, page_date: nil),
        body: "",
        links: []
      )
    end

    def decode_route(path)
      raise WebNotFoundError, "ページが見つかりません" unless path.start_with?("/")

      raw_route = path.delete_prefix("/")
      raise WebNotFoundError, "ページが見つかりません" if raw_route.empty? || raw_route.include?("/")

      route = decode_segment(raw_route, "route")
      normalized = WeblogAuthoring.validate_page_name(route)
      raise WebNotFoundError, "ページが見つかりません" unless normalized == route

      normalized
    rescue ArgumentError
      raise WebNotFoundError, "ページが見つかりません"
    end

    def decode_segment(raw, _label)
      raise WebNotFoundError, "ページが見つかりません" if raw.nil? || raw.empty? || raw.include?("/")
      raise WebNotFoundError, "ページが見つかりません" if raw.match?(/%(?![0-9A-Fa-f]{2})/)

      value = Rack::Utils.unescape_path(raw)
      raise WebNotFoundError, "ページが見つかりません" unless value.valid_encoding?
      raise WebNotFoundError, "ページが見つかりません" if value.include?("/")
      if value.each_codepoint.any? { |codepoint| codepoint < 32 || codepoint == 127 }
        raise WebNotFoundError, "ページが見つかりません"
      end

      value
    end

    def api_response(request, path)
      return method_not_allowed_response unless request.post?

      require_json_content_type!(request)
      payload = parse_json(request)

      case path
      when "/api/preview"
        rendered = @service.preview(save_request(payload, preview: true), mode: "local")
        json_response(200, { "html" => rendered.html, "errors" => rendered.problems.map(&:to_s) })
      when "/api/save"
        page = @service.save_draft(save_request(payload))
        json_response(200, page_json(page))
      when "/api/publish"
        request_value = PublishRequest.new(
          page_id: required_string(payload, "page_id"),
          expected_updated_at: expected_updated_at(payload)
        )
        json_response(200, page_json(@service.publish(request_value)))
      when "/api/unpublish"
        json_response(200, page_json(@service.unpublish(required_string(payload, "page_id"))))
      when "/api/rename"
        page_id = required_string(payload, "page_id")
        name = required_string(payload, "name")
        begin
          normalized_name = WeblogAuthoring.validate_page_name(name)
        rescue ArgumentError => error
          raise WebInputError.new(error.message, field: "name")
        end
        json_response(200, page_json(@service.rename(page_id, normalized_name)))
      else
        text_response(404, "APIが見つかりません")
      end
    end

    def require_json_content_type!(request)
      return if request.media_type == "application/json"

      raise WebInputError.new("Content-Type: application/json が必要です", status: 415)
    end

    def parse_json(request)
      payload = JSON.parse(request.body.read.to_s)
      raise WebInputError, "JSON本文はオブジェクトにしてください" unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError => error
      raise WebInputError, "JSON本文が不正です: #{error.message}"
    end

    def save_request(payload, preview: false)
      page_id = optional_string(payload, "page_id")
      current = if preview || page_id.nil?
                  nil
                else
                  page = @service.repository.get_page(page_id)
                  raise ConflictError, "ページが見つかりません" if page.nil?

                  page
                end
      page_type = optional_string(payload, "page_type") || current&.page_type || "date"
      unless ALLOWED_PAGE_TYPES.include?(page_type)
        raise WebInputError.new("page_type が不正です", field: "page_type")
      end

      body = if payload.key?("body")
               optional_string(payload, "body") || ""
             elsif preview
               ""
             else
               raise WebInputError.new("body は必須です", field: "body")
             end
      page_date = if page_type == "date"
                    raw_date = optional_string(payload, "date")
                    raw_date ||= current&.page_date&.iso8601
                    raw_date ||= @service.today.iso8601 if preview
                    raw_date.nil? ? nil : parse_date(raw_date, "date")
                  end
      name = if page_type == "named"
               optional_string(payload, "name") || current&.name
             end
      if !preview && page_type == "named"
        begin
          name = WeblogAuthoring.validate_page_name(name.to_s)
        rescue ArgumentError => error
          raise WebInputError.new(error.message, field: "name")
        end
      end

      SaveRequest.new(
        page_type:,
        body:,
        page_id:,
        name:,
        page_date:,
        title: optional_string(payload, "title"),
        expected_updated_at: expected_updated_at(payload)
      )
    end

    def optional_string(payload, key)
      value = payload[key]
      return nil if value.nil?
      unless value.is_a?(String)
        raise WebInputError.new("#{key} は文字列にしてください", field: key)
      end

      value.empty? ? nil : value
    end

    def required_string(payload, key)
      value = optional_string(payload, key)
      raise WebInputError.new("#{key} は必須です", field: key) if value.nil?

      value
    end

    def expected_updated_at(payload)
      value = optional_string(payload, "expected_updated_at")
      return nil if value.nil?

      Time.iso8601(value)
    rescue ArgumentError
      raise WebInputError.new("expected_updated_at が不正です", field: "expected_updated_at")
    end

    def parse_date(value, key)
      Date.iso8601(value)
    rescue ArgumentError
      raise WebInputError.new("#{key} が不正です", field: key)
    end

    def page_json(page)
      {
        "id" => page.id,
        "page_type" => page.page_type,
        "date" => page.page_date&.iso8601,
        "name" => page.name,
        "title" => page.title,
        "status" => page.status,
        "updated_at" => page.updated_at&.iso8601,
        "route" => page.route
      }
    end

    def render_template(filename, values)
      template = ERB.new(@template_dir.join(filename).read(encoding: "UTF-8"))
      template.result_with_hash(values)
    end

    def static_response(path)
      filename, content_type = STATIC_FILES.fetch(path) do
        return text_response(404, "ファイルが見つかりません")
      end
      response(200, "#{content_type}; charset=utf-8", @static_dir.join(filename).read(encoding: "UTF-8"))
    end

    def format_time(value)
      value.getlocal(TOKYO_OFFSET).strftime("%Y-%m-%d %H:%M")
    end

    def html_attribute(value)
      CGI.escapeHTML(value.to_s)
    end

    def error_payload(message, field: nil)
      { "error" => message, "errors" => { field || "form" => [message] } }
    end

    def method_not_allowed_response
      response(405, "text/plain; charset=utf-8", "許可されていないメソッドです", "allow" => "GET, POST")
    end

    def redirect_response(location)
      [302, { "location" => location, "content-length" => "0" }, [""]]
    end

    def html_response(body, status: 200)
      response(status, "text/html; charset=utf-8", body)
    end

    def text_response(status, body)
      response(status, "text/plain; charset=utf-8", body)
    end

    def json_response(status, value)
      response(status, "application/json; charset=utf-8", JSON.generate(value))
    end

    def response(status, content_type, body, extra_headers = {})
      payload = body.to_s.encode("UTF-8")
      headers = { "content-type" => content_type, "content-length" => payload.bytesize.to_s }.merge(extra_headers)
      [status, headers, [payload]]
    end
  end
end
