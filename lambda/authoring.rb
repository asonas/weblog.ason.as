# frozen_string_literal: true

require "pathname"

require "weblog_authoring/dsql_database"
require "weblog_authoring/embed_metadata"
require "weblog_authoring/github_oauth"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"
require "weblog_authoring/production_secrets"
require "aws-sdk-sqs"

module WeblogAuthoring
  module LambdaHandler
    module_function

    def call(event:, context:) # rubocop:disable Lint/UnusedMethodArgument
      api.call(event)
    end

    def api
      @api ||= begin
        secrets = ProductionSecrets.new(secret_id: ENV.fetch("OAUTH_SECRET_ID")).fetch
        LambdaApi.new(
          database: DsqlDatabase.new(
            host: ENV.fetch("DSQL_HOST"),
            content_dir: Pathname("/tmp/content")
          ),
          s3_client: Aws::S3::Client.new,
          asset_bucket: ENV.fetch("ASSET_BUCKET"),
          site_bucket: ENV.fetch("SITE_BUCKET"),
          sqs_client: Aws::SQS::Client.new,
          search_queue_url: ENV["SEARCH_INDEX_QUEUE_URL"],
          embed_fetcher: EmbedMetadataFetcher.new,
          oauth: GitHubOAuth.new(
            client_id: secrets.fetch("github_client_id"),
            client_secret: secrets.fetch("github_client_secret")
          ),
          session_codec: LambdaSession.new(secret: secrets.fetch("session_secret")),
          redirect_uri: ENV.fetch("GITHUB_REDIRECT_URI"),
          frontend_url: ENV.fetch("FRONTEND_URL"),
          allowed_github_user_id: Integer(ENV.fetch("GITHUB_ALLOWED_USER_ID"), 10)
        )
      end
    end
  end
end
