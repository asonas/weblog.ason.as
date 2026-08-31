# frozen_string_literal: true

require "json"
require "time"

module WeblogAuthoring
  module InboxSync
    SOURCES = %w[bluesky raindrop c4p].freeze
    Item = Data.define(:kind, :source_id, :occurred_at, :payload)
    Snapshot = Data.define(:items, :complete, :watermark)

    def self.sources(value)
      return SOURCES if value.nil?

      unless value.is_a?(Array) && value.any? && value.all? { |source| SOURCES.include?(source) }
        raise ArgumentError, "invalid inbox sync sources"
      end

      value.uniq
    end

    module ErrorClassifier
      module_function

      def call(error, phase:)
        return %w[persistence immediate] if phase == :persistence

        message = error.message
        if message.match?(/\b(?:401|403)\b|unauthori[sz]ed|not authorized|forbidden|reauthorization_required|authentication required|login required|access denied/i)
          return %w[authentication immediate]
        end
        return %w[rate_limit after_three] if message.match?(/\b429\b|rate.?limit/i)
        return %w[upstream after_three] if message.match?(/\b5\d\d\b|upstream/i)
        return %w[timeout after_three] if error.class.name.include?("Timeout") || message.match?(/timed? ?out|timeout/i)
        if error.class.name.match?(/SocketError|ECONN|EHOST|ENET/) || message.match?(/network|connection reset|name or service/i)
          return %w[network after_three]
        end

        %w[unexpected immediate]
      end
    end

    class PendingSource
      def fetch(watermark:)
        Snapshot.new(items: [], complete: false, watermark:)
      end
    end

    class Runner
      def initialize(database:, sources:, clock: Time.method(:now), logger: $stdout)
        @database = database
        @sources = sources
        @clock = clock
        @logger = logger
      end

      def call(trigger:, run_id:, requested_sources: nil)
        selected_sources = select_sources(requested_sources)
        started_at = @clock.call
        started = @database.start_inbox_sync_run(
          run_id:, trigger:, started_at:, sources: selected_sources.keys
        )
        return { "id" => run_id, "trigger" => trigger, "status" => "already_running", "sources" => [] } unless started

        log("inbox_sync_started", run_id:, trigger:, sources: selected_sources.keys)
        results = selected_sources.map { |source, adapter| run_source(run_id, source, adapter) }
        status = results.any? { |result| result.fetch("status") == "failed" } ? "completed_with_errors" : "succeeded"
        completed_at = @clock.call
        @database.finish_inbox_sync_run(run_id:, status:, completed_at:)
        log("inbox_sync_completed", run_id:, trigger:, status:)
        {
          "id" => run_id,
          "trigger" => trigger,
          "status" => status,
          "started_at" => started_at.iso8601,
          "completed_at" => completed_at.iso8601,
          "sources" => results,
        }
      end

      private

      def select_sources(requested_sources)
        return @sources if requested_sources.nil?

        selected = InboxSync.sources(requested_sources)
        unknown = selected - @sources.keys
        raise ArgumentError, "unknown inbox sources: #{unknown.join(', ')}" unless unknown.empty?

        @sources.slice(*selected)
      end

      def run_source(run_id, source, adapter)
        state = @database.inbox_source_sync_state(source:)
        snapshot = nil
        begin
          snapshot = adapter.fetch(watermark: state&.fetch("watermark"))
        rescue StandardError => error
          return failed_source(run_id, source, error, phase: :fetch)
        end
        completed_at = @clock.call
        counts = nil
        begin
          counts = @database.apply_inbox_source_snapshot(run_id:, source:, snapshot:, completed_at:)
        rescue StandardError => error
          return failed_source(run_id, source, error, phase: :persistence)
        end
        result = {
          "source" => source,
          "status" => "succeeded",
          "fetched_count" => snapshot.items.length,
          "created_count" => counts.fetch(:created_count),
          "updated_count" => counts.fetch(:updated_count),
          "deleted_count" => counts.fetch(:deleted_count),
        }
        log(
          "inbox_sync_source_result",
          run_id:,
          source:,
          status: result.fetch("status"),
          fetched_count: result.fetch("fetched_count"),
          created_count: result.fetch("created_count"),
          updated_count: result.fetch("updated_count"),
          deleted_count: result.fetch("deleted_count")
        )
        result
      end

      def failed_source(run_id, source, error, phase:)
        completed_at = @clock.call
        classification, alert_policy = ErrorClassifier.call(error, phase:)
        result = {
          "source" => source,
          "status" => "failed",
          "error" => error.message,
        }
        log("inbox_sync_source_result", run_id:, source:, status: "failed", classification:, alert_policy:)
        @database.fail_inbox_source_sync(run_id:, source:, error: error.message, completed_at:)
        result
      end

      def log(event, **fields)
        @logger.puts(JSON.generate({ "event" => event }.merge(fields.transform_keys(&:to_s))))
      end
    end
  end
end
