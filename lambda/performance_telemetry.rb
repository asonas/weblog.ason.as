# frozen_string_literal: true

require "weblog_authoring/lambda_session"
require "weblog_authoring/performance_telemetry"
require "weblog_authoring/production_secrets"
require "aws-sdk-secretsmanager"

module WeblogAuthoring
  module PerformanceTelemetryLambdaHandler
    module_function

    def call(event:, context:)
      api.call(event)
    end

    def api
      @api ||= begin
        secrets = ProductionSecrets.new(
          secret_id: ENV.fetch("OAUTH_SECRET_ID"),
          client: Aws::SecretsManager::Client.new,
        ).fetch
        PerformanceTelemetry.new(
          session_codec: LambdaSession.new(secret: secrets.fetch("session_secret")),
          allowed_github_user_id: Integer(ENV.fetch("GITHUB_ALLOWED_USER_ID"), 10),
        )
      end
    end
  end
end
