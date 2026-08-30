# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/dsql_database"

class DsqlInboxTest < Minitest::Test
  NOW = Time.iso8601("2026-08-26T12:00:00+09:00")

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
    attr_reader :items, :consumed

    def initialize
      @items = {}
      @consumed = {}
      @adoptions = {}
    end

    def add_adoption(item_id, expires_at:) = @adoptions[item_id] = expires_at

    def transaction = yield

    def exec_params(statement, params)
      case statement
      when /SELECT 1 FROM weblog_authoring\.consumed_inbox_items/
        key = params.take(3)
        row = @consumed[key]
        Result.new(row && row.fetch("expires_at") > params.fetch(3) ? [{ "?column?" => "1" }] : [])
      when /INSERT INTO weblog_authoring\.inbox_items/
        key = params.take(3)
        existing = @items[key]
        @items[key] = if existing
                        existing.merge("occurred_at" => params[3], "payload" => params[4], "updated_at" => params[6])
                      else
                        {
                          "source" => params[0], "kind" => params[1], "source_id" => params[2],
                          "occurred_at" => params[3], "payload" => params[4], "id" => params[5],
                          "ingested_at" => params[6], "expires_at" => params[7], "created_at" => params[6],
                          "updated_at" => params[6],
                        }
                      end
        Result.new([@items.fetch(key)])
      when /INSERT INTO weblog_authoring\.consumed_inbox_items/
        item = @items.values.find { |candidate| candidate.fetch("id") == params[0] }
        key = [item.fetch("source"), item.fetch("kind"), item.fetch("source_id")]
        unless statement.include?("DO NOTHING") && @consumed.key?(key)
          @consumed[key] = { "expires_at" => item.fetch("expires_at") }
        end
        Result.new
      when /DELETE FROM weblog_authoring\.inbox_items\s+WHERE id IN/
        expired = @items.select { |_key, item| item.fetch("expires_at") <= params[0] }.keys.take(params[1])
        expired.each { |key| @items.delete(key) }
        Result.new([], cmd_tuples: expired.length)
      when /DELETE FROM weblog_authoring\.consumed_inbox_items\s+WHERE \(source, kind, source_id\) IN/
        expired = @consumed.select { |_key, item| item.fetch("expires_at") <= params[0] }.keys.take(params[1])
        expired.each { |key| @consumed.delete(key) }
        Result.new([], cmd_tuples: expired.length)
      when /DELETE FROM weblog_authoring\.inbox_items WHERE id/
        before = @items.length
        @items.delete_if { |_key, item| item.fetch("id") == params[0] }
        Result.new([], cmd_tuples: before - @items.length)
      when /UPDATE weblog_authoring\.inbox_image_adoptions SET committed_at/
        Result.new
      when /SELECT 1 FROM weblog_authoring\.inbox_image_adoptions/
        expires_at = @adoptions[params.fetch(0)]
        Result.new(expires_at && expires_at > params.fetch(1) ? [{ "?column?" => "1" }] : [])
      when /DELETE FROM weblog_authoring\.inbox_image_adoptions/
        Result.new
      when /DELETE FROM weblog_authoring\.inbox_item_usages/
        Result.new
      when /FROM weblog_authoring\.inbox_items\s+WHERE expires_at/
        rows = @items.values.select { |item| item.fetch("expires_at") > params[0] }
        Result.new(rows.sort_by { |item| [item.fetch("occurred_at"), item.fetch("ingested_at"), item.fetch("id")] }.reverse)
      when /FROM weblog_authoring\.inbox_items\s+WHERE id/
        Result.new(@items.values.select { |item| item.fetch("id") == params[0] })
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

  def test_upsert_updates_payload_without_extending_retention
    database = database_at(NOW)
    first = database.upsert_inbox_item(source: "raindrop", kind: "bookmark", source_id: "42", occurred_at: NOW - 3600, payload: { "url" => "https://example.com", "title" => "First", "raindrop_id" => 42 })
    updated = database_at(NOW + 86_400).upsert_inbox_item(source: "raindrop", kind: "bookmark", source_id: "42", occurred_at: NOW, payload: { "url" => "https://example.com", "title" => "Updated", "raindrop_id" => 42 })

    assert_equal first.id, updated.id
    assert_equal NOW, updated.occurred_at
    assert_equal "Updated", updated.payload.fetch("title")
    assert_equal first.ingested_at, updated.ingested_at
    assert_equal first.expires_at, updated.expires_at
    assert_equal 1, @pool.connection.items.length
  end

  def test_consumed_item_is_suppressed_until_original_expiry
    database = database_at(NOW)
    item = database.upsert_inbox_item(source: "c4p", kind: "track", source_id: "episode-1", occurred_at: NOW, payload: { "guid" => "episode-1", "permalink" => "https://c4p.ason.as/1", "title" => "Episode", "audio_url" => "https://cdn.example/1.mp3", "duration_seconds" => 60 })

    assert database.consume_inbox_item(item.id)
    assert_nil database.upsert_inbox_item(source: "c4p", kind: "track", source_id: "episode-1", occurred_at: NOW, payload: item.payload)
    assert_empty database.list_inbox_items
  end

  def test_expired_items_are_hidden_and_cleaned_in_batches
    old_database = database_at(NOW - (8 * 86_400))
    old_database.upsert_inbox_item(source: "photo", kind: "photo", source_id: "old", occurred_at: NOW - (8 * 86_400), payload: { "inbox_key" => "assets/inbox/old.jpg", "preview_url" => "/assets/inbox/old.jpg", "captured_at_source" => "exif" })
    current_database = database_at(NOW)

    assert_empty current_database.list_inbox_items
    assert_equal({ inbox_items: 1, consumed_items: 0 }, current_database.cleanup_inbox_items(limit: 10))
    assert_empty @pool.connection.items
  end

  def test_upsert_rejects_unknown_types_and_incomplete_payloads
    database = database_at(NOW)

    assert_raises(ArgumentError) do
      database.upsert_inbox_item(source: "bluesky", kind: "bookmark", source_id: "bad", occurred_at: NOW, payload: {})
    end
    assert_raises(ArgumentError) do
      database.upsert_inbox_item(source: "photo", kind: "photo", source_id: "photo-1", occurred_at: NOW, payload: { "inbox_key" => "assets/inbox/photo.jpg" })
    end
    assert_raises(ArgumentError) do
      database.upsert_inbox_item(source: "c4p", kind: "track", source_id: "episode", occurred_at: NOW, payload: { "guid" => "episode", "permalink" => "https://c4p.ason.as/episode", "title" => "Episode", "audio_url" => "https://cdn.example/episode.mp3", "duration_seconds" => "unknown" })
    end
  end

  def test_consuming_reingested_item_replaces_expired_suppression
    old_database = database_at(NOW - (8 * 86_400))
    old = old_database.upsert_inbox_item(source: "photo", kind: "photo", source_id: "photo-1", occurred_at: NOW - (8 * 86_400), payload: photo_payload)
    @pool.connection.add_adoption(old.id, expires_at: old.expires_at)
    old_database.consume_inbox_item(old.id)

    current_database = database_at(NOW)
    current = current_database.upsert_inbox_item(source: "photo", kind: "photo", source_id: "photo-1", occurred_at: NOW, payload: photo_payload)
    @pool.connection.add_adoption(current.id, expires_at: current.expires_at)
    current_database.consume_inbox_item(current.id)

    assert_nil current_database.upsert_inbox_item(source: "photo", kind: "photo", source_id: "photo-1", occurred_at: NOW, payload: photo_payload)
  end

  private

  def database_at(time)
    @pool ||= Pool.new
    WeblogAuthoring::DsqlDatabase.new(host: "cluster.dsql.ap-northeast-1.on.aws", content_dir: "content", clock: -> { time }, pool: @pool)
  end

  def photo_payload
    { "inbox_key" => "assets/inbox/photo.jpg", "preview_url" => "/assets/inbox/photo.jpg", "captured_at_source" => "exif" }
  end
end
