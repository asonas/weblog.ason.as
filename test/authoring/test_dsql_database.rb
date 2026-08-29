# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/dsql_database"

class DsqlDatabaseTest < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-22T12:00:00+09:00")

  class Result
    include Enumerable

    def initialize(rows = [])
      @rows = rows
    end

    def each(&)
      @rows.each(&)
    end

    def [](index)
      @rows[index]
    end

    def ntuples
      @rows.length
    end
  end

  class Connection
    attr_reader :links, :items, :consumed, :committed_adoptions, :usages

    def initialize
      @pages = {}
      @links = []
      @items = {}
      @consumed = []
      @committed_adoptions = []
      @usages = []
      @adoptions = {}
      @line_metadata = {}
    end

    def transaction
      snapshot = Marshal.load(Marshal.dump([@pages, @links, @items, @consumed, @committed_adoptions, @usages, @line_metadata]))
      yield
    rescue StandardError
      @pages, @links, @items, @consumed, @committed_adoptions, @usages, @line_metadata = snapshot
      raise
    end

    def add_inbox_item(row) = @items[row.fetch("id")] = row
    def add_adoption(item_id, expires_at:) = @adoptions[item_id] = expires_at

    def exec(statement)
      return Result.new([{ "?column?" => "1" }]) if statement.strip == "SELECT 1"
      return Result.new(sorted_pages) if statement.include?("ORDER BY updated_at DESC")

      raise "unexpected SQL: #{statement}"
    end

    def exec_params(statement, params)
      case statement
      when /FROM weblog_authoring\.scrapbox_line_metadata metadata/
        page = @pages[params.fetch(0)]
        rows = @line_metadata.fetch(params.fetch(0), [])
        Result.new(page && rows.first&.fetch("body_hash", nil) == page.fetch("body_hash") ? rows : [])
      when /DELETE FROM weblog_authoring\.scrapbox_line_metadata/
        @line_metadata.delete(params.fetch(0))
        Result.new
      when /INSERT INTO weblog_authoring\.scrapbox_line_metadata/
        @line_metadata[params.fetch(0)] ||= []
        @line_metadata.fetch(params.fetch(0)) << {
          "body_hash" => params.fetch(1), "line_index" => params.fetch(2),
          "created_at" => params.fetch(3), "updated_at" => params.fetch(4), "user_id" => params.fetch(5),
        }
        Result.new
      when /\A\s*SELECT.*FROM weblog_authoring\.inbox_items\s+WHERE id/m
        item = @items[params.fetch(0)]
        Result.new(item && item.fetch("expires_at") > params.fetch(1) ? [item] : [])
      when /INSERT INTO weblog_authoring\.consumed_inbox_items/
        @consumed << params.fetch(0)
        Result.new
      when /INSERT INTO weblog_authoring\.inbox_item_usages/
        @usages << params.first(2)
        Result.new
      when /FROM weblog_authoring\.inbox_item_usages usage/
        Result.new(@usages.map do |item_id, page_id|
          page = @pages.fetch(page_id)
          { "item_id" => item_id, "page_id" => page_id, "page_route" => page.fetch("name"), "used_at" => FIXED_TIME }
        end)
      when /SELECT 1 FROM weblog_authoring\.inbox_image_adoptions/
        expires_at = @adoptions[params.fetch(0)]
        Result.new(expires_at && expires_at > params.fetch(1) ? [{ "?column?" => "1" }] : [])
      when /UPDATE weblog_authoring\.inbox_image_adoptions SET committed_at/
        @committed_adoptions << params.fetch(0)
        Result.new
      when /DELETE FROM weblog_authoring\.inbox_items WHERE id/
        @items.delete(params.fetch(0))
        Result.new
      when /WHERE id = \$1/
        Result.new([@pages[params.fetch(0)]].compact)
      when /WHERE \(page_type = 'date'/
        Result.new(@pages.values.select { |page| page.fetch("name") == params.fetch(0) })
      when /SELECT id FROM weblog_authoring\.pages WHERE page_type/
        Result.new(@pages.values.filter_map do |page|
          { "id" => page.fetch("id") } if page.fetch("name") == params.fetch(1, params.fetch(0))
        end)
      when /INSERT INTO weblog_authoring\.pages/
        store_page(params)
        Result.new
      when /UPDATE weblog_authoring\.pages/
        update_page(params)
        Result.new
      when /DELETE FROM weblog_authoring\.links/
        @links.reject! { |link| link.fetch(:source_id) == params.fetch(0) }
        Result.new
      when /INSERT INTO weblog_authoring\.links/
        @links << { source_id: params.fetch(0), target_name: params.fetch(2) }
        Result.new
      else
        raise "unexpected SQL: #{statement}"
      end
    end

    private

    def sorted_pages
      @pages.values.sort_by { |page| page.fetch("updated_at") }.reverse
    end

    def store_page(values)
      keys = %w[
        id page_type name page_date title status created_at updated_at published_at
        path body_hash is_empty body
      ]
      stored_values = values.each_with_index.map do |value, index|
        index.between?(6, 8) && value.is_a?(Time) ? value.strftime("%Y-%m-%d %H:%M:%S%:z").sub(/:00\z/, "") : value
      end
      @pages[values.fetch(0)] = keys.zip(stored_values).to_h
    end

    def update_page(values)
      page = @pages.fetch(values.fetch(6))
      page.merge!(
        "status" => values.fetch(0),
        "updated_at" => values.fetch(1),
        "published_at" => values.fetch(2),
        "body_hash" => values.fetch(3),
        "is_empty" => values.fetch(4),
        "body" => values.fetch(5)
      )
    end
  end

  class Pool
    attr_reader :connection

    def initialize
      @connection = Connection.new
    end

    def with
      yield @connection
    end

    def shutdown; end
  end

  def test_saves_reads_and_lists_page_documents
    database = dsql_database
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "date",
      title: "DSQLの記事",
      body: "本文 [[リンク先]]"
    ))

    assert_equal page, database.find(page.id)
    assert_equal page, database.find_route("/DSQLの記事")
    assert_equal [page], database.list_pages
    assert_equal ["リンク先"], page.links.map(&:name)
    assert_equal [{ source_id: page.id, target_name: "リンク先" }], @pool.connection.links
  end

  def test_checks_database_health
    assert dsql_database.healthy?
  end

  def test_updates_existing_page_with_optimistic_timestamp
    database = dsql_database
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "DSQLの記事", body: "最初"
    ))
    updated = database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id,
      page_type: page.page_type,
      name: page.name,
      body: "更新",
      expected_updated_at: page.updated_at
    ))

    assert_equal "更新", updated.body
    assert_equal updated, database.find(page.id)
  end

  def test_tracks_line_update_times_across_page_saves
    later = FIXED_TIME + 3600
    times = [FIXED_TIME, later]
    database = dsql_database(clock: -> { times.shift || later })
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "行履歴", body: "維持\n変更前"
    ))
    updated = database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: page.page_type, name: page.name,
      body: "維持\n変更後", expected_updated_at: page.updated_at
    ))

    assert_equal [FIXED_TIME, later],
                 database.scrapbox_line_metadata(updated.id).map { |line| line.fetch(:updated_at) }
  end

  def test_page_save_records_inbox_usage_without_removing_the_item
    database = dsql_database
    @pool.connection.add_inbox_item(inbox_row("item-1", expires_at: FIXED_TIME + 3600))
    @pool.connection.add_adoption("item-1", expires_at: FIXED_TIME + 3600)

    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "インボックス採用", body: "本文", consumed_inbox_item_ids: ["item-1"]
    ))

    assert_equal "インボックス採用", page.name
    assert_equal ["item-1"], @pool.connection.items.keys
    assert_empty @pool.connection.consumed
    assert_equal [["item-1", page.id]], @pool.connection.usages
    assert_equal ["item-1"], @pool.connection.committed_adoptions
    assert_equal [["item-1", page.id, "インボックス採用"]],
                 database.list_inbox_item_usages.map { |usage| [usage.item_id, usage.page_id, usage.page_route] }
  end

  def test_expired_inbox_item_rejects_page_save
    database = dsql_database
    @pool.connection.add_inbox_item(inbox_row("expired", expires_at: FIXED_TIME - 1))

    error = assert_raises(WeblogAuthoring::ConflictError) do
      database.save(WeblogAuthoring::SaveRequest.new(
        page_type: "named", name: "保存されない記事", body: "本文", consumed_inbox_item_ids: ["expired"]
      ))
    end

    assert_equal "inbox_item_expired", error.message
    assert_nil database.find_route("保存されない記事")
  end

  def test_photo_without_pending_adoption_rejects_page_save
    database = dsql_database
    @pool.connection.add_inbox_item(inbox_row("unprepared", expires_at: FIXED_TIME + 3600))

    error = assert_raises(WeblogAuthoring::ConflictError) do
      database.save(WeblogAuthoring::SaveRequest.new(
        page_type: "named", name: "採用されない記事", body: "本文", consumed_inbox_item_ids: ["unprepared"]
      ))
    end

    assert_equal "inbox_item_expired", error.message
    assert_nil database.find_route("採用されない記事")
  end

  private

  def dsql_database(clock: -> { FIXED_TIME })
    @pool = Pool.new
    WeblogAuthoring::DsqlDatabase.new(
      host: "cluster.dsql.ap-northeast-1.on.aws",
      content_dir: Pathname("content"),
      clock:,
      pool: @pool
    )
  end

  def inbox_row(id, expires_at:)
    {
      "id" => id, "source" => "photo", "kind" => "photo", "source_id" => id,
      "occurred_at" => FIXED_TIME, "ingested_at" => FIXED_TIME, "expires_at" => expires_at,
      "payload" => {}, "created_at" => FIXED_TIME, "updated_at" => FIXED_TIME
    }
  end
end
