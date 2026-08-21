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
    assert_equal "2026-08-21", page.route
    assert_equal ["page-a"], page.links.map(&:name)
    refute tmpdir.join("content/2026-08-21.md").exist?

    updated = database.save(
      WeblogAuthoring::SaveRequest.new(
        page_id: page.id,
        page_type: "date",
        page_date: page.page_date,
        title: page.title,
        body: "更新した本文",
        expected_updated_at: page.updated_at
      )
    )

    assert_equal "更新した本文", database.find(page.id).body
    assert_equal updated, database.find_route("/2026-08-21")
  end

  def test_date_route_is_unique
    database = development_database
    request = WeblogAuthoring::SaveRequest.new(
      page_type: "date",
      page_date: Date.new(2026, 8, 21),
      title: "最初の記事",
      body: "本文"
    )
    database.save(request)

    error = assert_raises(WeblogAuthoring::ConflictError) { database.save(request) }
    assert_includes error.message, "2026-08-21"
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
