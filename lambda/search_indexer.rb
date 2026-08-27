# frozen_string_literal: true

require "pathname"
require "aws-sdk-s3"

require "weblog_authoring/dsql_database"
require "weblog_authoring/search_indexer"

module WeblogAuthoring
  module SearchIndexerHandler
    module_function

    def call(event:, context:) # rubocop:disable Lint/UnusedMethodArgument
      result = indexer.call
      puts(JSON.generate(result.merge("event" => "search_index_completed")))
      result
    end

    def indexer
      @indexer ||= SearchIndexer.new(
        database: DsqlDatabase.new(
          host: ENV.fetch("DSQL_HOST"),
          content_dir: Pathname("/tmp/content")
        ),
        s3_client: Aws::S3::Client.new,
        bucket: ENV.fetch("SITE_BUCKET")
      )
    end
  end
end
