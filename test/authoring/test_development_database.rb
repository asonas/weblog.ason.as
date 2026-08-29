# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_database"

require "fileutils"

class TestDevelopmentDatabase < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-21T12:00:00+09:00")

  def test_save_reads_and_writes_page_documents_without_markdown_files
    database = development_database
    page = database.save(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 8, 21),
        title: "最初の記事",
        body: "本文 [[page-a]]"
      )
    )

    assert database.path.file?
    assert_equal page, database.find(page.id)
    assert_equal "published", page.status
    assert_equal "最初の記事", page.route
    assert_equal ["page-a"], page.links.map(&:name)
    refute tmpdir.join("content/2026-08-21.md").exist?

    updated = database.save(
      WeblogAuthoring::SaveRequest.new(
        page_id: page.id,
        page_type: page.page_type,
        name: page.name,
        body: "更新した本文",
        expected_updated_at: page.updated_at
      )
    )

    assert_equal "更新した本文", database.find(page.id).body
    assert_equal updated, database.find_route("/最初の記事")
  end

  def test_save_tracks_new_and_changed_line_update_times
    current_time = Time.iso8601("2026-08-21T12:00:00+09:00")
    database = WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("data/development/authoring.sqlite3"),
      content_dir: tmpdir.join("content"),
      clock: -> { current_time }
    )
    database.setup!
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "行更新", body: "残る行\n変更前\n末尾"
    ))

    assert_equal [current_time.to_i] * 3,
                 database.scrapbox_line_metadata(page.id).map { |line| line.fetch(:updated_at).to_i }

    current_time = Time.iso8601("2026-08-21T13:00:00+09:00")
    updated = database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id,
      page_type: page.page_type,
      name: page.name,
      body: "追加行\n残る行\n変更後\n末尾",
      expected_updated_at: page.updated_at
    ))

    assert_equal [current_time.to_i, page.updated_at.to_i, current_time.to_i, page.updated_at.to_i],
                 database.scrapbox_line_metadata(updated.id).map { |line| line.fetch(:updated_at).to_i }
  end

  def test_titles_are_unique_and_the_same_date_can_have_multiple_pages
    database = development_database
    database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "date",
      page_date: Date.new(2026, 8, 21),
      title: "最初の記事",
      body: "本文"
    ))
    second = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "date",
      page_date: Date.new(2026, 8, 21),
      title: "次の記事",
      body: "本文"
    ))

    assert_equal "次の記事", second.route
    error = assert_raises(WeblogAuthoring::ConflictError) do
      database.save(WeblogAuthoring::SaveRequest.new(
        page_type: "named",
        name: "最初の記事",
        body: "重複"
      ))
    end
    assert_includes error.message, "最初の記事"
  end

  def test_list_pages_orders_pages_by_update_time_descending
    current_time = Time.iso8601("2026-08-20T12:00:00+09:00")
    database = WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("data/development/authoring.sqlite3"),
      content_dir: tmpdir.join("content"),
      clock: -> { current_time }
    )
    database.setup!
    database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "older", body: "古い記事"
    ))
    current_time = Time.iso8601("2026-08-21T12:00:00+09:00")
    database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "newer", body: "新しい記事"
    ))

    older = database.find_route("older")
    current_time = Time.iso8601("2026-08-22T12:00:00+09:00")
    database.save(WeblogAuthoring::SaveRequest.new(
      page_id: older.id, page_type: older.page_type, name: older.name,
      body: "更新した記事", expected_updated_at: older.updated_at
    ))

    assert_equal ["older", "newer"], database.list_pages.map(&:name)
  end

  def test_list_pages_reads_only_the_records_next_to_a_cursor
    current_time = Time.iso8601("2025-01-31T12:00:00+09:00")
    database = WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("data/development/authoring.sqlite3"),
      content_dir: tmpdir.join("content"),
      clock: -> { current_time }
    )
    database.setup!
    january = database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "january", body: "[[日記]]"))
    current_time = Time.iso8601("2025-02-01T12:00:00+09:00")
    february = database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "february", body: ""))
    current_time = Time.iso8601("2025-03-01T12:00:00+09:00")
    database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "march", body: ""))

    assert_equal ["january"], database.list_pages(limit: 1, before: { timestamp: february.updated_at, id: february.id }).map(&:name)
    assert_equal ["february"], database.list_pages(limit: 1, after: { timestamp: january.updated_at, id: january.id }).map(&:name)
    assert_equal ["january"], database.list_pages(kind: "diary").map(&:name)
    assert_equal ["march", "february"], database.list_pages(kind: "article").map(&:name)
  end

  def test_save_records_inbox_usage_and_commits_its_image_adoption_atomically
    database = development_database
    item = database.upsert_inbox_item(
      source: "photo", kind: "photo", source_id: "photo-1", occurred_at: FIXED_TIME,
      payload: { "inbox_key" => "assets/inbox/photo.webp", "preview_url" => "/assets/inbox/photo.webp", "captured_at_source" => "exif" }
    )
    database.prepare_inbox_image_adoption(
      item_id: item.id, inbox_key: "assets/inbox/photo.webp", public_key: "assets/uploads/2026/08/photo.webp"
    )

    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "写真の日記", body: "![photo](/assets/uploads/2026/08/photo.webp)",
      consumed_inbox_item_ids: [item.id]
    ))

    assert_equal "写真の日記", page.name
    assert_equal [item.id], database.list_inbox_items.map(&:id)
    assert_equal [[item.id, page.id, "写真の日記"]],
                 database.list_inbox_item_usages.map { |usage| [usage.item_id, usage.page_id, usage.page_route] }
    SQLite3::Database.new(database.path.to_s) do |sqlite|
      refute_nil sqlite.get_first_value("SELECT committed_at FROM inbox_image_adoptions WHERE item_id = ?", item.id)
      assert_equal page.id, sqlite.get_first_value("SELECT page_id FROM inbox_item_usages WHERE item_id = ?", item.id)
    end
  end

  def test_expired_inbox_item_rolls_back_page_save
    original = development_database
    item = original.upsert_inbox_item(
      source: "photo", kind: "photo", source_id: "photo-1", occurred_at: FIXED_TIME,
      payload: { "inbox_key" => "assets/inbox/photo.webp", "preview_url" => "/assets/inbox/photo.webp", "captured_at_source" => "exif" }
    )
    expired = WeblogAuthoring::DevelopmentDatabase.new(
      original.path, content_dir: tmpdir.join("content"), clock: -> { FIXED_TIME + (8 * 86_400) }
    )

    error = assert_raises(WeblogAuthoring::ConflictError) do
      expired.save(WeblogAuthoring::SaveRequest.new(
        page_type: "named", name: "保存されない記事", body: "本文", consumed_inbox_item_ids: [item.id]
      ))
    end

    assert_equal "inbox_item_expired", error.message
    assert_nil expired.find_route("保存されない記事")
  end

  def test_version_one_date_pages_are_migrated_to_title_routes
    database = development_database
    database.path.dirname.mkpath
    SQLite3::Database.new(database.path.to_s) do |sqlite|
      sqlite.execute_batch(<<~SQL)
        PRAGMA user_version = 1;
        CREATE TABLE pages (
          id TEXT PRIMARY KEY, page_type TEXT NOT NULL, name TEXT, page_date TEXT,
          title TEXT, status TEXT NOT NULL, created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL, published_at TEXT, path TEXT NOT NULL,
          body_hash TEXT NOT NULL, is_empty INTEGER NOT NULL, body TEXT NOT NULL
        );
        CREATE UNIQUE INDEX pages_date_route ON pages(page_date) WHERE page_type = 'date';
        CREATE UNIQUE INDEX pages_named_route ON pages(name) WHERE page_type = 'named';
        CREATE TABLE links (
          source_id TEXT NOT NULL, target_id TEXT, target_name TEXT NOT NULL,
          position INTEGER NOT NULL, PRIMARY KEY (source_id, position)
        );
        INSERT INTO pages VALUES (
          'legacy', 'date', NULL, '2026-08-21', 'test', 'published',
          '2026-08-21T12:00:00+09:00', '2026-08-21T12:00:00+09:00',
          '2026-08-21T12:00:00+09:00', 'content/2026-08-21.md', '', 1, ''
        );
      SQL
    end

    database.setup!

    page = database.find_route("/test")
    assert_equal "named", page.page_type
    assert_equal "test", page.name
    assert_nil database.find_route("/2026-08-21")
  end

  def test_version_four_database_gains_inbox_usage_schema
    database = development_database
    database.path.dirname.mkpath
    SQLite3::Database.new(database.path.to_s) do |sqlite|
      sqlite.execute_batch(<<~SQL)
        PRAGMA user_version = 4;
        CREATE TABLE pages (
          id TEXT PRIMARY KEY,
          name TEXT,
          page_date TEXT
        );
        CREATE TABLE inbox_items (id TEXT PRIMARY KEY);
        CREATE TABLE inbox_image_adoptions (item_id TEXT PRIMARY KEY);
      SQL
    end

    database.setup!

    assert_equal [], database.list_inbox_item_usages
  end

  def test_rename_updates_incoming_and_self_wiki_links
    database = development_database
    target = database.save(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "old", body: "[[old]]")
    )
    source = database.save(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "source", body: "see [[old]]")
    )

    renamed = database.rename(
      target.id,
      "new",
      body: target.body,
      expected_updated_at: target.updated_at
    )

    assert_equal "new", renamed.route
    assert_equal "[[new]]", renamed.body
    assert_equal "see [[new]]", database.find(source.id).body
    assert_nil database.find_route("old")
  end

  private

  def development_database
    WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("data/development/authoring.sqlite3"),
      content_dir: tmpdir.join("content"),
      clock: -> { FIXED_TIME }
    )
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("weblog-development-database"))
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end
end
