# frozen_string_literal: true

require "pathname"
require "aws-sdk-sqs"

require "weblog_authoring/dsql_database"
require "weblog_authoring/webmention_revalidator"
require "weblog_authoring/webmention_worker"

module WeblogAuthoring
  module WebmentionWorkerHandler
    module_function

    def call(event:, context:)
      _context = context
      if event["source"] == "aws.events"
        return { statusCode: 200, body: JSON.generate(revalidator.call) }
      end

      worker.call(event)
    end

    def worker
      @worker ||= WebmentionWorker.new(
        database: DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content"))
      )
    end

    def revalidator
      @revalidator ||= WebmentionRevalidator.new(
        database: DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content")),
        sqs_client: Aws::SQS::Client.new,
        queue_url: ENV.fetch("WEBMENTION_QUEUE_URL"),
        limit: Integer(ENV.fetch("WEBMENTION_REVERIFY_BATCH_SIZE", "100")),
        stale_after_days: Integer(ENV.fetch("WEBMENTION_REVERIFY_AFTER_DAYS", "7"))
      )
    end
  end
end
