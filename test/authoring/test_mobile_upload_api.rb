# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_database"
require_relative "../../lib/weblog_authoring/lambda_api"
require_relative "../../lib/weblog_authoring/lambda_session"

require "fileutils"

class MobileUploadApiTest < Minitest::Test
  NOW = Time.iso8601("2026-08-27T12:00:00+09:00")

  class FakeThumbnailer
    attr_reader :keys

    def initialize
      @keys = []
    end

    def create(key:)
      keys << key
      key.sub(%r{\Aassets/inbox/}, "assets/inbox/thumbnails/").sub(/\.[^.]+\z/, ".webp")
    end
  end

  def setup
    @now = NOW
    @tmpdir = Pathname(Dir.mktmpdir)
    @database = WeblogAuthoring::DevelopmentDatabase.new(
      @tmpdir.join("authoring.sqlite3"),
      content_dir: @tmpdir.join("content"),
      clock: -> { @now }
    )
    @database.setup!
    @codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    @api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      session_codec: @codec,
      allowed_github_user_id: 630_181,
      clock: -> { @now }
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_allowed_user_issues_and_exchanges_a_one_time_pairing_code
    issued = @api.call(json_event(
      "POST",
      "/api/mobile/pairings",
      {},
      cookies: [session_cookie],
      headers: { "x-csrf-token" => "csrf-token" }
    ))
    pairing = JSON.parse(issued.fetch(:body))

    assert_equal 201, issued.fetch(:statusCode)
    assert_match(/\A[A-Z2-7]{12}\z/, pairing.fetch("code"))
    assert_equal (NOW + 600).iso8601, pairing.fetch("expires_at")

    exchanged = @api.call(json_event(
      "POST",
      "/api/mobile/pairings/exchange",
      { code: pairing.fetch("code"), device_name: "iPhone 16 Pro" }
    ))
    credentials = JSON.parse(exchanged.fetch(:body))

    assert_equal 201, exchanged.fetch(:statusCode)
    assert_match(/\A[\w-]{43}\z/, credentials.fetch("token"))
    assert_equal "iPhone 16 Pro", credentials.fetch("device").fetch("name")

    reused = @api.call(json_event(
      "POST",
      "/api/mobile/pairings/exchange",
      { code: pairing.fetch("code"), device_name: "Another iPhone" }
    ))
    assert_equal 410, reused.fetch(:statusCode)
  end

  def test_paired_device_creates_a_presigned_inbox_upload
    token = paired_device_token
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      s3_client: s3,
      asset_bucket: "production-assets",
      clock: -> { NOW }
    )
    payload = {
      client_upload_id: "11111111-2222-4333-8444-555555555555",
      content_type: "image/jpeg",
      size: 1024,
      sha256: "a" * 64,
      captured_at: "2026-08-27T08:30:00+09:00",
      captured_at_source: "photos",
    }

    unauthorized = api.call(json_event("POST", "/api/mobile/uploads", payload))
    assert_equal 401, unauthorized.fetch(:statusCode)

    response = api.call(json_event(
      "POST",
      "/api/mobile/uploads",
      payload,
      headers: { "authorization" => "Bearer #{token}" }
    ))
    upload = JSON.parse(response.fetch(:body))

    assert_equal 201, response.fetch(:statusCode)
    assert_match(/\A[0-9a-f]{32}\z/, upload.fetch("upload_id"))
    assert_equal (NOW + 300).iso8601, upload.fetch("expires_at")
    assert_equal "image/jpeg", upload.dig("fields", "Content-Type")
    assert_equal "a" * 64, upload.dig("fields", "x-amz-meta-sha256")
    assert_match(%r{\Aassets/inbox/2026/08/27/[0-9a-f]{32}\.jpg\z}, upload.dig("fields", "key"))
  end

  def test_invalid_upload_size_returns_problem_details_and_a_correlated_log
    token = paired_device_token
    log = StringIO.new
    api = mobile_api(logger: log)
    response = api.call(json_event(
      "POST", "/api/mobile/uploads", mobile_upload_payload.merge(size: 0),
      headers: { "authorization" => "Bearer #{token}" }
    ))
    problem = JSON.parse(response.fetch(:body))

    assert_equal 422, response.fetch(:statusCode)
    assert_equal "application/problem+json; charset=utf-8", response.dig(:headers, "content-type")
    assert_equal "https://weblog.ason.as/problems/mobile-upload/invalid-upload-size", problem.fetch("type")
    assert_equal "Invalid upload size", problem.fetch("title")
    assert_equal 422, problem.fetch("status")
    assert_equal "The prepared photo size must be between 1 byte and 25 MiB.", problem.fetch("detail")
    assert_equal "https://weblog.ason.as/problems/instances/request-id", problem.fetch("instance")
    assert_equal "invalid_upload_size", problem.fetch("code")
    assert_equal "size", problem.fetch("field")
    assert_equal "request-id", problem.fetch("request_id")

    entry = JSON.parse(log.string)
    assert_equal "mobile_upload_rejected", entry.fetch("event")
    assert_equal "request-id", entry.fetch("request_id")
    assert_equal "11111111-2222-4333-8444-555555555555", entry.fetch("client_upload_id")
    assert_equal "invalid_upload_size", entry.fetch("code")
    assert_equal 0, entry.fetch("size")
    refute_includes log.string, "authorization"
    refute_includes log.string, "a" * 64
  end

  def test_invalid_upload_metadata_has_stable_problem_types
    token = paired_device_token
    cases = [
      [
        { client_upload_id: "invalid" }, 422,
        "invalid_client_upload_id", "client_upload_id",
      ],
      [
        { content_type: "image/heic" }, 415,
        "unsupported_content_type", "content_type",
      ],
      [
        { sha256: "invalid" }, 422,
        "invalid_sha256", "sha256",
      ],
      [
        { captured_at_source: "camera" }, 422,
        "invalid_captured_at_source", "captured_at_source",
      ],
    ]

    cases.each do |overrides, status, code, field|
      log = StringIO.new
      response = mobile_api(logger: log).call(json_event(
        "POST", "/api/mobile/uploads", mobile_upload_payload.merge(overrides),
        headers: { "authorization" => "Bearer #{token}" }
      ))
      problem = JSON.parse(response.fetch(:body))

      assert_equal status, response.fetch(:statusCode)
      assert_equal "application/problem+json; charset=utf-8", response.dig(:headers, "content-type")
      assert_equal status, problem.fetch("status")
      assert_equal code, problem.fetch("code")
      assert_equal field, problem.fetch("field")
      assert_equal "https://weblog.ason.as/problems/mobile-upload/#{code.tr('_', '-')}", problem.fetch("type")
      entry = JSON.parse(log.string)
      assert_equal code, entry.fetch("code")
      assert_equal field, entry.fetch("field")
      refute_includes log.string, "authorization"
      refute_includes log.string, "a" * 64
      assert_equal 0, mobile_upload_count
    end
  end

  def test_invalid_mobile_upload_json_returns_problem_details
    token = paired_device_token
    log = StringIO.new
    event = json_event(
      "POST", "/api/mobile/uploads", {}, headers: { "authorization" => "Bearer #{token}" }
    ).merge("body" => "{")

    response = mobile_api(logger: log).call(event)
    problem = JSON.parse(response.fetch(:body))

    assert_equal 422, response.fetch(:statusCode)
    assert_equal "application/problem+json; charset=utf-8", response.dig(:headers, "content-type")
    assert_equal "invalid_json_body", problem.fetch("code")
    assert_equal "request-id", problem.fetch("request_id")
    assert_equal "invalid_json_body", JSON.parse(log.string).fetch("code")
    assert_equal 0, mobile_upload_count
  end

  def test_invalid_mobile_upload_content_type_returns_problem_details
    token = paired_device_token
    log = StringIO.new
    response = mobile_api(logger: log).call(json_event(
      "POST", "/api/mobile/uploads", mobile_upload_payload,
      headers: {
        "authorization" => "Bearer #{token}",
        "content-type" => "text/plain",
      }
    ))
    problem = JSON.parse(response.fetch(:body))

    assert_equal 415, response.fetch(:statusCode)
    assert_equal "application/problem+json; charset=utf-8", response.dig(:headers, "content-type")
    assert_equal "invalid_content_type", problem.fetch("code")
    assert_equal 415, problem.fetch("status")
    assert_equal "invalid_content_type", JSON.parse(log.string).fetch("code")
    assert_equal 0, mobile_upload_count
  end

  def test_problem_details_omit_occurrence_fields_without_a_request_id
    token = paired_device_token
    log = StringIO.new
    event = json_event(
      "POST", "/api/mobile/uploads", mobile_upload_payload.merge(size: 0),
      headers: { "authorization" => "Bearer #{token}" }
    )
    event.fetch("requestContext").delete("requestId")

    response = mobile_api(logger: log).call(event)
    problem = JSON.parse(response.fetch(:body))

    assert_equal 422, response.fetch(:statusCode)
    refute problem.key?("instance")
    refute problem.key?("request_id")
    refute JSON.parse(log.string).key?("request_id")
  end

  def test_upload_creation_is_idempotent_for_each_device_client_id
    token = paired_device_token
    api = mobile_api
    payload = mobile_upload_payload
    headers = { "authorization" => "Bearer #{token}" }

    first = api.call(json_event("POST", "/api/mobile/uploads", payload, headers:))
    repeated = api.call(json_event("POST", "/api/mobile/uploads", payload, headers:))
    conflicting = api.call(json_event(
      "POST", "/api/mobile/uploads", payload.merge(size: 2048), headers:
    ))

    first_upload = JSON.parse(first.fetch(:body))
    repeated_upload = JSON.parse(repeated.fetch(:body))
    assert_equal 201, first.fetch(:statusCode)
    assert_equal 200, repeated.fetch(:statusCode)
    assert_equal first_upload.fetch("upload_id"), repeated_upload.fetch("upload_id")
    assert_equal first_upload.dig("fields", "key"), repeated_upload.dig("fields", "key")
    assert_equal 409, conflicting.fetch(:statusCode)
  end

  def test_completion_verifies_s3_and_registers_one_inbox_photo
    token = paired_device_token
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    thumbnailer = FakeThumbnailer.new
    api = WeblogAuthoring::LambdaApi.new(
      database: @database, s3_client: s3, asset_bucket: "production-assets",
      inbox_thumbnail: thumbnailer, clock: -> { NOW }
    )
    headers = { "authorization" => "Bearer #{token}" }
    created = api.call(json_event("POST", "/api/mobile/uploads", mobile_upload_payload, headers:))
    upload = JSON.parse(created.fetch(:body))
    upload_id = upload.fetch("upload_id")
    key = upload.dig("fields", "key")
    s3.stub_responses(:head_object, {
      content_type: "image/jpeg",
      content_length: 1024,
      metadata: { "sha256" => "a" * 64 },
    })

    completed = api.call(json_event(
      "POST", "/api/mobile/uploads/#{upload_id}/complete", {}, headers:,
      path_parameters: { "upload_id" => upload_id }
    ))
    repeated = api.call(json_event(
      "POST", "/api/mobile/uploads/#{upload_id}/complete", {}, headers:,
      path_parameters: { "upload_id" => upload_id }
    ))

    assert_equal 201, completed.fetch(:statusCode), completed.fetch(:body)
    assert_equal 200, repeated.fetch(:statusCode), repeated.fetch(:body)
    first_item = JSON.parse(completed.fetch(:body)).fetch("item")
    repeated_item = JSON.parse(repeated.fetch(:body)).fetch("item")
    assert_equal first_item.fetch("id"), repeated_item.fetch("id")
    assert_equal key, first_item.dig("payload", "inbox_key")
    assert_equal "/#{key.sub(%r{\Aassets/inbox/}, "assets/inbox/thumbnails/").sub(/\.[^.]+\z/, ".webp")}",
                 first_item.dig("payload", "preview_url")
    assert_equal "photos", first_item.dig("payload", "captured_at_source")
    assert_equal "2026-08-27T08:30:00+09:00", first_item.fetch("occurred_at")
    assert_equal [key], thumbnailer.keys
  end

  def test_completion_mirrors_the_photo_and_manifest_to_development_s3
    token = paired_device_token
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database,
      s3_client: s3,
      asset_bucket: "production-assets",
      development_asset_bucket: "development-assets",
      inbox_thumbnail: FakeThumbnailer.new,
      clock: -> { NOW }
    )
    headers = { "authorization" => "Bearer #{token}" }
    created = api.call(json_event("POST", "/api/mobile/uploads", mobile_upload_payload, headers:))
    upload = JSON.parse(created.fetch(:body))
    upload_id = upload.fetch("upload_id")
    key = upload.dig("fields", "key")
    thumbnail_key = key.sub(%r{\Aassets/inbox/}, "assets/inbox/thumbnails/").sub(/\.[^.]+\z/, ".webp")
    s3.stub_responses(:head_object, {
      content_type: "image/jpeg",
      content_length: 1024,
      metadata: { "sha256" => "a" * 64 },
    })

    response = api.call(json_event(
      "POST", "/api/mobile/uploads/#{upload_id}/complete", {}, headers:,
      path_parameters: { "upload_id" => upload_id }
    ))
    repeated = api.call(json_event(
      "POST", "/api/mobile/uploads/#{upload_id}/complete", {}, headers:,
      path_parameters: { "upload_id" => upload_id }
    ))

    assert_equal 201, response.fetch(:statusCode), response.fetch(:body)
    assert_equal 200, repeated.fetch(:statusCode), repeated.fetch(:body)
    copy = s3.api_requests.find { |request| request.fetch(:operation_name) == :copy_object }
    assert_equal({
      bucket: "development-assets",
      key:,
      copy_source: "production-assets/#{key}",
    }, copy.fetch(:params).slice(:bucket, :key, :copy_source))
    manifest = s3.api_requests.find do |request|
      request.fetch(:operation_name) == :put_object && request.dig(:params, :key)&.end_with?(".json")
    end
    assert_equal "development-assets", manifest.dig(:params, :bucket)
    assert_equal "assets/inbox/.metadata/#{upload_id}.json", manifest.dig(:params, :key)
    assert_equal "application/json", manifest.dig(:params, :content_type)
    assert_equal({
      "source" => "photo",
      "kind" => "photo",
      "source_id" => upload_id,
      "occurred_at" => "2026-08-27T08:30:00+09:00",
      "payload" => {
        "inbox_key" => key,
        "preview_url" => "/#{thumbnail_key}",
        "captured_at_source" => "photos",
      },
    }, JSON.parse(manifest.dig(:params, :body)))
    copied_keys = s3.api_requests.filter_map do |request|
      request.dig(:params, :key) if request.fetch(:operation_name) == :copy_object
    end
    manifest_keys = s3.api_requests.filter_map do |request|
      request.dig(:params, :key) if request.fetch(:operation_name) == :put_object
    end
    assert_equal [key, thumbnail_key], copied_keys.uniq
    assert_equal ["assets/inbox/.metadata/#{upload_id}.json"], manifest_keys.uniq
  end

  def test_completion_rejects_an_s3_object_with_different_metadata
    token = paired_device_token
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database, s3_client: s3, asset_bucket: "production-assets",
      inbox_thumbnail: FakeThumbnailer.new, clock: -> { NOW }
    )
    headers = { "authorization" => "Bearer #{token}" }
    created = api.call(json_event("POST", "/api/mobile/uploads", mobile_upload_payload, headers:))
    upload_id = JSON.parse(created.fetch(:body)).fetch("upload_id")
    s3.stub_responses(:head_object, {
      content_type: "image/jpeg", content_length: 2048, metadata: { "sha256" => "a" * 64 },
    })

    response = api.call(json_event(
      "POST", "/api/mobile/uploads/#{upload_id}/complete", {}, headers:,
      path_parameters: { "upload_id" => upload_id }
    ))
    inbox = @api.call(json_event("GET", "/api/inbox", {}, cookies: [session_cookie]))

    assert_equal 409, response.fetch(:statusCode)
    assert_empty JSON.parse(inbox.fetch(:body)).fetch("items")
  end

  def test_completion_rejects_an_unknown_upload_with_conflict
    response = mobile_api.call(json_event(
      "POST", "/api/mobile/uploads/missing/complete", {},
      headers: { "authorization" => "Bearer #{paired_device_token}" },
      path_parameters: { "upload_id" => "missing" }
    ))

    assert_equal 409, response.fetch(:statusCode)
  end

  def test_pairing_expires_and_stops_after_five_failed_exchanges
    issued = issue_pairing
    code = issued.fetch("code")

    4.times do
      failed = @api.call(json_event(
        "POST", "/api/mobile/pairings/exchange", { code: "AAAAAAAAAAAA", device_name: "Unknown" }
      ))
      assert_equal 410, failed.fetch(:statusCode)
    end
    limited = @api.call(json_event(
      "POST", "/api/mobile/pairings/exchange", { code: "AAAAAAAAAAAA", device_name: "Unknown" }
    ))
    valid_after_limit = @api.call(json_event(
      "POST", "/api/mobile/pairings/exchange", { code:, device_name: "iPhone" }
    ))

    assert_equal 429, limited.fetch(:statusCode)
    assert_equal 429, valid_after_limit.fetch(:statusCode)

    fresh = issue_pairing
    @now += 601
    expired = @api.call(json_event(
      "POST", "/api/mobile/pairings/exchange", { code: fresh.fetch("code"), device_name: "iPhone" }
    ))
    assert_equal 410, expired.fetch(:statusCode)
  end

  def test_issuing_a_new_pairing_invalidates_the_previous_code
    previous = issue_pairing.fetch("code")
    current = issue_pairing.fetch("code")

    old_response = @api.call(json_event(
      "POST", "/api/mobile/pairings/exchange", { code: previous, device_name: "Old" }
    ))
    current_response = @api.call(json_event(
      "POST", "/api/mobile/pairings/exchange", { code: current, device_name: "Current" }
    ))

    assert_equal 410, old_response.fetch(:statusCode)
    assert_equal 201, current_response.fetch(:statusCode)
  end

  def test_revoked_device_token_cannot_create_uploads
    credentials = paired_device_credentials
    revoked = @api.call(json_event(
      "DELETE", "/api/mobile/devices/#{credentials.dig("device", "id")}", {},
      cookies: [session_cookie], headers: { "x-csrf-token" => "csrf-token" },
      path_parameters: { "device_id" => credentials.dig("device", "id") }
    ))
    response = mobile_api.call(json_event(
      "POST", "/api/mobile/uploads", mobile_upload_payload,
      headers: { "authorization" => "Bearer #{credentials.fetch("token")}" }
    ))

    assert_equal 200, revoked.fetch(:statusCode)
    assert_equal 401, response.fetch(:statusCode)
  end

  def test_invalid_or_24_hours_future_captured_at_falls_back_to_ingestion_time
    token = paired_device_token
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    api = WeblogAuthoring::LambdaApi.new(
      database: @database, s3_client: s3, asset_bucket: "production-assets",
      inbox_thumbnail: FakeThumbnailer.new, clock: -> { @now }
    )
    headers = { "authorization" => "Bearer #{token}" }

    ["unknown", (@now + 86_400).iso8601].each_with_index do |captured_at, index|
      payload = mobile_upload_payload.merge(
        client_upload_id: "11111111-2222-4333-8444-55555555555#{index}",
        captured_at:, captured_at_source: "exif"
      )
      created = api.call(json_event("POST", "/api/mobile/uploads", payload, headers:))
      upload = JSON.parse(created.fetch(:body))
      s3.stub_responses(:head_object, {
        content_type: "image/jpeg", content_length: 1024, metadata: { "sha256" => "a" * 64 },
      })
      completed = api.call(json_event(
        "POST", "/api/mobile/uploads/#{upload.fetch("upload_id")}/complete", {}, headers:,
        path_parameters: { "upload_id" => upload.fetch("upload_id") }
      ))
      item = JSON.parse(completed.fetch(:body)).fetch("item")

      assert_equal 201, completed.fetch(:statusCode)
      assert_equal @now.iso8601, item.fetch("occurred_at")
      assert_equal "uploaded", item.dig("payload", "captured_at_source")
    end
  end

  private

  def session_cookie
    token = @codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf-token" },
      ttl: 600
    )
    "weblog_authoring_session=#{token}"
  end

  def paired_device_token
    paired_device_credentials.fetch("token")
  end

  def issue_pairing
    issued = @api.call(json_event(
      "POST", "/api/mobile/pairings", {},
      cookies: [session_cookie], headers: { "x-csrf-token" => "csrf-token" }
    ))
    JSON.parse(issued.fetch(:body))
  end

  def paired_device_credentials
    code = issue_pairing.fetch("code")
    exchanged = @api.call(json_event(
      "POST", "/api/mobile/pairings/exchange", { code:, device_name: "iPhone 16 Pro" }
    ))
    JSON.parse(exchanged.fetch(:body))
  end

  def mobile_api(logger: $stderr)
    s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    WeblogAuthoring::LambdaApi.new(
      database: @database, s3_client: s3, asset_bucket: "production-assets", logger:, clock: -> { @now }
    )
  end

  def mobile_upload_payload
    {
      client_upload_id: "11111111-2222-4333-8444-555555555555",
      content_type: "image/jpeg",
      size: 1024,
      sha256: "a" * 64,
      captured_at: "2026-08-27T08:30:00+09:00",
      captured_at_source: "photos",
    }
  end

  def mobile_upload_count
    database = SQLite3::Database.new(@database.path.to_s)
    database.get_first_value("SELECT COUNT(*) FROM mobile_uploads")
  ensure
    database&.close
  end

  def json_event(method, path, payload, cookies: nil, headers: nil, path_parameters: nil)
    {
      "rawPath" => path,
      "pathParameters" => path_parameters,
      "queryStringParameters" => nil,
      "cookies" => cookies,
      "headers" => { "content-type" => "application/json", **headers.to_h },
      "body" => JSON.generate(payload),
      "requestContext" => { "requestId" => "request-id", "http" => { "method" => method } },
    }
  end
end
