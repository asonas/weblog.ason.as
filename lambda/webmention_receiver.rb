# frozen_string_literal: true

require "pathname"

require "aws-sdk-sqs"
require "weblog_authoring/dsql_database"
require "weblog_authoring/webmention_receiver"

module WeblogAuthoring
  module WebmentionReceiverHandler
    module_function

    def call(event:, context:)
      _context = context
      receiver.call(event)
    end

    def receiver
      @receiver ||= WebmentionReceiver.new(
        database: DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content")),
        sqs_client: Aws::SQS::Client.new,
        queue_url: ENV.fetch("WEBMENTION_QUEUE_URL"),
        site_url: ENV.fetch("SITE_URL"),
        enabled: ENV.fetch("WEBMENTION_RECEIVER_ENABLED", "true") == "true"
      )
    end
  end
end
