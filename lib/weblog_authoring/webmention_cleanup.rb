# frozen_string_literal: true

require "json"

module WeblogAuthoring
  class WebmentionCleanup
    KINDS = %w[attempts snapshots deliveries outboxes tombstones].freeze

    def initialize(database:, dry_run:, limit: 500, logger: $stdout)
      @database = database
      @dry_run = dry_run
      @limit = limit
      @logger = logger
    end

    def call
      KINDS.map do |kind|
        result = @database.cleanup_expired_webmentions(kind:, limit: @limit, dry_run: @dry_run)
        log("webmention_cleanup", result.merge("dry_run" => @dry_run))
        result
      rescue StandardError => error
        result = { "kind" => kind, "error" => error.class.name }
        log("webmention_cleanup_failed", result)
        result
      end
    end

    private

    def log(event, fields)
      @logger.puts(JSON.generate({ "event" => event }.merge(fields)))
    end
  end
end
