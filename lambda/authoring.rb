# frozen_string_literal: true

require "pathname"
require "json"

require "weblog_authoring/dsql_database"
require "weblog_authoring/embed_metadata"
require "weblog_authoring/github_oauth"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"
require "weblog_authoring/production_secrets"
require "weblog_authoring/search_index"
require "aws-sdk-sqs"
require "aws-sdk-lambda"

module WeblogAuthoring
  module LambdaHandler
    module_function

    def call(event:, context:)
      api(request_id: context.aws_request_id, route: event.fetch("rawPath", "")).call(event)
    end

    def api(request_id: nil, route: nil)
      @api ||= begin
        timings = {} # @type var timings: Hash[String, Float]
        api_started_at = monotonic_time
        secrets_client = measure(timings, "secrets_client") { Aws::SecretsManager::Client.new }
        secrets = ProductionSecrets.new(
          secret_id: ENV.fetch("OAUTH_SECRET_ID"), client: secrets_client, timings:
        ).fetch
        s3_client = measure(timings, "s3_client") { Aws::S3::Client.new }
        database = measure(timings, "dsql_pool") do
          DsqlDatabase.new(
            host: ENV.fetch("DSQL_HOST"),
            content_dir: Pathname("/tmp/content")
          )
        end
        sqs_client = measure(timings, "sqs_client") { Aws::SQS::Client.new }
        lambda_client = measure(timings, "lambda_client") { Aws::Lambda::Client.new }
        instance = measure(timings, "object_graph") do
          LambdaApi.new(
            database:, s3_client:, asset_bucket: ENV.fetch("ASSET_BUCKET"),
            development_asset_bucket: ENV["DEVELOPMENT_ASSET_BUCKET"], site_bucket: ENV.fetch("SITE_BUCKET"),
            sqs_client:, search_queue_url: ENV["SEARCH_INDEX_QUEUE_URL"], lambda_client:,
            inbox_sync_function_name: ENV["INBOX_SYNC_FUNCTION_NAME"],
            bluesky_oauth_function_name: ENV["BLUESKY_OAUTH_FUNCTION_NAME"],
            search_index: SearchIndex.new(s3_client:, bucket: ENV.fetch("SITE_BUCKET")),
            embed_fetcher: EmbedMetadataFetcher.new,
            oauth: GitHubOAuth.new(client_id: secrets.fetch("github_client_id"),
                                   client_secret: secrets.fetch("github_client_secret")),
            session_codec: LambdaSession.new(secret: secrets.fetch("session_secret")),
            redirect_uri: ENV.fetch("GITHUB_REDIRECT_URI"), frontend_url: ENV.fetch("FRONTEND_URL"),
            allowed_github_user_id: Integer(ENV.fetch("GITHUB_ALLOWED_USER_ID"), 10)
          )
        end
        timings["api_total"] = elapsed_ms(api_started_at)
        parts = timings.reject { |name, _duration| name == "api_total" }.values.sum
        puts(JSON.generate(
          "event" => "cold_api_timing", "request_id" => request_id, "route" => route, "cold" => true,
          "timings" => timings, "unaccounted_ms" => (timings.fetch("api_total") - parts).round(1)
        ))
        instance
      end
    end

    def measure(timings, name)
      started_at = monotonic_time
      result = yield
      timings[name] = elapsed_ms(started_at)
      result
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round(1).to_f
    end
  end
end
