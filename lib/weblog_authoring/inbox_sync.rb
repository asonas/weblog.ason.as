# frozen_string_literal: true

require "time"

module WeblogAuthoring
  module InboxSync
    Item = Data.define(:kind, :source_id, :occurred_at, :payload)
    Snapshot = Data.define(:items, :complete, :watermark)

    class PendingSource
      def fetch(watermark:)
        Snapshot.new(items: [], complete: false, watermark:)
      end
    end

    class Runner
      def initialize(database:, sources:, clock: Time.method(:now))
        @database = database
        @sources = sources
        @clock = clock
      end

      def call(trigger:, run_id:)
        started_at = @clock.call
        started = @database.start_inbox_sync_run(run_id:, trigger:, started_at:)
        return { "id" => run_id, "trigger" => trigger, "status" => "already_running", "sources" => [] } unless started

        results = @sources.map { |source, adapter| run_source(run_id, source, adapter) }
        status = results.any? { |result| result.fetch("status") == "failed" } ? "completed_with_errors" : "succeeded"
        completed_at = @clock.call
        @database.finish_inbox_sync_run(run_id:, status:, completed_at:)
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

      def run_source(run_id, source, adapter)
        state = @database.inbox_source_sync_state(source:)
        snapshot = adapter.fetch(watermark: state&.fetch("watermark"))
        completed_at = @clock.call
        counts = @database.apply_inbox_source_snapshot(run_id:, source:, snapshot:, completed_at:)
        {
          "source" => source,
          "status" => "succeeded",
          "fetched_count" => snapshot.items.length,
          "created_count" => counts.fetch(:created_count),
          "updated_count" => counts.fetch(:updated_count),
          "deleted_count" => counts.fetch(:deleted_count),
        }
      rescue StandardError => error
        completed_at = @clock.call
        @database.fail_inbox_source_sync(run_id:, source:, error: error.message, completed_at:)
        {
          "source" => source,
          "status" => "failed",
          "error" => error.message,
        }
      end
    end
  end
end
