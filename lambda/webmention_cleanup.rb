# frozen_string_literal: true

require "weblog_authoring/dsql_database"
require "weblog_authoring/webmention_cleanup"
require "pathname"

module WeblogAuthoring
  module WebmentionCleanupHandler
    module_function

    def call(event:, context:)
      _event = event
      _context = context
      results = cleanup.call
      { statusCode: 200, body: JSON.generate("results" => results) }
    end

    def cleanup
      @cleanup ||= WebmentionCleanup.new(
        database: DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content")),
        dry_run: ENV.fetch("WEBMENTION_CLEANUP_DRY_RUN", "true") == "true",
        limit: Integer(ENV.fetch("WEBMENTION_CLEANUP_BATCH_SIZE", "500"))
      )
    end
  end
end
