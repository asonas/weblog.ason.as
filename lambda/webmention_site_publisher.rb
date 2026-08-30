# frozen_string_literal: true

require "pathname"

require "aws-sdk-cloudfront"
require "aws-sdk-s3"
require "aws-sdk-sqs"
require "weblog_authoring/dsql_database"
require "weblog_authoring/webmention_site_publisher"

module WeblogAuthoring
  module WebmentionSitePublisherHandler
    module_function

    def call(event:, context:)
      _context = context
      publisher.call(event)
    end

    def publisher
      @publisher ||= WebmentionSitePublisher.new(
        database: DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content")),
        s3_client: Aws::S3::Client.new,
        cloudfront_client: Aws::CloudFront::Client.new,
        sqs_client: Aws::SQS::Client.new,
        site_bucket: ENV.fetch("SITE_BUCKET"),
        distribution_id: ENV.fetch("CLOUDFRONT_DISTRIBUTION_ID"),
        delivery_queue_url: ENV.fetch("WEBMENTION_QUEUE_URL"),
        sender_enabled: ENV.fetch("WEBMENTION_SENDER_ENABLED", "false") == "true"
      )
    end
  end
end
