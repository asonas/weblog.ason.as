# frozen_string_literal: true

require "cgi"
require "date"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "rack"
require "rack/reloader"
require "rack/session/cookie"
require "securerandom"
require "sinatra/base"
require "time"
require "uri"
require "aws-sdk-s3"
require "aws-sdk-secretsmanager"
require "base64"

require_relative "development_database"
require_relative "embed_metadata"
require_relative "github_oauth"
require_relative "image_inbox"
require_relative "image_upload"
require_relative "inbox_sync"
require_relative "bluesky_source"
require_relative "raindrop_source"
require_relative "mobile_upload"
require_relative "models"
require_relative "names"
require_relative "atom_feed"

module WeblogAuthoring
  class DevelopmentRequestLog
    def initialize(app, path)
      @app = app
      FileUtils.mkdir_p(path.dirname)
      @output = path.open("a", encoding: "UTF-8")
      @output.sync = true
    end

    def call(env)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      chunks = body.each.to_a
      body.close if body.respond_to?(:close)
      write(env, status, headers, chunks.join, started_at)
      [status, headers, chunks]
    rescue StandardError => error
      write(env, 500, {}, "#{error.class}: #{error.message}", started_at)
      raise
    end

    private

    def write(env, status, headers, response_body, started_at)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      entry = {
        time: Time.now.iso8601(6),
        method: env.fetch("REQUEST_METHOD"),
        path: env.fetch("PATH_INFO"),
        status:,
        duration_ms: (elapsed * 1000).round(1),
      }
      server_timing = headers["server-timing"] || headers["Server-Timing"]
      entry[:server_timing] = server_timing if server_timing
      entry[:error] = response_body if status >= 400
      @output.puts(JSON.generate(entry))
    end
  end

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
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    ALLOWED_PAGE_TYPES = %w[date named].freeze
    JAPANESE_WEEKDAYS = %w[日曜日 月曜日 火曜日 水曜日 木曜日 金曜日 土曜日].freeze
    DIARY_DATE_TAG = /\A(?:\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])|\d{4}(?:0[1-9]|1[0-2])|(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))\z/
    IMAGE_EXTENSIONS = /\.(?:avif|gif|jpe?g|png|webp)(?:[?#]|\z)/i
    HASHTAG_PATTERN = /(?:\A|\s)#([^\s#\[\]]+)/
    RELATED_PAGE_LIMIT = 50
    DEVELOPMENT_ASSET_BUCKET = "weblog-asonas-assets-dev-282782318939"
    DEVELOPMENT_ASSET_REGION = "ap-northeast-1"
    ASSET_FILENAME = /\Aasset_[0-9a-f]{16}\.(?:avif|gif|jpe?g|png|webp)\z/i
    EMBED_CACHE_TTL = 7 * 24 * 60 * 60
    EMBED_FALLBACK_CACHE_TTL = 5 * 60
    INBOX_METADATA_PREFIX = "assets/inbox/.metadata/"
    DEFAULT_ALLOWED_GITHUB_USER_ID = 630_181
    DEFAULT_GITHUB_REDIRECT_URI = "http://127.0.0.1:5173/api/auth/github/callback"
    FRONTEND_ORIGIN = "http://127.0.0.1:5173"

    set :environment, :development
    set :show_exceptions, false
    set :static, false
    set :logging, false

    before do
      validate_loopback_host!
      if settings.authentication_required && mutation_request? && !mobile_device_request?
        require_authenticated!
      end
    end

    get "/api/auth/github" do
      halt 503, "GitHub OAuthが設定されていません" unless settings.authentication_required

      state = SecureRandom.urlsafe_base64(32)
      verifier = SecureRandom.urlsafe_base64(64)
      session[:github_oauth_state] = state
      session[:github_oauth_verifier] = verifier
      session[:github_oauth_return_to] = safe_return_to(params["return_to"])
      redirect settings.oauth_client.authorization_url(
        redirect_uri: settings.github_redirect_uri,
        state:,
        code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      )
    end

    get "/api/auth/github/callback" do
      halt 503, "GitHub OAuthが設定されていません" unless settings.authentication_required

      expected_state = session.delete(:github_oauth_state).to_s
      verifier = session.delete(:github_oauth_verifier).to_s
      supplied_state = params["state"].to_s
      unless valid_oauth_state?(expected_state, supplied_state) && !verifier.empty?
        halt 422, "GitHub OAuthのstateが一致しません"
      end

      user = settings.oauth_client.authenticate(
        code: params.fetch("code", ""),
        redirect_uri: settings.github_redirect_uri,
        code_verifier: verifier
      )
      halt 403, "このGitHubアカウントには編集権限がありません" unless user.fetch("id") == settings.allowed_github_user_id

      session[:github_user] = user
      redirect frontend_url(session.delete(:github_oauth_return_to) || "/")
    rescue GitHubOAuthError => error
      halt 502, error.message
    end

    get "/api/auth/session" do
      json_response(auth_state)
    end

    post "/api/auth/logout" do
      require_csrf!
      session.clear
      redirect frontend_url("/")
    end

    get "/" do
      redirect frontend_url("/"), 307
    end

    get "/api/pages" do
      timings = {}
      payload = page_window(params, timings:).merge("mode" => "home")
      body = measure(timings, "json") { JSON.generate(payload) }
      headers "Server-Timing" => server_timing(timings)
      content_type :json
      body
    end

    get "/api/tags" do
      json_response({ "tags" => recent_tags(settings.database.list_pages) })
    end

    get "/api/archive" do
      json_response({ "archive" => archive_years(settings.database.list_pages) })
    end

    get "/api/page-names" do
      entries = WeblogAuthoring.page_name_entries(settings.database.list_pages)
      conditional_json_response("names" => entries.map { |entry| entry.fetch("name") }, "entries" => entries)
    end

    get "/api/editor/new" do
      json_response(new_editor_state)
    end

    get "/api/pages/:id" do
      page = settings.database.find(params.fetch("id"))
      return json_error(404, "ページが見つかりません") if page.nil?

      conditional_json_response(editor_json(page))
    end

    get "/api/routes/:route" do
      route = valid_page_route(params.fetch("route"))
      return json_error(404, "ページが見つかりません") if route.nil?

      conditional_json_response(editor_state_for_route(route))
    end

    get "/api/related" do
      route = valid_page_route(params.fetch("route", ""))
      return json_error(422, "ページ名が不正です") if route.nil?

      offset = Integer(params.fetch("offset", "0"), 10)
      return json_error(422, "offset が不正です") if offset.negative?

      page = params["excluding_id"].to_s.empty? ? nil : settings.database.find(params["excluding_id"])
      json_response(related_page_result(route, page&.body.to_s, excluding_id: page&.id, offset:))
    rescue ArgumentError
      json_error(422, "offset が不正です")
    end

    get "/api/embed" do
      url = params.fetch("url", "")
      return json_error(422, "URLを指定してください") if url.empty?

      json_response(embed_metadata(url))
    rescue EmbedMetadataFetcher::UnsafeUrlError => error
      json_error(422, error.message)
    end

    get "/feed.xml" do
      content_type "application/atom+xml; charset=utf-8"
      cache_control :public, max_age: 300
      AtomFeed.new(site_url: frontend_url("/").sub(%r{/\z}, "")).render(settings.database.list_pages)
    end

    get "/assets/:filename" do
      filename = params.fetch("filename")
      halt 404 unless ASSET_FILENAME.match?(filename)

      object = s3_client.get_object(
        bucket: settings.asset_bucket,
        key: "assets/#{filename}"
      )
      content_type object.content_type || "application/octet-stream"
      cache_control :public, max_age: 31_536_000, immutable: true
      object.body.read
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      halt 404
    end

    get "/assets/uploads/:year/:month/:filename" do
      year = params.fetch("year")
      month = params.fetch("month")
      filename = params.fetch("filename")
      halt 404 unless /\A\d{4}\z/.match?(year) && /\A(?:0[1-9]|1[0-2])\z/.match?(month)
      halt 404 unless /\A(?:[0-9a-f]{32}|[0-9a-f-]{36})\.(?:gif|jpe?g|png|webp)\z/i.match?(filename)

      object = s3_client.get_object(
        bucket: settings.asset_bucket,
        key: "assets/uploads/#{year}/#{month}/#{filename}"
      )
      content_type object.content_type || "application/octet-stream"
      cache_control :public, max_age: 31_536_000, immutable: true
      object.body.read
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      halt 404
    end

    get "/assets/inbox/:year/:month/:day/:filename" do
      year = params.fetch("year")
      month = params.fetch("month")
      day = params.fetch("day")
      filename = params.fetch("filename")
      halt 404 unless /\A\d{4}\z/.match?(year) && /\A(?:0[1-9]|1[0-2])\z/.match?(month)
      halt 404 unless /\A(?:0[1-9]|[12]\d|3[01])\z/.match?(day)
      halt 404 unless /\A(?:[0-9a-f]{32}|[0-9a-f-]{36})\.(?:gif|jpe?g|png|webp)\z/i.match?(filename)

      object = s3_client.get_object(
        bucket: settings.asset_bucket,
        key: "assets/inbox/#{year}/#{month}/#{day}/#{filename}"
      )
      content_type object.content_type || "application/octet-stream"
      cache_control :private, max_age: 300
      object.body.read
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      halt 404
    end

    post "/api/authoring/pages" do
      api_response(201) do |payload|
        request = save_request(payload)
        page = settings.database.save(request)
        page_json(page)
      end
    end

    post "/api/uploads" do
      api_response do |payload|
        ImageUpload.new(
          s3_client: s3_client,
          bucket: settings.asset_bucket,
          clock: settings.clock
        ).create(
          content_type: payload["content_type"],
          size: payload["size"],
          inbox_date: payload["inbox_date"]
        )
      end
    end

    post "/api/mobile/pairings" do
      api_response(201) { |_payload| mobile_upload.issue_pairing }
    end

    post "/api/mobile/pairings/exchange" do
      mobile_api_response do |payload|
        result = mobile_upload.exchange_pairing(
          code: required_string(payload, "code"),
          device_name: required_string(payload, "device_name")
        )
        [result, 201]
      end
    end

    get "/api/mobile/devices" do
      require_authenticated! if settings.authentication_required
      json_response("devices" => mobile_upload.devices)
    end

    post "/api/mobile/uploads" do
      mobile_api_response do |payload|
        result = mobile_upload.create_upload(token: mobile_bearer_token, payload:)
        halt 401, JSON.generate(error: "A valid device token is required") if result.nil?

        upload, created = result
        [upload, created ? 201 : 200]
      end
    end

    post "/api/mobile/uploads/:upload_id/complete" do
      mobile_api_response do |_payload|
        result = mobile_upload.complete_upload(token: mobile_bearer_token, upload_id: params.fetch("upload_id"))
        halt 401, JSON.generate(error: "A valid device token is required") if result.nil?

        item, created = result
        [{ "item" => inbox_item_json(item) }, created ? 201 : 200]
      end
    end

    delete "/api/mobile/devices/:device_id" do
      api_response do |_payload|
        halt 404 unless mobile_upload.revoke_device(device_id: params.fetch("device_id"))

        { "revoked" => true }
      end
    end

    get "/api/inbox" do
      require_authenticated! if settings.authentication_required
      content_type :json
      sync_development_inbox
      items = settings.database.list_inbox_items(source: params["source"], kind: params["kind"])
      usages = settings.database.list_inbox_item_usages.group_by(&:item_id)
      JSON.generate("items" => items.map { |item| inbox_item_json(item, usages: usages.fetch(item.id, [])) })
    end

    post "/api/inbox/adopt" do
      api_response { |payload| image_inbox.prepare(item_id: required_string(payload, "item_id")) }
    end

    post "/api/inbox/sync" do
      api_response(202) do |payload|
        sources = InboxSync.sources(payload["sources"])
        run_id = SecureRandom.uuid.delete("-")
        queued = settings.database.queue_inbox_sync_run(
          run_id:, trigger: "manual", queued_at: settings.clock.call, sources:
        )
        raise ConflictError, "Selected inbox sources are already running" unless queued

        InboxSync::Runner.new(
          database: settings.database,
          sources: settings.inbox_sources,
          clock: settings.clock
        ).call(trigger: "manual", run_id:, requested_sources: sources)
        { "run_id" => run_id, "status" => "queued", "sources" => sources }
      end
    end

    get "/api/inbox/sync/:run_id" do
      require_authenticated! if settings.authentication_required
      run = settings.database.inbox_sync_run(run_id: params.fetch("run_id"))
      halt 404 if run.nil?

      json_response(run)
    end

    patch "/api/authoring/pages/:id" do
      api_response do |payload|
        request = save_request(payload, page_id: params.fetch("id"))
        page = settings.database.save(request)
        page_json(page)
      end
    end

    post "/api/rename" do
      api_response do |payload|
        page_id = required_string(payload, "page_id")
        name = required_string(payload, "name")
        body = payload.fetch("body") { raise DevelopmentInputError.new("body は必須です", field: "body") }
        raise DevelopmentInputError.new("body は文字列にしてください", field: "body") unless body.is_a?(String)

        page = settings.database.rename(
          page_id,
          name,
          body:,
          expected_updated_at: expected_updated_at(payload)
        )
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

    def self.application(root: ROOT, clock: -> { Time.now.getlocal(DevelopmentDatabase::TOKYO_OFFSET) },
                         s3_client: nil, asset_bucket: DEVELOPMENT_ASSET_BUCKET, embed_fetcher: nil,
                         oauth_client: default_oauth_client, allowed_github_user_id: default_allowed_github_user_id,
                         github_redirect_uri: ENV.fetch("GITHUB_REDIRECT_URI", DEFAULT_GITHUB_REDIRECT_URI),
                         session_secret: nil, inbox_sources: default_inbox_sources)
      root_path = Pathname(root).expand_path
      session_secret ||= development_session_secret(root_path)
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
      app.set :s3_client, s3_client
      app.set :asset_bucket, asset_bucket
      app.set :embed_fetcher, embed_fetcher
      app.set :asset_image_paths, asset_image_paths(root_path)
      app.set :authentication_required, !oauth_client.nil?
      app.set :oauth_client, oauth_client
      app.set :allowed_github_user_id, allowed_github_user_id
      app.set :github_redirect_uri, github_redirect_uri
      app.set :inbox_sources, inbox_sources
      session_app = Rack::Session::Cookie.new(
        app,
        key: "weblog.authoring.development.session",
        secret: session_secret,
        httponly: true,
        same_site: :lax,
        secure: github_redirect_uri.start_with?("https://")
      )
      reloader = Rack::Reloader.new(session_app, 0)
      DevelopmentRequestLog.new(reloader, root_path.join("log/authoring-development.log"))
    end

    def self.development_session_secret(root_path)
      path = root_path.join("data/development/session-secret")
      FileUtils.mkdir_p(path.dirname)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(SecureRandom.hex(64))
      end
      path.read
    rescue Errno::EEXIST
      path.read
    end

    private

    def image_inbox
      ImageInbox.new(s3_client: s3_client, bucket: settings.asset_bucket, database: settings.database)
    end

    def sync_development_inbox
      objects = s3_client.list_objects_v2(
        bucket: settings.asset_bucket,
        prefix: INBOX_METADATA_PREFIX
      )
      objects.contents.each do |object|
        manifest = JSON.parse(s3_client.get_object(bucket: settings.asset_bucket, key: object.key).body.read)
        occurred_at = Time.iso8601(manifest.fetch("occurred_at"))
        next if occurred_at < settings.clock.call - DevelopmentDatabase::INBOX_RETENTION_SECONDS

        settings.database.upsert_inbox_item(
          source: manifest.fetch("source"),
          kind: manifest.fetch("kind"),
          source_id: manifest.fetch("source_id"),
          occurred_at:,
          payload: manifest.fetch("payload")
        )
      rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound,
             JSON::ParserError, KeyError, ArgumentError, TypeError
        next
      end
    end

    def mobile_upload
      MobileUpload.new(
        database: settings.database,
        s3_client: s3_client,
        bucket: settings.asset_bucket,
        clock: settings.clock
      )
    end

    def mobile_device_request?
      request.path_info == "/api/mobile/pairings/exchange" || request.path_info.start_with?("/api/mobile/uploads")
    end

    def mobile_bearer_token
      match = /\ABearer ([^\s]+)\z/.match(request.env.fetch("HTTP_AUTHORIZATION", ""))
      match&.captures&.first
    end

    def mobile_api_response
      payload = parse_json
      body, response_status = yield(payload)
      json_response(body, status: response_status)
    rescue MobileUpload::PairingUnavailable
      json_error(410, "Pairing code is expired or already used")
    rescue MobileUpload::PairingAttemptsExceeded
      json_error(429, "Pairing exchange attempts exceeded")
    rescue MobileUpload::UnsupportedContentType => error
      json_error(415, error.message)
    rescue ConflictError => error
      json_error(409, error.message)
    rescue ArgumentError, TypeError => error
      json_error(422, error.message)
    end

    def inbox_item_json(item, usages: [])
      {
        "id" => item.id,
        "source" => item.source,
        "kind" => item.kind,
        "source_id" => item.source_id,
        "occurred_at" => item.occurred_at.iso8601,
        "ingested_at" => item.ingested_at.iso8601,
        "expires_at" => item.expires_at.iso8601,
        "payload" => item.payload,
        "used_in_pages" => usages.map { |usage| { "id" => usage.page_id, "route" => usage.page_route } },
      }
    end

    class << self
      private

      def default_oauth_client
        client_id = ENV["GITHUB_CLIENT_ID"]
        client_secret = ENV["GITHUB_CLIENT_SECRET"]
        return nil if client_id.to_s.empty? || client_secret.to_s.empty?

        GitHubOAuth.new(client_id:, client_secret:)
      end

      def default_allowed_github_user_id
        Integer(ENV.fetch("GITHUB_ALLOWED_USER_ID", DEFAULT_ALLOWED_GITHUB_USER_ID.to_s), 10)
      end

      def default_inbox_sources
        secret_id = ENV["INBOX_SOURCES_SECRET_ID"]
        bluesky_origin = ENV["BLUESKY_OAUTH_ORIGIN"]
        return pending_inbox_sources if secret_id.to_s.empty? || bluesky_origin.to_s.empty?

        response = Aws::SecretsManager::Client.new(region: DEVELOPMENT_ASSET_REGION).get_secret_value(secret_id:)
        token = JSON.parse(response.secret_string).fetch("raindrop_test_token")
        {
          "bluesky" => BlueskySource.new(client: BlueskySource::HttpClient.new(origin: bluesky_origin)),
          "raindrop" => RaindropSource.new(client: RaindropSource::Client.new(token:)),
          "c4p" => InboxSync::PendingSource.new,
        }
      end

      def pending_inbox_sources
        InboxSync::SOURCES.to_h { |source| [source, InboxSync::PendingSource.new] }
      end

      def asset_image_paths(root_path)
        manifest_path = root_path.join("data/normalized/asset-manifest.json")
        report_path = root_path.join("data/reports/asset-fetch-report.json")
        return {} unless manifest_path.file? && report_path.file?

        manifest = JSON.parse(manifest_path.read(encoding: "UTF-8")).fetch("assets")
        local_paths = JSON.parse(report_path.read(encoding: "UTF-8")).fetch("results").to_h do |result|
          [result["id"], result["local_path"]]
        end
        manifest.each_with_object({}) do |asset, paths|
          local_path = local_paths[asset.fetch("id")]
          paths[asset.fetch("url")] = local_path if asset.fetch("kind") == "image" && local_path
        end
      end
    end

    def validate_loopback_host!
      return if LOOPBACK_HOSTS.include?(request.host)

      halt 403, "localhostからのアクセスだけを許可しています"
    end

    def mutation_request?
      request.post? || request.patch? || request.put? || request.delete?
    end

    def require_authenticated!
      return unless session[:github_user].nil?

      halt 401, json_error(401, "編集するにはGitHubでログインしてください")
    end

    def require_csrf!
      supplied = request.env["HTTP_X_CSRF_TOKEN"].to_s
      supplied = params["csrf_token"].to_s if supplied.empty?
      expected = session[:csrf_token].to_s
      return if !expected.empty? && supplied.bytesize == expected.bytesize && Rack::Utils.secure_compare(supplied, expected)

      halt 403, json_error(403, "CSRFトークンが一致しません")
    end

    def valid_oauth_state?(expected, supplied)
      !expected.empty? && supplied.bytesize == expected.bytesize && Rack::Utils.secure_compare(supplied, expected)
    end

    def safe_return_to(value)
      candidate = value.to_s
      candidate.start_with?("/") && !candidate.start_with?("//") ? candidate : "/"
    end

    def frontend_url(path)
      frontend = URI(FRONTEND_ORIGIN)
      destination = URI(safe_return_to(path))
      frontend.path = destination.path
      frontend.query = destination.query
      frontend.fragment = nil
      frontend.to_s
    end

    def auth_state
      user = session[:github_user]
      {
        "authenticated" => !user.nil?,
        "authentication_required" => settings.authentication_required,
        "can_edit" => !settings.authentication_required || !user.nil?,
        "login" => user&.fetch("login", nil),
        "csrf_token" => csrf_token,
      }
    end

    def csrf_token
      session[:csrf_token] ||= SecureRandom.urlsafe_base64(32)
    end

    def s3_client
      settings.s3_client || (@s3_client ||= Aws::S3::Client.new(region: DEVELOPMENT_ASSET_REGION))
    end

    def embed_fetcher
      settings.embed_fetcher || (@embed_fetcher ||= EmbedMetadataFetcher.new)
    end

    def embed_metadata(url)
      key = "assets/embed-cache/#{Digest::SHA256.hexdigest(url)}.json"
      cached = read_embed_cache(key, url)
      return cached unless cached.nil?

      metadata = embed_fetcher.fetch(url)
      write_embed_cache(key, metadata.merge("fetched_at" => settings.clock.call.iso8601))
    rescue EmbedMetadataFetcher::FetchError
      fallback = {
        "url" => url,
        "canonical_url" => url,
        "title" => URI.parse(url).host || url,
        "description" => nil,
        "image_url" => nil,
        "site_name" => URI.parse(url).host,
        "status" => "fallback",
        "fetched_at" => settings.clock.call.iso8601,
      }
      write_embed_cache(key, fallback)
    end

    def read_embed_cache(key, url)
      object = s3_client.get_object(bucket: settings.asset_bucket, key:)
      metadata = JSON.parse(object.body.read)
      return nil unless metadata["url"] == url

      fetched_at = Time.iso8601(metadata.fetch("fetched_at"))
      ttl = metadata["status"] == "fallback" ? EMBED_FALLBACK_CACHE_TTL : EMBED_CACHE_TTL
      settings.clock.call - fetched_at <= ttl ? metadata : nil
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound, JSON::ParserError, KeyError, ArgumentError
      nil
    end

    def write_embed_cache(key, metadata)
      s3_client.put_object(
        bucket: settings.asset_bucket,
        key:,
        body: JSON.generate(metadata),
        content_type: "application/json; charset=utf-8"
      )
      metadata
    end

    def new_editor_state
      return daily_editor_state if params["template"] == "daily"

      page_type = params.fetch("type", "named")
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

    def daily_editor_state
      date = today
      title = date.iso8601
      page = settings.database.find_route(title)
      return editor_json(page) unless page.nil?

      links = [
        JAPANESE_WEEKDAYS.fetch(date.wday),
        date.strftime("%Y%m"),
        date.strftime("%m%d"),
        "日記",
      ].map { |name| "[[#{name}]]" }.join(" ")

      editor_json(
        page_id: "",
        page_type: "named",
        date: "",
        name: title,
        title:,
        body: links,
        expected_updated_at: "",
        save_message: ""
      )
    end

    def editor_state_for_route(raw_route)
      route = WeblogAuthoring.validate_page_name(raw_route)
      page = settings.database.find_route(route)
      return editor_json(page) unless page.nil?

      editor_json(
        page_id: "",
        page_type: "named",
        date: "",
        name: route,
        title: route,
        body: "",
        expected_updated_at: "",
        save_message: "",
        linked_pages_has_more: true
      )
    end

    def valid_page_route(raw_route)
      WeblogAuthoring.validate_page_name(raw_route)
    rescue ArgumentError
      nil
    end

    def editor_json(page = nil, page_id: nil, page_type: nil, date: nil, name: nil, title: nil, body: nil,
                    expected_updated_at: nil, save_message: nil, linked_pages_has_more: nil, line_updated_at: nil)
      if page
        page_id = page.id
        page_type = page.page_type
        date = page.page_date&.iso8601.to_s
        name = page.name.to_s
        title = page.page_type == "named" ? page.name.to_s : page.title.to_s
        body = page.body
        expected_updated_at = page.updated_at.iso8601(9)
        save_message = "保存済み・最終更新 #{format_time(page.updated_at)}"
        line_updated_at = line_updated_at(page.id)
      end

      {
        "mode" => "editor",
        "page_id" => page_id,
        "page_type" => page_type,
        "date" => date,
        "name" => name,
        "title" => title,
        "body" => body,
        "cover_mode" => page&.cover_mode || "auto",
        "cover_image_url" => page&.cover_image_url,
        "resolved_cover_image_url" => page && page_image_url(page),
        "line_updated_at" => line_updated_at || [],
        "expected_updated_at" => expected_updated_at,
        "save_message" => save_message,
        "linked_pages" => [],
        "linked_pages_has_more" => linked_pages_has_more.nil? ? !page.nil? : linked_pages_has_more,
      }
    end

    def related_page_result(route, body, excluding_id: nil, offset: 0)
      pages = settings.database.list_pages
      outgoing_names = WeblogAuthoring.extract_wiki_links(body.to_s).map(&:name).uniq
      outgoing_urls = WeblogAuthoring.extract_external_urls(body.to_s)

      related = pages.each_with_index.filter_map do |page, index|
        next false if page.id == excluding_id

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
      end.sort_by { |priority, order, _page| [priority, order] }
        .map(&:last)

      {
        "pages" => related.slice(offset, RELATED_PAGE_LIMIT) || [],
        "has_more" => offset + RELATED_PAGE_LIMIT < related.length,
      }
    end

    def api_response(status = 200)
      require_csrf! if settings.authentication_required
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

    def conditional_json_response(payload)
      body = JSON.generate(payload)
      etag = %Q("#{Digest::SHA256.hexdigest(body)}")
      headers "Cache-Control" => "no-cache", "ETag" => etag
      if request.env["HTTP_IF_NONE_MATCH"] == etag
        status 304
        return ""
      end

      content_type :json
      body
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

      body = payload.fetch("body") { raise DevelopmentInputError.new("body は必須です", field: "body") }
      raise DevelopmentInputError.new("body は文字列にしてください", field: "body") unless body.is_a?(String)
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
        expected_updated_at: expected_updated_at(payload),
        consumed_inbox_item_ids: string_array(payload, "consumed_inbox_item_ids"),
        cover_mode: optional_string(payload, "cover_mode"),
        cover_image_url: optional_string(payload, "cover_image_url")
      )
    end

    def string_array(payload, key)
      value = payload[key]
      return [] if value.nil?
      unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
        raise DevelopmentInputError.new("#{key} は空でない文字列の配列にしてください", field: key)
      end

      value
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
      related = related_page_result(page.route, page.body, excluding_id: page.id)
      {
        "id" => page.id,
        "page_type" => page.page_type,
        "date" => page.page_date&.iso8601,
        "name" => page.name,
        "title" => page.title,
        "status" => page.status,
        "updated_at" => page.updated_at.iso8601(9),
        "line_updated_at" => line_updated_at(page.id),
        "route" => page.route,
        "cover_mode" => page.cover_mode,
        "cover_image_url" => page.cover_image_url,
        "resolved_cover_image_url" => page_image_url(page),
        "linked_pages" => related.fetch("pages"),
        "linked_pages_has_more" => related.fetch("has_more"),
      }
    end

    def line_updated_at(page_id)
      settings.database.scrapbox_line_metadata(page_id).map do |line|
        line.fetch(:updated_at)&.iso8601(9)
      end
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
        "is_diary" => page.links.any? { |link| link.name == "日記" },
      }
    end

    def page_window(query, timings: {})
      kind = query["kind"]
      halt 422, "kindが不正です" unless kind.nil? || %w[diary article].include?(kind)
      before = decode_page_cursor(query["before"])
      after = decode_page_cursor(query["after"])
      before ||= month_boundary(query["month"]) if query["month"]
      halt 422, "beforeとafterは同時に指定できません" if before && after

      pages = measure(timings, "db") do
        settings.database.list_pages(limit: 31, before:, after:, kind:)
      end
      has_more = pages.length > 30
      pages = pages.first(30)
      {
        "pages" => measure(timings, "summaries") { pages.map { |page| page_summary(page) } },
        "newer_cursor" => pages.empty? ? nil : encode_page_cursor(pages.first, kind:),
        "older_cursor" => pages.empty? ? nil : encode_page_cursor(pages.last, kind:),
        "has_newer" => after ? has_more : newer_pages?(pages, before:, kind:),
        "has_older" => after ? older_pages?(pages, kind:) : has_more,
      }
    end

    def newer_pages?(pages, before:, kind:)
      return false if pages.empty? && before.nil?

      cursor = pages.empty? ? before : page_cursor(pages.first, kind:)
      settings.database.list_pages(limit: 1, after: cursor, kind:).any?
    end

    def older_pages?(pages, kind:)
      return false if pages.empty?

      settings.database.list_pages(limit: 1, before: page_cursor(pages.last, kind:), kind:).any?
    end

    def page_cursor(page, kind:)
      { timestamp: kind == "diary" ? page.created_at : page.updated_at, id: page.id }
    end

    def encode_page_cursor(page, kind:)
      cursor = page_cursor(page, kind:)
      Base64.urlsafe_encode64(JSON.generate([cursor.fetch(:timestamp).iso8601(9), page.id]), padding: false)
    end

    def decode_page_cursor(value)
      return nil if value.to_s.empty?

      updated_at, id = JSON.parse(Base64.urlsafe_decode64(value.to_s))
      halt 422, "カーソルが不正です" unless updated_at.is_a?(String) && id.is_a?(String)
      { timestamp: Time.iso8601(updated_at), id: }
    rescue ArgumentError, JSON::ParserError
      halt 422, "カーソルが不正です"
    end

    def month_boundary(value)
      match = /\A(\d{4})-(0[1-9]|1[0-2])\z/.match(value.to_s)
      halt 422, "monthはYYYY-MM形式で指定してください" unless match
      date = Date.new(match[1].to_i, match[2].to_i, 1) >> 1
      { timestamp: Time.new(date.year, date.month, 1, 0, 0, 0, DevelopmentDatabase::TOKYO_OFFSET), id: "" }
    end

    def measure(timings, name)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      timings[name] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      result
    end

    def server_timing(timings)
      timings.map { |name, duration| "#{name};dur=#{duration}" }.join(", ")
    end

    def archive_years(pages)
      return [] if pages.empty?

      months_by_year = pages.each_with_object(Hash.new { |hash, year| hash[year] = [] }) do |page, result|
        date = page.updated_at.getlocal(DevelopmentDatabase::TOKYO_OFFSET)
        result[date.year] << date.month unless result[date.year].include?(date.month)
      end
      newest_year = [today.year, months_by_year.keys.max].max
      oldest_year = months_by_year.keys.min

      newest_year.downto(oldest_year).map do |year|
        { "year" => year, "months" => months_by_year.fetch(year, []).sort }
      end
    end

    def recent_tags(pages)
      pages.sort_by(&:updated_at).reverse_each.each_with_object([]) do |page, tags|
        names = page.links.map(&:name)
        names.concat(page.body.to_s.scan(HASHTAG_PATTERN).flatten)
        names.each do |name|
          tag = name.strip
          tags << tag unless tag.empty? || tag == "日記" || JAPANESE_WEEKDAYS.include?(tag) || DIARY_DATE_TAG.match?(tag) || tags.include?(tag)
          return tags if tags.length == 20
        end
      end
    end

    def page_image_url(page)
      CoverImage.resolve(page, asset_image_paths: settings.asset_image_paths)
    end

    def page_excerpt(page)
      lines = page.body.to_s.lines.map(&:strip)
      lines.shift if lines.first == page.display_title
      lines.reject! { |line| line.empty? || line.match?(/\A\[https?:\/\//) }
      lines.join(" ")
        .gsub(/\[\[([^\]]+)\]\]/, "\\1")
        .gsub(/(?:\A|\s)#[^\s#\[\]]+/, " ")
        .gsub(/\s+/, " ")
        .strip
        .slice(0, 600)
    end

    def today
      @today ||= settings.clock.call.getlocal(DevelopmentDatabase::TOKYO_OFFSET).to_date
    end

    def format_time(value)
      value.getlocal(DevelopmentDatabase::TOKYO_OFFSET).strftime("%Y-%m-%d %H:%M")
    end

    def json_error(status, message, field: nil)
      content_type :json
      self.status status
      JSON.generate("error" => message, "errors" => { field || "form" => [message] })
    end
  end
end
