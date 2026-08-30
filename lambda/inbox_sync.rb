# frozen_string_literal: true

require "pathname"
require "securerandom"
require "json"
require "aws-sdk-lambda"
require "aws-sdk-secretsmanager"

require "weblog_authoring/bluesky_source"
require "weblog_authoring/dsql_database"
require "weblog_authoring/inbox_sync"
require "weblog_authoring/raindrop_source"

module WeblogAuthoring
  module InboxSyncLambdaHandler
    module_function

    def call(event:, context:, runner: nil) # rubocop:disable Lint/UnusedMethodArgument
      trigger, run_id = invocation(event)
      (runner || sync_runner).call(trigger:, run_id:)
    end

    def sync_runner
      @sync_runner ||= InboxSync::Runner.new(
        database: DsqlDatabase.new(
          host: ENV.fetch("DSQL_HOST"),
          content_dir: Pathname("/tmp/content")
        ),
        sources: {
          "bluesky" => bluesky_source,
          "raindrop" => raindrop_source,
          "c4p" => InboxSync::PendingSource.new,
        }
      )
    end

    def bluesky_source
      BlueskySource.new(
        client: BlueskySource::Client.new(
          lambda_client: Aws::Lambda::Client.new,
          function_name: ENV.fetch("BLUESKY_OAUTH_FUNCTION_NAME")
        )
      )
    end
    private_class_method :bluesky_source

    def raindrop_source
      response = Aws::SecretsManager::Client.new.get_secret_value(
        secret_id: ENV.fetch("INBOX_SOURCES_SECRET_ID")
      )
      token = JSON.parse(response.secret_string).fetch("raindrop_test_token")
      RaindropSource.new(client: RaindropSource::Client.new(token:))
    end
    private_class_method :raindrop_source

    def invocation(event)
      if event["source"] == "aws.events" && event["detail-type"] == "Scheduled Event"
        return ["scheduled", SecureRandom.uuid.delete("-")]
      end
      if event["type"] == "inbox_sync" && event["trigger"] == "manual" && !event["run_id"].to_s.empty?
        return ["manual", event.fetch("run_id")]
      end

      raise ArgumentError, "unsupported inbox sync event"
    end
    private_class_method :invocation
  end
end
