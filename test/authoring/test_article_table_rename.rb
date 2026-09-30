# frozen_string_literal: true

require_relative "../test_helper"
require "sqlite3"
require "open3"
require "weblog_authoring/draft_store"
require "weblog_authoring/published_article_reader"

class ArticleTableRenameTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("article-table-rename"))
    @path = @root.join("legacy.sqlite3")
    @connection = SQLite3::Database.new(@path.to_s)
    @connection.results_as_hash = true
    @connection.execute_batch(File.read(File.expand_path("../fixtures/drafts/article_tables_legacy.sql", __dir__)))
    @db = WeblogAuthoring::DraftStore::SqliteConnection.new(@connection)
    @rename = WeblogAuthoring::ArticleTableRename.new(@db)
  end

  def teardown
    @connection.close
    FileUtils.remove_entry(@root)
  end

  def test_round_trip_preserves_publication_and_editing_data_and_can_be_repeated
    before = database_contents
    store = WeblogAuthoring::DraftStore.sqlite(@path)
    assert_raises(RuntimeError) { store.setup! }
    assert_equal before, database_contents
    expected = @rename.snapshot
    assert_equal expected, @rename.rename!(direction: "forward")
    assert_equal expected, @rename.rename!(direction: "forward")
    store.setup!
    article = WeblogAuthoring::PublishedArticleReader.new(store:, database: nil).find_route("2026-09-01")
    assert_equal "dc802ad0b89946aeb6b7623c2ba7bc79", article.id
    assert_equal "公開本文 [[日記]]", article.body
    assert_equal Time.iso8601("2026-09-01T01:00:00Z"), article.created_at
    assert_equal expected, @rename.rename!(direction: "reverse")
    assert_equal expected, @rename.rename!(direction: "reverse")
    assert_equal before, database_contents.slice(*before.keys)
  end

  def test_resumes_after_interrupted_ddl_and_reverses_completed_tables
    before = database_contents
    assert_raises(IOError) do
      @rename.rename!(direction: "forward") do |event|
        raise IOError, "connection lost" if event["event"] == "renamed" && event["target"] == "article_published_versions"
      end
    end
    assert_includes @db.table_names, "articles"
    assert_includes @db.table_names, "draft_publication_jobs"
    @rename.rename!(direction: "reverse")
    assert_equal before, database_contents
    @db.query("ALTER TABLE draft_articles RENAME TO articles")
    @rename.rename!(direction: "forward")
    assert @rename.status.all? { |row| row["current_exists"] && !row["old_exists"] }
  end

  def test_ambiguous_or_missing_tables_stop_before_any_rename
    @db.query("CREATE TABLE articles (id TEXT)")
    before = database_contents
    assert_raises(RuntimeError) { @rename.rename!(direction: "forward") }
    assert_equal before, database_contents
    @db.query("DROP TABLE articles")
    @db.query("DROP TABLE draft_rename_members")
    before = database_contents
    assert_raises(RuntimeError) { @rename.rename!(direction: "forward") }
    assert_equal before, database_contents
  end

  def test_command_requires_confirmation_and_records_verified_progress
    executable = File.expand_path("../../bin/rename-article-tables", __dir__)
    before = database_contents
    _output, error, status = Open3.capture3(RbConfig.ruby, executable, "forward", "--sqlite", @path.to_s)
    refute status.success?
    assert_includes error, "Confirm the exact target"
    assert_equal before, database_contents
    record = @root.join("progress.jsonl")
    output, error, status = Open3.capture3(
      RbConfig.ruby, executable, "forward", "--sqlite", @path.to_s,
      "--confirm-target", @path.to_s, "--stopped", "--record", record.to_s
    )
    assert status.success?, error
    assert_equal "verified", JSON.parse(output.lines.last).fetch("event")
    entries = record.readlines.map { |line| JSON.parse(line) }
    assert_equal "before", entries.first.fetch("event")
    assert_equal "verified", entries.last.fetch("event")
    assert_equal @path.to_s, entries.last.fetch("target")
    assert_equal entries.first.fetch("tables"), entries.last.fetch("tables")
  end

  private

  def database_contents
    @db.table_names.sort.to_h { |name| [name, @db.query("SELECT * FROM #{name}")] }
  end
end
