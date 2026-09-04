# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "weblog_authoring/lambda_session"
require "weblog_authoring/performance_telemetry"

class PerformanceTelemetryTest < Minitest::Test
  def setup
    @codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    @token = @codec.issue(
      kind: "session",
      attributes: { "github_user_id" => 630_181, "csrf_token" => "csrf-token" },
      ttl: 600,
    )
    @log = StringIO.new
    @api = WeblogAuthoring::PerformanceTelemetry.new(
      session_codec: @codec,
      allowed_github_user_id: 630_181,
      logger: @log,
      clock: -> { Time.iso8601("2026-09-04T12:00:00Z") },
    )
  end

  def test_accepts_bounded_authenticated_otel_batch
    result = @api.call(event(payload))

    assert_equal 202, result.fetch(:statusCode)
    entry = JSON.parse(@log.string)
    assert_equal "authoring_performance_telemetry", entry.fetch("event")
    assert_equal "authoring.interaction.duration", entry.dig("payload", "metrics", 0, "name")
  end

  def test_rejects_content_attributes
    body = payload
    body.fetch("resource").fetch("attributes")["page.title"] = "secret title"

    result = @api.call(event(body))

    assert_equal 422, result.fetch(:statusCode)
    assert_empty @log.string
  end

  def test_requires_session_and_csrf
    no_session = event(payload).tap { |value| value.delete("cookies") }
    wrong_csrf = event(payload).tap { |value| value.fetch("headers")["x-csrf-token"] = "wrong" }

    assert_equal 401, @api.call(no_session).fetch(:statusCode)
    assert_equal 403, @api.call(wrong_csrf).fetch(:statusCode)
  end

  def test_rejects_oversized_payload
    oversized = event(payload)
    oversized["body"] = "x" * (WeblogAuthoring::PerformanceTelemetry::MAX_BODY_BYTES + 1)

    assert_equal 413, @api.call(oversized).fetch(:statusCode)
    assert_empty @log.string
  end

  def test_rejects_too_many_metrics
    body = payload
    body["metrics"] = Array.new(WeblogAuthoring::PerformanceTelemetry::MAX_METRICS + 1) do
      body.fetch("metrics").first
    end

    assert_equal 422, @api.call(event(body)).fetch(:statusCode)
    assert_empty @log.string
  end

  private

  def payload
    {
      "schema_version" => "1.0",
      "resource" => {
        "attributes" => {
          "service.name" => "weblog-authoring",
          "deployment.environment.name" => "production",
        },
      },
      "metrics" => [{
        "name" => "authoring.interaction.duration",
        "unit" => "ms",
        "count" => 2,
        "sum" => 24.0,
        "min" => 8.0,
        "max" => 16.0,
        "explicit_bounds" => [16, 50, 100, 200, 500],
        "bucket_counts" => [2, 0, 0, 0, 0, 0],
      }],
      "spans" => [],
    }
  end

  def event(body)
    {
      "rawPath" => "/api/authoring/telemetry",
      "requestContext" => { "http" => { "method" => "POST" } },
      "headers" => { "x-csrf-token" => "csrf-token" },
      "cookies" => ["weblog_authoring_session=#{@token}"],
      "body" => JSON.generate(body),
    }
  end
end
