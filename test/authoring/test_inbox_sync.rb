# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "weblog_authoring/inbox_sync"
require "weblog_authoring/development_database"

class InboxSyncTest < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-28T12:00:00Z")

  class FixtureSource
    def initialize(name, calls:, snapshot: nil, error: nil)
      @name = name
      @calls = calls
      @snapshot = snapshot
      @error = error
    end

    def fetch(watermark:)
      @calls << [@name, watermark]
      raise @error if @error

      @snapshot
    end
  end

  class FixtureDatabase
    attr_reader :events

    def initialize
      @events = []
    end

    def start_inbox_sync_run(run_id:, trigger:, started_at:)
      events << [:run_started, run_id, trigger, started_at]
      true
    end

    def inbox_source_sync_state(source:)
      source == "bluesky" ? { "watermark" => "cursor-1" } : nil
    end

    def apply_inbox_source_snapshot(run_id:, source:, snapshot:, completed_at:)
      events << [:source_applied, run_id, source, snapshot, completed_at]
      { created_count: snapshot.items.length, updated_count: 0, deleted_count: 0 }
    end

    def fail_inbox_source_sync(run_id:, source:, error:, completed_at:)
      events << [:source_failed, run_id, source, error, completed_at]
    end

    def finish_inbox_sync_run(run_id:, status:, completed_at:)
      events << [:run_finished, run_id, status, completed_at]
    end
  end

  class BusyDatabase < FixtureDatabase
    def start_inbox_sync_run(run_id:, trigger:, started_at:)
      false
    end
  end

  class MutableSource
    attr_accessor :snapshot

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def fetch(watermark:)
      snapshot
    end
  end

  def test_runs_sources_serially_and_continues_after_one_source_fails
    calls = []
    database = FixtureDatabase.new
    item = WeblogAuthoring::InboxSync::Item.new(
      kind: "post", source_id: "at://did:example/post/1", occurred_at: FIXED_TIME,
      payload: { "record_uri" => "at://did:example/post/1" }
    )
    sources = {
      "bluesky" => FixtureSource.new(
        "bluesky", calls:,
        snapshot: WeblogAuthoring::InboxSync::Snapshot.new(items: [item], complete: true, watermark: "cursor-2")
      ),
      "raindrop" => FixtureSource.new("raindrop", calls:, error: RuntimeError.new("temporary failure")),
      "c4p" => FixtureSource.new(
        "c4p", calls:,
        snapshot: WeblogAuthoring::InboxSync::Snapshot.new(items: [], complete: true, watermark: nil)
      ),
    }
    runner = WeblogAuthoring::InboxSync::Runner.new(database:, sources:, clock: -> { FIXED_TIME })

    result = runner.call(trigger: "manual", run_id: "run-1")

    assert_equal [%w[bluesky cursor-1], ["raindrop", nil], ["c4p", nil]], calls
    assert_equal "completed_with_errors", result.fetch("status")
    assert_equal %w[succeeded failed succeeded], result.fetch("sources").map { |source| source.fetch("status") }
    assert_equal "temporary failure", result.fetch("sources").fetch(1).fetch("error")
    assert_equal [:run_finished, "run-1", "completed_with_errors", FIXED_TIME], database.events.last
  end

  def test_repeated_and_incomplete_snapshots_do_not_duplicate_or_delete_items
    database = WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("authoring.sqlite3"), content_dir: tmpdir.join("content"), clock: -> { FIXED_TIME }
    )
    database.setup!
    first = item("1")
    second = item("2")
    source = MutableSource.new(snapshot([first, second], complete: true, watermark: "watermark-1"))
    runner = WeblogAuthoring::InboxSync::Runner.new(
      database:, sources: { "raindrop" => source }, clock: -> { FIXED_TIME }
    )

    first_run = runner.call(trigger: "scheduled", run_id: "run-1")
    repeated_run = runner.call(trigger: "scheduled", run_id: "run-2")
    source.snapshot = snapshot([first], complete: false, watermark: "watermark-2")
    incomplete_run = runner.call(trigger: "scheduled", run_id: "run-3")

    assert_equal [2, 0], first_run.fetch("sources").first.values_at("created_count", "updated_count")
    assert_equal [0, 2], repeated_run.fetch("sources").first.values_at("created_count", "updated_count")
    assert_equal 0, incomplete_run.fetch("sources").first.fetch("deleted_count")
    assert_equal %w[1 2], database.list_inbox_items.map(&:source_id).sort

    source.snapshot = snapshot([first], complete: true, watermark: "watermark-3")
    final_run = runner.call(trigger: "scheduled", run_id: "run-4")

    assert_equal 1, final_run.fetch("sources").first.fetch("deleted_count")
    assert_equal ["1"], database.list_inbox_items.map(&:source_id)
    assert_equal "watermark-3", database.inbox_source_sync_state(source: "raindrop").fetch("watermark")
  end

  def test_does_not_fetch_sources_when_another_sync_is_active
    calls = []
    source = FixtureSource.new(
      "bluesky", calls:,
      snapshot: WeblogAuthoring::InboxSync::Snapshot.new(items: [], complete: false, watermark: nil)
    )
    runner = WeblogAuthoring::InboxSync::Runner.new(
      database: BusyDatabase.new, sources: { "bluesky" => source }, clock: -> { FIXED_TIME }
    )

    result = runner.call(trigger: "scheduled", run_id: "run-2")

    assert_equal "already_running", result.fetch("status")
    assert_empty calls
  end

  def test_complete_snapshot_compares_the_full_source_kind_identity
    database = WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("identity.sqlite3"), content_dir: tmpdir.join("content"), clock: -> { FIXED_TIME }
    )
    database.setup!
    post = WeblogAuthoring::InboxSync::Item.new(
      kind: "post", source_id: "same", occurred_at: FIXED_TIME, payload: { "type" => "post" }
    )
    like = WeblogAuthoring::InboxSync::Item.new(
      kind: "like", source_id: "same", occurred_at: FIXED_TIME, payload: { "type" => "like" }
    )
    source = MutableSource.new(snapshot([post, like], complete: true, watermark: nil))
    runner = WeblogAuthoring::InboxSync::Runner.new(
      database:, sources: { "bluesky" => source }, clock: -> { FIXED_TIME }
    )
    runner.call(trigger: "scheduled", run_id: "identity-1")
    source.snapshot = snapshot([post], complete: true, watermark: nil)

    runner.call(trigger: "scheduled", run_id: "identity-2")

    assert_equal ["post"], database.list_inbox_items.map(&:kind)
  end

  private

  def item(id)
    WeblogAuthoring::InboxSync::Item.new(
      kind: "bookmark", source_id: id, occurred_at: FIXED_TIME,
      payload: { "raindrop_id" => Integer(id), "url" => "https://example.com/#{id}", "title" => "Bookmark #{id}" }
    )
  end

  def snapshot(items, complete:, watermark:)
    WeblogAuthoring::InboxSync::Snapshot.new(items:, complete:, watermark:)
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("inbox-sync"))
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end
end
