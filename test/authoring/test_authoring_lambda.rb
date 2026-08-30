# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lambda/authoring"

class AuthoringLambdaTest < Minitest::Test
  SecretResponse = Data.define(:secret_string)

  def test_logs_cold_api_construction_timings
    secret_client = Object.new
    secret_client.define_singleton_method(:get_secret_value) do |secret_id:|
      raise "unexpected secret" unless secret_id == "oauth"

      SecretResponse.new(JSON.generate(
        "github_client_id" => "id", "github_client_secret" => "secret", "session_secret" => "s" * 64
      ))
    end
    pool = Object.new
    client = Object.new
    s3_client_constructions = 0
    lambda_client_constructions = 0
    variables = {
      "OAUTH_SECRET_ID" => "oauth", "DSQL_HOST" => "cluster", "ASSET_BUCKET" => "assets",
      "SITE_BUCKET" => "site", "GITHUB_REDIRECT_URI" => "https://example.com/callback",
      "FRONTEND_URL" => "https://example.com", "GITHUB_ALLOWED_USER_ID" => "1",
    }
    previous = variables.to_h { |name, _value| [name, ENV[name]] }
    variables.each { |name, value| ENV[name] = value }
    WeblogAuthoring::LambdaHandler.remove_instance_variable(:@api) if WeblogAuthoring::LambdaHandler.instance_variable_defined?(:@api)

    output, _stderr = capture_io do
      with_new_returning(Aws::SecretsManager::Client, secret_client) do
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

    entry = JSON.parse(output)
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
