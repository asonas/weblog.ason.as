# frozen_string_literal: true

require "pathname"

require "aws-sdk-s3"
require "aws-sdk-sqs"
require "weblog_authoring/dsql_database"
require "weblog_authoring/webmention_site_publisher"

module WeblogAuthoring
  module WebmentionSitePublisherHandler
    module_function

    def call(event:, context:)
      _context = context
      if ENV.fetch("DRAFT_CUTOVER_ENABLED", "false") == "true"
        require "weblog_authoring/draft_runtime"
        (@draft_runtime ||= DraftRuntime.for_environment).legacy_work { publisher.call(event) }
      else
        publisher.call(event)
      end
    end

    def publisher
      @publisher ||= WebmentionSitePublisher.new(
        database: DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content")),
        s3_client: Aws::S3::Client.new,
        sqs_client: Aws::SQS::Client.new,
        site_bucket: ENV.fetch("SITE_BUCKET"),
        delivery_queue_url: ENV.fetch("WEBMENTION_QUEUE_URL"),
        sender_enabled: ENV.fetch("DRAFT_CUTOVER_ENABLED", "false") != "true" && ENV.fetch("WEBMENTION_SENDER_ENABLED", "false") == "true"
      )
    end
  end
end
