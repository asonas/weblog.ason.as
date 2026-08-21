# frozen_string_literal: true

require "cgi"
require "date"
require "erb"
require "json"
require "pathname"
require "rack"
require "rack/reloader"
require "sinatra/base"
require "time"
require "uri"

require_relative "development_database"
require_relative "models"
require_relative "names"

module WeblogAuthoring
  class DevelopmentInputError < StandardError
    attr_reader :field, :status

    def initialize(message, status: 422, field: nil)
      super(message)
      @field = field
      @status = status
    end
  end

  class DevelopmentApp < Sinatra::Base
    ROOT = Pathname(__dir__).join("../..").expand_path.freeze
    TEMPLATE_DIR = ROOT.join("templates/authoring").freeze
    STATIC_DIR = ROOT.join("static/authoring").freeze
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    STATIC_FILES = {
      "app.css" => ["text/css", "app.css"],
      "app.js" => ["application/javascript", "app.js"]
    }.freeze
    ALLOWED_PAGE_TYPES = %w[date named].freeze

    set :environment, :development
    set :show_exceptions, false
    set :static, false
    set :logging, false

    before do
      validate_loopback_host!
    end

    get "/" do
      render_shell(
        title: "weblog",
        initial_state: {
          "mode" => "home",
          "pages" => settings.database.list_pages.map { |page| page_summary(page) }
        }
      )
    end

    get "/editor/new" do
      render_shell(title: "編集", initial_state: new_editor_state)
    end

    get "/editor/:id" do
      page = settings.database.find(params.fetch("id"))
      halt 404, "ページが見つかりません" if page.nil?

      render_editor(
        page_id: page.id,
        page_type: page.page_type,
        date: page.page_date&.iso8601.to_s,
        name: page.name.to_s,
        title: page.page_type == "named" ? page.name.to_s : page.title.to_s,
        body: page.body,
        expected_updated_at: page.updated_at.iso8601(9),
        save_message: "保存済み・最終更新 #{format_time(page.updated_at)}"
      )
    end

    get "/api/pages" do
      json_response({
        "mode" => "home",
        "pages" => settings.database.list_pages.map { |page| page_summary(page) }
      })
    end

    get "/api/editor/new" do
      json_response(new_editor_state)
    end

    get "/api/pages/:id" do
      page = settings.database.find(params.fetch("id"))
      return json_error(404, "ページが見つかりません") if page.nil?

      json_response(editor_json(page))
    end

    get "/static/authoring/:asset" do
      content_type, filename = STATIC_FILES.fetch(params.fetch("asset")) { halt 404 }
      content_type content_type
      send_file STATIC_DIR.join(filename).to_s
    end

    post "/api/pages" do
      api_response(201) do |payload|
        request = save_request(payload)
        page = settings.database.save(request)
        page_json(page)
      end
    end

    patch "/api/pages/:id" do
      api_response do |payload|
        request = save_request(payload, page_id: params.fetch("id"))
        page = settings.database.save(request)
        page_json(page)
      end
    end

    error DevelopmentInputError do
      error = env.fetch("sinatra.error")
      json_error(error.status, error.message, field: error.field)
    end

    error ConflictError do
      error = env.fetch("sinatra.error")
      json_error(409, error.message)
    end

    private

    def self.application(root: ROOT, clock: -> { Time.now.getlocal(DevelopmentDatabase::TOKYO_OFFSET) })
      root_path = Pathname(root).expand_path
      database = DevelopmentDatabase.new(
        root_path.join("data/development/authoring.sqlite3"),
        content_dir: root_path.join("content"),
        clock:
      )
      database.setup!

      app = Class.new(self)
      app.set :root_path, root_path
      app.set :database, database
      app.set :clock, -> { clock }
      Rack::Reloader.new(app, 0)
    end

    def validate_loopback_host!
      return if LOOPBACK_HOSTS.include?(request.host)

      halt 403, "localhostからのアクセスだけを許可しています"
    end

    def render_editor(page_id:, page_type:, date:, name:, title:, body:, expected_updated_at:, save_message:)
      render_shell(
        title: "編集",
        initial_state: editor_json(
          page_id:,
          page_type:,
          date:,
          name:,
          title:,
          body:,
          expected_updated_at:,
          save_message:
        )
      )
    end

    def new_editor_state
      page_type = params.fetch("type", "date")
      raise DevelopmentInputError, "page_type が不正です" unless ALLOWED_PAGE_TYPES.include?(page_type)

      page_date = if page_type == "date"
                    parse_date(params.fetch("date", today.iso8601), "date")
                  end
      name = if page_type == "named" && !params.fetch("name", "").empty?
               WeblogAuthoring.validate_page_name(params.fetch("name"))
             else
               ""
             end

      editor_json(
        page_id: "",
        page_type:,
        date: page_date&.iso8601 || "",
        name:,
        title: page_type == "named" ? name : "",
        body: "",
        expected_updated_at: "",
        save_message: "タイトルを確定すると保存します"
      )
    end

    def editor_json(page = nil, page_id: nil, page_type: nil, date: nil, name: nil, title: nil, body: nil,
                    expected_updated_at: nil, save_message: nil)
      if page
        page_id = page.id
        page_type = page.page_type
        date = page.page_date&.iso8601.to_s
        name = page.name.to_s
        title = page.page_type == "named" ? page.name.to_s : page.title.to_s
        body = page.body
        expected_updated_at = page.updated_at.iso8601(9)
        save_message = "保存済み・最終更新 #{format_time(page.updated_at)}"
      end

      {
        "mode" => "editor",
        "page_id" => page_id,
        "page_type" => page_type,
        "date" => date,
        "name" => name,
        "title" => title,
        "body" => body,
        "expected_updated_at" => expected_updated_at,
        "save_message" => save_message
      }
    end

    def render_shell(title:, initial_state:)
      template = ERB.new(TEMPLATE_DIR.join("app.html").read(encoding: "UTF-8"))
      body = template.result_with_hash(title:, initial_state: safe_json(initial_state))
      content_type "text/html; charset=utf-8"
      body
    end

    def api_response(status = 200)
      payload = parse_json
      content_type :json
      self.status status
      JSON.generate(yield(payload))
    rescue DevelopmentInputError => error
      json_error(error.status, error.message, field: error.field)
    rescue ConflictError => error
      json_error(409, error.message)
    rescue ArgumentError, TypeError => error
      json_error(422, error.message)
    end

    def json_response(payload, status: 200)
      content_type :json
      self.status status
      JSON.generate(payload)
    end

    def parse_json
      unless request.media_type == "application/json"
        raise DevelopmentInputError.new("Content-Type: application/json が必要です", status: 415)
      end

      payload = JSON.parse(request.body.read.to_s)
      raise DevelopmentInputError, "JSON本文はオブジェクトにしてください" unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError => error
      raise DevelopmentInputError, "JSON本文が不正です: #{error.message}"
    end

    def save_request(payload, page_id: nil)
      page_type = optional_string(payload, "page_type") || "date"
      unless ALLOWED_PAGE_TYPES.include?(page_type)
        raise DevelopmentInputError.new("page_type が不正です", field: "page_type")
      end

      body = required_string(payload, "body")
      title = optional_string(payload, "title")
      name = optional_string(payload, "name")
      page_date = if page_type == "date"
                    parse_date(optional_string(payload, "date") || today.iso8601, "date")
                  end

      if page_type == "named" && name.nil? && title.nil?
        raise DevelopmentInputError.new("タイトルまたはページ名が必要です", field: "title")
      end

      SaveRequest.new(
        page_type:,
        body:,
        page_id:,
        name:,
        page_date:,
        title:,
        expected_updated_at: expected_updated_at(payload)
      )
    end

    def optional_string(payload, key)
      value = payload[key]
      return nil if value.nil?
      raise DevelopmentInputError.new("#{key} は文字列にしてください", field: key) unless value.is_a?(String)

      value.empty? ? nil : value
    end

    def required_string(payload, key)
      value = optional_string(payload, key)
      raise DevelopmentInputError.new("#{key} は必須です", field: key) if value.nil?

      value
    end

    def expected_updated_at(payload)
      value = optional_string(payload, "expected_updated_at")
      return nil if value.nil?

      Time.iso8601(value)
    rescue ArgumentError
      raise DevelopmentInputError.new("expected_updated_at が不正です", field: "expected_updated_at")
    end

    def parse_date(value, key)
      Date.iso8601(value)
    rescue ArgumentError
      raise DevelopmentInputError.new("#{key} が不正です", field: key)
    end

    def page_json(page)
      {
        "id" => page.id,
        "page_type" => page.page_type,
        "date" => page.page_date&.iso8601,
        "name" => page.name,
        "title" => page.title,
        "status" => page.status,
        "updated_at" => page.updated_at.iso8601(9),
        "route" => page.route
      }
    end

    def page_summary(page)
      {
        "id" => page.id,
        "title" => page.display_title,
        "route" => page.route,
        "updated_at" => page.updated_at.iso8601(9)
      }
    end

    def today
      @today ||= settings.clock.call.getlocal(DevelopmentDatabase::TOKYO_OFFSET).to_date
    end

    def format_time(value)
      value.getlocal(DevelopmentDatabase::TOKYO_OFFSET).strftime("%Y-%m-%d %H:%M")
    end

    def safe_json(value)
      JSON.generate(value).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
    end

    def json_error(status, message, field: nil)
      content_type :json
      self.status status
      JSON.generate("error" => message, "errors" => { field || "form" => [message] })
    end
  end
end
