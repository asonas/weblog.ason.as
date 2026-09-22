# frozen_string_literal: true

require "pathname"

require "aws-sdk-sqs"
require "weblog_authoring/dsql_database"
require "weblog_authoring/webmention_receiver"
require "weblog_authoring/draft_reader"
require "weblog_authoring/draft_store"

module WeblogAuthoring
  module WebmentionReceiverHandler
    module_function

    def call(event:, context:)
      _context = context
      receiver.call(event)
    end

    def receiver
      @receiver ||= WebmentionReceiver.new(
        database: published_reader,
        sqs_client: Aws::SQS::Client.new,
        queue_url: ENV.fetch("WEBMENTION_QUEUE_URL"),
        site_url: ENV.fetch("SITE_URL"),
        enabled: ENV.fetch("WEBMENTION_RECEIVER_ENABLED", "true") == "true"
      )
    end

    def published_reader
      pool = AuroraDsql::Pg.create_pool(host: ENV.fetch("DSQL_HOST"), user: "weblog_authoring", application_name: "webmention-receiver", occ_max_retries: 3)
      database = DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content"), pool:)
      store = DraftStore.postgres(pool)
      %w[verifying open paused].include?(store.cutover_status.fetch("phase")) ? DraftReader.new(store:, database:) : database
    end
  end
end
