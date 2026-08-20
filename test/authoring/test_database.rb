# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class TestDatabase < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T00:00:00+09:00")

  def test_rebuild_restores_index_after_database_file_is_deleted
    repository = repository_for
    source = repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))
    database = database_for
    database.rebuild(repository.refresh)
    database.path.unlink

    database.rebuild(repository.refresh)

    target = repository.find_route("/page-a")
    refute_nil target
    assert_equal [source], database.backlinks(target.id)
  end

  def test_corrupt_database_is_rotated_and_rebuilt
    repository = repository_for
    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))
    database = database_for
    database.rebuild(repository.refresh)
    database.path.write("not sqlite", mode: "wb")

    database.rebuild(repository.refresh)

    assert database.integrity_ok?
    assert_equal 1, Pathname.glob(tmpdir.join("data/index/authoring.sqlite3.corrupt-*").to_s).size
  end

  def test_schema_version_mismatch_is_rotated_and_rebuilt
    repository = repository_for
    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "本文"))
    database = database_for

    database.connect.tap do |connection|
      connection.execute("PRAGMA user_version = 99")
    ensure
      connection.close
    end

    database.rebuild(repository.refresh)

    assert database.integrity_ok?
    assert_equal 1, Pathname.glob(tmpdir.join("data/index/authoring.sqlite3.corrupt-*").to_s).size
  end

  def test_backlinks_can_exclude_draft_sources_and_search_filters_status
    repository = repository_for
    draft = repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))
    published = repository.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "published", body: "[[page-a]]")
    )
    publish_named_page(published.path)
    snapshot = repository.refresh
    database = database_for
    database.rebuild(snapshot)

    target = repository.find_route("/page-a")
    refreshed_draft = repository.get_page(draft.id)
    refreshed_published = repository.get_page(published.id)
    refute_nil target

    assert_equal [refreshed_draft, refreshed_published], database.backlinks(target.id)
    assert_equal [refreshed_published], database.backlinks(target.id, public_only: true)
    assert_equal [refreshed_published], database.search("publish", "published")
    assert_equal [refreshed_draft], database.search("2026-01-01", "draft")
  end

  def test_rebuild_stores_problems_but_not_document_bodies
    repository = repository_for
    content_dir = tmpdir.join("content")
    content_dir.mkpath
    content_dir.join("broken.md").write("---\nstatus: broken\n---\nsecret body\n")
    page = repository.save_draft(new_date_request(Date.new(2026, 1, 1), "visible body"))
    database = database_for

    database.rebuild(repository.refresh)

    assert_equal [page], database.search("2026-01-01")

    database.connect.tap do |connection|
      dumped = connection.execute("SELECT * FROM pages").flatten.join(" ")
      problems = connection.execute("SELECT path, detail FROM problems")
      refute_includes dumped, "visible body"
      assert_equal [[content_dir.join("broken.md").to_s, "missing required key: id"]], problems
    ensure
      connection.close
    end
  end

  def test_integrity_ok_is_false_before_build_and_true_afterwards
    database = database_for

    refute database.integrity_ok?

    repository = repository_for
    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "本文"))
    database.rebuild(repository.refresh)

    assert database.integrity_ok?
  end

  private

  def repository_for
    WeblogAuthoring::ContentRepository.new(
      tmpdir.join("content"),
      tmpdir.join("data/index/authoring.sqlite3"),
      -> { FIXED_TIME }
    )
  end

  def database_for
    WeblogAuthoring::AuthoringDatabase.new(tmpdir.join("data/index/authoring.sqlite3"))
  end

  def new_date_request(page_date, body = "")
    WeblogAuthoring::SaveRequest.new(page_type: "date", page_date:, body:)
  end

  def publish_named_page(path)
    path.write(path.read.sub("status: draft", "status: published"))
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("weblog-authoring-database"))
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end
end
