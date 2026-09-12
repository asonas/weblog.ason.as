# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lambda/authoring"
require "open3"

class AuthoringLambdaTest < Minitest::Test
  SecretResponse = Data.define(:parameter)
  Parameter = Data.define(:value)

  def test_fresh_process_logs_require_timings_once_without_changing_session_responses
    source = <<~'RUBY'
      require_relative "lambda/authoring"
      Aws.config[:stub_responses] = true
      Aws.config[:ssm] = { stub_responses: {
        get_parameter: { parameter: { value: JSON.generate(
          "github_client_id" => "id", "github_client_secret" => "secret", "session_secret" => "s" * 64
        ) } }
      } }
      {
        "AWS_REGION" => "ap-northeast-1", "OAUTH_SECRET_ID" => "oauth", "DSQL_HOST" => "cluster",
        "AWS_ACCESS_KEY_ID" => "key", "AWS_SECRET_ACCESS_KEY" => "secret", "AWS_SESSION_TOKEN" => "token",
        "ASSET_BUCKET" => "assets", "SITE_BUCKET" => "site",
        "GITHUB_REDIRECT_URI" => "https://example.com/callback",
        "FRONTEND_URL" => "https://example.com", "GITHUB_ALLOWED_USER_ID" => "1"
      }.each { |key, value| ENV[key] = value }
      2.times do |index|
        response = WeblogAuthoring::LambdaHandler.call(
          event: { "rawPath" => "/api/auth/session", "requestContext" => {
            "requestId" => "gateway-#{index}", "http" => { "method" => "GET" }
          } },
          context: Struct.new(:aws_request_id).new("lambda-#{index}")
        )
        puts JSON.generate("response" => response)
      end
    RUBY
    output, stderr, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "-e", source, chdir: File.expand_path("../..", __dir__)
    )
    assert status.success?, stderr
    entries = output.lines.map { |line| JSON.parse(line) }
    require_entries = entries.select { |entry| entry["event"] == "cold_require_timing" }
    assert_equal 1, require_entries.length
    entry = require_entries.fetch(0)
    assert_equal "lambda-0", entry.fetch("request_id")
    assert_equal "gateway-0", entry.fetch("gateway_request_id")
    assert_equal "/api/auth/session", entry.fetch("route")
    assert_operator entry.fetch("require_total_ms"), :>, 0
    assert_operator entry.fetch("timings").fetch("weblog_authoring/dsql_database"), :>, 0
    assert(entry.fetch("timings").values.all? { |value| value.is_a?(Numeric) && value >= 0 })
    assert_operator entry.fetch("require_total_ms") + 0.01, :>=, entry.fetch("timings").values.sum
    assert_equal(1, entries.count { |item| item["event"] == "cold_api_timing" })
    responses = entries.filter_map { |item| item["response"] }
    assert_equal 2, responses.length
    assert_equal responses.first, responses.last
    assert_equal 200, responses.first.fetch("statusCode")
    assert_equal "no-store", responses.first.fetch("headers").fetch("cache-control")
  end

  def test_routes_thumbnail_backfill_events_outside_the_http_api
    api = Object.new
    api.define_singleton_method(:backfill_inbox_thumbnails) do |limit:|
      { "status" => "completed", "converted" => limit, "remaining" => 0 }
    end
    WeblogAuthoring::LambdaHandler.instance_variable_set(:@api, api)
    context = Data.define(:aws_request_id).new("request-id")

    result = WeblogAuthoring::LambdaHandler.call(
      event: { "action" => "backfill_inbox_thumbnails", "limit" => 2 }, context:
    )

    assert_equal({ "status" => "completed", "converted" => 2, "remaining" => 0 }, result)
  ensure
    WeblogAuthoring::LambdaHandler.remove_instance_variable(:@api) if WeblogAuthoring::LambdaHandler.instance_variable_defined?(:@api)
  end

  def test_logs_cold_api_construction_timings
    secret_client = Object.new
    secret_client.define_singleton_method(:get_parameter) do |name:, with_decryption:|
      raise "unexpected secret" unless name == "/oauth" && with_decryption

      SecretResponse.new(Parameter.new(JSON.generate(
        "github_client_id" => "id", "github_client_secret" => "secret", "session_secret" => "s" * 64
      )))
    end
    pool = Object.new
    client = Object.new
    s3_client_constructions = 0
    lambda_client_constructions = 0
    variables = {
      "OAUTH_SECRET_ID" => "oauth", "DSQL_HOST" => "cluster", "ASSET_BUCKET" => "assets",
      "SITE_BUCKET" => "site", "GITHUB_REDIRECT_URI" => "https://example.com/callback",
      "FRONTEND_URL" => "https://example.com", "GITHUB_ALLOWED_USER_ID" => "1",
      "AWS_REGION" => "ap-northeast-1", "AWS_ACCESS_KEY_ID" => "key",
      "AWS_SECRET_ACCESS_KEY" => "secret", "AWS_SESSION_TOKEN" => "token",
    }
    previous = variables.to_h { |name, _value| [name, ENV[name]] }
    variables.each { |name, value| ENV[name] = value }
    WeblogAuthoring::LambdaHandler.remove_instance_variable(:@api) if WeblogAuthoring::LambdaHandler.instance_variable_defined?(:@api)

    output, _stderr = capture_io do
      with_new_returning(Aws::SSM::Client, secret_client) do
        with_new_returning(Aws::S3::Client, -> { s3_client_constructions += 1; client }) do
          with_new_returning(Aws::SQS::Client, client) do
            with_new_returning(Aws::Lambda::Client, -> { lambda_client_constructions += 1; client }) do
              with_method_returning(AuroraDsql::Pg, :create_pool, pool) do
                WeblogAuthoring::LambdaHandler.api(request_id: "request-id", route: "/api/tags")
              end
            end
          end
        end
      end
    end

    entries = output.lines.map { |line| JSON.parse(line) }
    diagnostic = entries.find { |item| item["event"] == "ssm_client_init_diagnostic" }
    assert_equal "[DEBUG-ssm-init-7f31]", diagnostic.fetch("debug")
    assert_equal "explicit_config", diagnostic.fetch("mode")
    assert_equal "request-id", diagnostic.fetch("request_id")
    assert_kind_of Numeric, diagnostic.fetch("wall_ms")
    assert_kind_of Numeric, diagnostic.fetch("cpu_ms")
    assert_kind_of Numeric, diagnostic.fetch("gc_ms")
    assert_kind_of Integer, diagnostic.fetch("allocated_objects")
    assert_equal %w[access_key region secret_key session_token], diagnostic.fetch("environment").keys.sort

    entry = entries.find { |item| item["event"] == "cold_api_timing" }
    assert_equal "cold_api_timing", entry.fetch("event")
    assert_equal "request-id", entry.fetch("request_id")
    assert_equal "/api/tags", entry.fetch("route")
    assert_equal true, entry.fetch("cold")
    %w[api_total secrets_client secret_get secret_decode s3_client dsql_pool sqs_client lambda_client object_graph].each do |name|
      assert_kind_of Numeric, entry.fetch("timings").fetch(name)
    end
    assert_equal 0.0, entry.fetch("timings").fetch("s3_client")
    assert_equal 0.0, entry.fetch("timings").fetch("lambda_client")
    assert_equal 0, s3_client_constructions
    assert_equal 0, lambda_client_constructions
    assert_kind_of Numeric, entry.fetch("unaccounted_ms")
  ensure
    WeblogAuthoring::LambdaHandler.remove_instance_variable(:@api) if WeblogAuthoring::LambdaHandler.instance_variable_defined?(:@api)
    previous&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  private

  def with_new_returning(target, value)
    replacement = value.respond_to?(:call) ? value : -> { value }
    with_method_returning(target, :new, replacement) { yield }
  end

  def with_method_returning(target, method_name, value)
    original = target.method(method_name)
    target.define_singleton_method(method_name) { |**| value.respond_to?(:call) ? value.call : value }
    yield
  ensure
    target.define_singleton_method(method_name, original)
  end
end
