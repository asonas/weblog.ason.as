# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_database"
require_relative "../../lib/weblog_authoring/scrapbox_line_metadata_importer"

require "fileutils"

class TestScrapboxLineMetadataImporter < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-28T12:00:00+09:00")

  def test_imports_metadata_and_replaces_changed_lines_with_the_save_time
    database.setup!
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named",
      name: "記事",
      body: "最初の行\n次の行"
    ))
    export_path.write(JSON.generate(
      "name" => "example",
      "pages" => [{
        "title" => "記事",
        "lines" => [
          { "text" => "- 記事", "created" => 1_700_000_000, "updated" => 1_700_000_001, "userId" => "user-1" },
          { "text" => "最初の行", "created" => 1_700_000_010, "updated" => 1_700_000_011, "userId" => "user-1" },
          { "text" => "次の行", "created" => 1_700_000_020, "updated" => 1_700_000_021, "userId" => "user-1" },
          { "text" => "", "created" => 1_700_000_030, "updated" => 1_700_000_031, "userId" => "user-1" }
        ]
      }]
    ))

    counts = WeblogAuthoring::ScrapboxLineMetadataImporter.new(database:, export_path:).run

    assert_equal(
      {
        imported_pages: 1,
        imported_lines: 2,
        unmatched_pages: 0,
        skipped_pages: 0,
        unmatched_titles: [],
        skipped_titles: []
      },
      counts
    )
    assert_equal [1_700_000_011, 1_700_000_021],
                 database.scrapbox_line_metadata(page.id).map { |line| line.fetch(:updated_at).to_i }

    database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id,
      page_type: page.page_type,
      name: page.name,
      body: "変更した行",
      expected_updated_at: page.updated_at
    ))
    assert_equal [FIXED_TIME.to_i],
                 database.scrapbox_line_metadata(page.id).map { |line| line.fetch(:updated_at).to_i }
  end

  private

  def database
    @database ||= WeblogAuthoring::DevelopmentDatabase.new(
      tmpdir.join("authoring.sqlite3"),
      content_dir: tmpdir.join("content"),
      clock: -> { FIXED_TIME }
    )
  end

  def export_path
    tmpdir.join("scrapbox.json")
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("scrapbox-line-metadata"))
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end
end
