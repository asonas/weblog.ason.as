# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/dsql_database"

class DsqlDatabaseTest < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-22T12:00:00+09:00")

  class Result
    include Enumerable

    attr_reader :cmd_tuples

    def initialize(rows = [], cmd_tuples: 0)
      @rows = rows
      @cmd_tuples = cmd_tuples
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
    attr_reader :links, :items, :consumed, :committed_adoptions, :usages,
                :webmention_outboxes, :webmention_targets, :webmention_publications

    def initialize
      @pages = {}
      @links = []
      @items = {}
      @consumed = []
      @committed_adoptions = []
      @usages = []
      @adoptions = {}
      @line_metadata = {}
      @webmention_outboxes = []
      @webmention_targets = {}
      @webmention_publications = {}
    end

    def transaction
      snapshot = Marshal.load(Marshal.dump(
        [
          @pages, @links, @items, @consumed, @committed_adoptions, @usages,
          @line_metadata, @webmention_outboxes, @webmention_targets, @webmention_publications,
        ]
      ))
      yield
    rescue StandardError
      @pages, @links, @items, @consumed, @committed_adoptions, @usages,
        @line_metadata, @webmention_outboxes, @webmention_targets, @webmention_publications = snapshot
      raise
    end

    def add_inbox_item(row) = @items[row.fetch("id")] = row
    def add_adoption(item_id, expires_at:) = @adoptions[item_id] = expires_at
    def clear_line_metadata(page_id) = @line_metadata.delete(page_id)

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
      when /UPDATE weblog_authoring\.inbox_items\s+SET payload = jsonb_set/m
        item = @items[params.fetch(0)]
        return Result.new unless item && item.fetch("payload").fetch("inbox_key") == params.fetch(1)

        item["payload"] = item.fetch("payload").merge("preview_url" => params.fetch(2))
        item["updated_at"] = params.fetch(3)
        Result.new(cmd_tuples: 1)
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
      when /SELECT target_url FROM weblog_authoring\.webmention_page_targets/
        Result.new(@webmention_targets.values.filter_map do |target|
          { "target_url" => target.fetch("target_url") } if target.fetch("page_id") == params.fetch(0) && target.fetch("active")
        end)
      when /SELECT source_url FROM weblog_authoring\.webmention_page_publications/
        source_url = @webmention_publications[params.fetch(0)]
        Result.new(source_url ? [{ "source_url" => source_url }] : [])
      when /INSERT INTO weblog_authoring\.webmention_page_publications/
        @webmention_publications[params.fetch(0)] = params.fetch(1)
        Result.new
      when /INSERT INTO weblog_authoring\.webmention_outbox/
        @webmention_outboxes.reject! { |outbox| outbox.fetch("id") == params.fetch(0) }
        @webmention_outboxes << {
          "id" => params.fetch(0), "page_id" => params.fetch(2), "payload" => JSON.parse(params.fetch(3)),
        }
        Result.new
      when /UPDATE weblog_authoring\.webmention_page_targets SET active = FALSE/
        @webmention_targets.each_value { |target| target["active"] = false if target["page_id"] == params.fetch(0) }
        Result.new
      when /INSERT INTO weblog_authoring\.webmention_page_targets/
        @webmention_targets[[params.fetch(0), params.fetch(1)]] = {
          "page_id" => params.fetch(0), "target_url" => params.fetch(1), "active" => params.fetch(3),
        }
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
        path body_hash is_empty body cover_mode cover_image_url
      ]
      stored_values = values.each_with_index.map do |value, index|
        index.between?(6, 8) && value.is_a?(Time) ? value.strftime("%Y-%m-%d %H:%M:%S%:z").sub(/:00\z/, "") : value
      end
      @pages[values.fetch(0)] = keys.zip(stored_values).to_h
    end

    def update_page(values)
      page = @pages.fetch(values.fetch(8))
      page.merge!(
        "status" => values.fetch(0),
        "updated_at" => values.fetch(1),
        "published_at" => values.fetch(2),
        "body_hash" => values.fetch(3),
        "is_empty" => values.fetch(4),
        "body" => values.fetch(5),
        "cover_mode" => values.fetch(6),
        "cover_image_url" => values.fetch(7)
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
    assert_equal page.id, @pool.connection.webmention_outboxes.fetch(0).fetch("page_id")
    assert_empty @pool.connection.webmention_targets
  end

  def test_list_pages_reports_non_overlapping_database_timings
    samples = (0..7).map(&:to_f)
    database = dsql_database(monotonic_clock: -> { samples.shift })
    database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "計測", body: "本文 [[リンク先]]"
    ))
    timings = {}

    database.list_pages(timings:)

    assert_equal(
      {
        "db_checkout" => 1000.0,
        "dsql_exec" => 1000.0,
        "row_build" => 2000.0,
        "wiki_parse" => 1000.0,
      },
      timings
    )
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

    assert_equal([FIXED_TIME, later],
                 database.scrapbox_line_metadata(updated.id).map { |line| line.fetch(:updated_at) })
  end

  def test_first_tracked_save_preserves_existing_lines_at_the_page_update_time
    later = FIXED_TIME + 3600
    times = [FIXED_TIME, later]
    database = dsql_database(clock: -> { times.shift || later })
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "既存記事", body: "以前からある行"
    ))
    @pool.connection.clear_line_metadata(page.id)

    updated = database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id, page_type: page.page_type, name: page.name,
      body: "新しい行\n以前からある行", expected_updated_at: page.updated_at
    ))

    assert_equal([later, FIXED_TIME],
                 database.scrapbox_line_metadata(updated.id).map { |line| line.fetch(:updated_at) })
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
    assert_equal([["item-1", page.id, "インボックス採用"]],
                 database.list_inbox_item_usages.map { |usage| [usage.item_id, usage.page_id, usage.page_route] })
  end

  def test_updates_only_the_preview_for_the_matching_inbox_image
    database = dsql_database
    row = inbox_row("item-1", expires_at: FIXED_TIME + 3600)
    row["payload"] = {
      "inbox_key" => "assets/inbox/photo.jpg",
      "preview_url" => "/assets/inbox/photo.jpg",
      "captured_at_source" => "exif",
    }
    @pool.connection.add_inbox_item(row)

    updated = database.update_inbox_item_preview(
      item_id: "item-1", inbox_key: "assets/inbox/photo.jpg",
      preview_url: "/assets/inbox/thumbnails/photo.webp"
    )

    assert_equal true, updated
    assert_equal "/assets/inbox/thumbnails/photo.webp", @pool.connection.items.fetch("item-1").fetch("payload").fetch("preview_url")
    assert_equal "assets/inbox/photo.jpg", @pool.connection.items.fetch("item-1").fetch("payload").fetch("inbox_key")
    assert_equal false, database.update_inbox_item_preview(
      item_id: "item-1", inbox_key: "assets/inbox/other.jpg", preview_url: "/wrong.webp"
    )
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

  def dsql_database(clock: -> { FIXED_TIME }, monotonic_clock: nil)
    @pool = Pool.new
    options = {
      host: "cluster.dsql.ap-northeast-1.on.aws",
      content_dir: Pathname("content"),
      clock:,
      pool: @pool,
    }
    options[:monotonic_clock] = monotonic_clock unless monotonic_clock.nil?
    WeblogAuthoring::DsqlDatabase.new(**options)
  end

  def inbox_row(id, expires_at:)
    {
      "id" => id, "source" => "photo", "kind" => "photo", "source_id" => id,
      "occurred_at" => FIXED_TIME, "ingested_at" => FIXED_TIME, "expires_at" => expires_at,
      "payload" => {}, "created_at" => FIXED_TIME, "updated_at" => FIXED_TIME,
    }
  end
end
