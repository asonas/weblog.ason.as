# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/dsql_database"
require "weblog_authoring/inbox_sync"

class DsqlSyncTest < Minitest::Test
  NOW = Time.iso8601("2026-08-28T12:00:00Z")

  class Result
    include Enumerable
    attr_reader :cmd_tuples

    def initialize(rows = [], cmd_tuples: 0)
      @rows = rows
      @cmd_tuples = cmd_tuples
    end

    def each(&) = @rows.each(&)
    def [](index) = @rows[index]
    def ntuples = @rows.length
  end

  class Connection
    attr_reader :items

    def initialize
      @items = {}
      @runs = {}
      @source_runs = {}
      @states = {}
    end

    def transaction = yield

    def exec(statement)
      case statement
      when /SELECT id FROM weblog_authoring\.inbox_sync_runs/
        active = @runs.values.select { |run| %w[queued running].include?(run.fetch("status")) }
        Result.new(active.sort_by { |run| run.fetch("started_at") }.first(1))
      else
        raise "unexpected SQL: #{statement}"
      end
    end

    def exec_params(statement, params)
      case statement
      when /SELECT runs\.id.*JOIN weblog_authoring\.inbox_sync_run_sources/m
        excluded_run_id = statement.include?("runs.id <>") ? params.fetch(0) : nil
        sources = excluded_run_id ? params.drop(1) : params
        active = @source_runs.filter_map do |(run_id, source), _result|
          run = @runs[run_id]
          next unless run && %w[queued running].include?(run.fetch("status"))
          next if run_id == excluded_run_id || !sources.include?(source)

          { "id" => run_id }
        end
        Result.new(active.first(1))
      when /SELECT 1.*JOIN weblog_authoring\.inbox_sync_run_sources/m
        sources = params
        active = @source_runs.any? do |(run_id, source), _result|
          run = @runs[run_id]
          run && %w[queued running].include?(run.fetch("status")) && sources.include?(source)
        end
        Result.new(active ? [{ "?column?" => "1" }] : [])
      when /DELETE FROM weblog_authoring\.inbox_sync_run_sources\s+WHERE run_id IN/m
        expired_ids = @runs.filter_map { |id, run| id if run.fetch("expires_at") <= params.fetch(0) }
        before = @source_runs.length
        @source_runs.delete_if { |(run_id, _source), _result| expired_ids.include?(run_id) }
        Result.new([], cmd_tuples: before - @source_runs.length)
      when /DELETE FROM weblog_authoring\.inbox_sync_runs WHERE expires_at/
        expired_ids = @runs.filter_map { |id, run| id if run.fetch("expires_at") <= params.fetch(0) }
        expired_ids.each do |id|
          @runs.delete(id)
          @source_runs.delete_if { |(run_id, _source), _result| run_id == id }
        end
        Result.new([], cmd_tuples: expired_ids.length)
      when /INSERT INTO weblog_authoring\.inbox_sync_runs/
        status = statement.include?("'queued'") ? "queued" : "running"
        @runs[params.fetch(0)] = {
          "id" => params.fetch(0), "trigger" => params.fetch(1), "status" => status,
          "started_at" => params.fetch(2), "completed_at" => nil, "expires_at" => params.fetch(3),
        }
        Result.new
      when /SELECT source, last_attempted_at.*FROM weblog_authoring\.inbox_source_sync_states/m
        state = @states[params.fetch(0)]
        Result.new(state ? [state] : [])
      when /SELECT 1 FROM weblog_authoring\.consumed_inbox_items/
        Result.new
      when /SELECT 1 FROM weblog_authoring\.inbox_items WHERE source/
        Result.new(@items.key?(params.take(3)) ? [{ "?column?" => "1" }] : [])
      when /INSERT INTO weblog_authoring\.inbox_items/
        key = params.take(3)
        existing = @items[key]
        @items[key] = {
          "source" => params.fetch(0), "kind" => params.fetch(1), "source_id" => params.fetch(2),
          "occurred_at" => params.fetch(3), "payload" => params.fetch(4), "id" => existing&.fetch("id", nil) || params.fetch(5),
          "ingested_at" => existing&.fetch("ingested_at", nil) || params.fetch(6),
          "expires_at" => existing&.fetch("expires_at", nil) || params.fetch(7),
          "created_at" => existing&.fetch("created_at", nil) || params.fetch(6), "updated_at" => params.fetch(6),
        }
        Result.new
      when /DELETE FROM weblog_authoring\.inbox_items WHERE source/
        source = params.fetch(0)
        retained_identities = params.drop(1).each_slice(2).to_a
        before = @items.length
        @items.delete_if do |(item_source, kind, source_id), _item|
          item_source == source && !retained_identities.include?([kind, source_id])
        end
        Result.new([], cmd_tuples: before - @items.length)
      when /INSERT INTO weblog_authoring\.inbox_sync_run_sources/
        if statement.include?("'succeeded'")
          @source_runs[[params.fetch(0), params.fetch(1)]] = {
            "source" => params.fetch(1), "status" => "succeeded", "fetched_count" => params.fetch(2),
            "created_count" => params.fetch(3), "updated_count" => params.fetch(4),
            "deleted_count" => params.fetch(5), "error" => nil, "completed_at" => params.fetch(6),
          }
        elsif statement.include?("'failed'")
          @source_runs[[params.fetch(0), params.fetch(1)]] = {
            "source" => params.fetch(1), "status" => "failed", "fetched_count" => 0,
            "created_count" => 0, "updated_count" => 0, "deleted_count" => 0,
            "error" => params.fetch(2), "completed_at" => params.fetch(3),
          }
        else
          status = statement.include?("'queued'") ? "queued" : "running"
          @source_runs[[params.fetch(0), params.fetch(1)]] = {
            "source" => params.fetch(1), "status" => status, "fetched_count" => 0,
            "created_count" => 0, "updated_count" => 0, "deleted_count" => 0,
            "error" => nil, "completed_at" => params.fetch(2),
          }
        end
        Result.new
      when /INSERT INTO weblog_authoring\.inbox_source_sync_states/
        source = params.fetch(0)
        if statement.include?("last_succeeded_at = EXCLUDED")
          @states[source] = {
            "source" => source, "last_attempted_at" => params.fetch(1), "last_succeeded_at" => params.fetch(1),
            "watermark" => params.fetch(2), "last_error" => nil, "updated_at" => params.fetch(1),
          }
        else
          previous = @states[source] || {}
          @states[source] = previous.merge(
            "source" => source, "last_attempted_at" => params.fetch(1),
            "last_error" => params.fetch(2), "updated_at" => params.fetch(1)
          )
        end
        Result.new
      when /UPDATE weblog_authoring\.inbox_sync_runs SET status/
        @runs.fetch(params.fetch(0))["status"] = params.fetch(1)
        @runs.fetch(params.fetch(0))["completed_at"] = params.fetch(2)
        Result.new
      when /SELECT id, trigger, status, started_at, completed_at.*FROM weblog_authoring\.inbox_sync_runs/m
        run = @runs[params.fetch(0)]
        Result.new(run ? [run] : [])
      when /SELECT source, status, fetched_count.*FROM weblog_authoring\.inbox_sync_run_sources/m
        rows = @source_runs.filter_map { |(run_id, _source), result| result if run_id == params.fetch(0) }
        Result.new(rows.sort_by { |result| [result.fetch("completed_at"), result.fetch("source")] })
      else
        raise "unexpected SQL: #{statement}"
      end
    end
  end

  class Pool
    attr_reader :connection

    def initialize = @connection = Connection.new
    def with = yield connection
    def shutdown; end
  end

  class Source
    attr_accessor :snapshot

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def fetch(**)
      snapshot
    end
  end

  def test_repeated_complete_snapshots_are_atomic_and_idempotent
    source = Source.new(snapshot(%w[1 2]))
    runner = WeblogAuthoring::InboxSync::Runner.new(
      database:, sources: { "raindrop" => source }, clock: -> { NOW }
    )

    first = runner.call(trigger: "scheduled", run_id: "run-1")
    repeated = runner.call(trigger: "scheduled", run_id: "run-2")
    source.snapshot = snapshot(["1"])
    final = runner.call(trigger: "scheduled", run_id: "run-3")

    assert_equal [2, 0], first.fetch("sources").first.values_at("created_count", "updated_count")
    assert_equal [0, 2], repeated.fetch("sources").first.values_at("created_count", "updated_count")
    assert_equal 1, final.fetch("sources").first.fetch("deleted_count")
    assert_equal "succeeded", database.inbox_sync_run(run_id: "run-3").fetch("status")
    assert_equal "watermark", database.inbox_source_sync_state(source: "raindrop").fetch("watermark")
  end

  private

  def database
    @database ||= WeblogAuthoring::DsqlDatabase.new(
      host: "cluster.dsql.ap-northeast-1.on.aws", content_dir: "content", pool: Pool.new, clock: -> { NOW }
    )
  end

  def snapshot(ids)
    WeblogAuthoring::InboxSync::Snapshot.new(
      items: ids.map do |id|
        WeblogAuthoring::InboxSync::Item.new(
          kind: "bookmark", source_id: id, occurred_at: NOW,
          payload: { "raindrop_id" => Integer(id), "url" => "https://example.com/#{id}", "title" => id }
        )
      end,
      complete: true,
      watermark: "watermark"
    )
  end
end
