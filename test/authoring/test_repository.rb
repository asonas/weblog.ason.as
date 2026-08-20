# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class TestRepository < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T00:00:00+09:00")

  def test_first_date_save_creates_only_the_date_source_file
    repository = repository_for

    page = repository.save_draft(new_date_request(Date.new(2026, 1, 1), "本文"))

    assert_equal tmpdir.join("content/2026-01-01.md"), page.path
    assert_equal ["2026-01-01.md"], tmpdir.join("content").children.map(&:basename).map(&:to_s)
    assert_equal page, repository.find_route("/2026-01-01")
  end

  def test_second_date_page_for_same_day_is_rejected
    repository = repository_for
    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "本文"))

    error = assert_raises(WeblogAuthoring::ConflictError) do
      repository.save_draft(new_date_request(Date.new(2026, 1, 1), "別本文"))
    end

    assert_includes error.message, "2026-01-01"
  end

  def test_saving_wiki_link_creates_an_empty_named_draft
    repository = repository_for

    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))

    linked_page = repository.find_route("/page-a")
    refute_nil linked_page
    assert_equal "draft", linked_page.status
    assert linked_page.empty?
    assert linked_page.path.read(encoding: "UTF-8").end_with?("---\n")
  end

  def test_invalid_external_document_is_reported_without_overwrite
    path = tmpdir.join("content/2026-01-01.md")
    path.dirname.mkpath
    original = "---\nstatus: broken\n---\n本文\n"
    path.write(original)

    snapshot = repository_for.refresh

    assert_equal path, snapshot.problems.fetch(0).path
    assert_equal original, path.read
  end

  def test_list_pages_filters_by_query_status_and_empty_state
    repository = repository_for
    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]", title: "Today"))
    named_page = repository.find_route("/page-a")
    refute_nil named_page
    publish_named_page(named_page.path)

    pages = repository.list_pages(query: "page-a", status: "published", empty_only: true)

    assert_equal ["page-a"], pages.map(&:route)
  end

  def test_refresh_uses_external_markdown_edits_as_source_of_truth
    repository = repository_for
    page = repository.save_draft(new_date_request(Date.new(2026, 1, 1), "old body", title: "Today"))
    updated = page.path.read.sub("old body", "new body")
    page.path.write(updated)

    refreshed = repository.refresh.pages.find { |candidate| candidate.id == page.id }

    refute_nil refreshed
    assert_equal "new body", refreshed.body
  end

  def test_external_named_document_at_noncanonical_path_is_reported
    path = tmpdir.join("content/other.md")
    path.dirname.mkpath
    path.write(
      <<~DOC
        ---
        id: wrong-path
        page_type: named
        name: page-a
        status: draft
        created_at: 2026-01-01 00:00:00 +09:00
        updated_at: 2026-01-01 00:00:00 +09:00
        ---
      DOC
    )

    snapshot = repository_for.refresh

    assert_empty snapshot.pages
    assert_includes snapshot.problems.fetch(0).detail, "canonical source path"
  end

  def test_rename_collision_leaves_all_source_files_unchanged
    repository = repository_for
    first = repository.save_draft(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "page-a", body: "本文"))
    repository.save_draft(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "page-b", body: "本文"))
    before = source_bytes

    error = assert_raises(WeblogAuthoring::ConflictError) do
      repository.rename_named_page(first.id, "page-b")
    end

    assert_includes error.message, "page-b"
    assert_equal before, source_bytes
    assert_equal first.id, repository.find_route("/page-a").id
  end

  def test_rename_updates_source_links_and_preserves_the_page_id
    repository = repository_for
    source = repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))
    target = repository.find_route("/page-a")
    refute_nil target

    renamed = repository.rename_named_page(target.id, "page-b")

    assert_equal target.id, renamed.id
    assert_equal tmpdir.join("content/page-b.md"), renamed.path
    refute tmpdir.join("content/page-a.md").exist?
    assert_includes source.path.read, "[[page-b]]"
  end

  def test_rename_restores_source_files_when_transaction_fails
    repository = repository_for
    repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))
    target = repository.find_route("/page-a")
    refute_nil target
    before = source_bytes

    original = WeblogAuthoring::FileTransaction.instance_method(:replace)
    calls = 0
    WeblogAuthoring::FileTransaction.send(:define_method, :replace) do |path, content|
      calls += 1
      raise IOError, "simulated write failure" if calls == 2

      original.bind_call(self, path, content)
    end

    error = assert_raises(IOError) do
      repository.rename_named_page(target.id, "page-b")
    end

    assert_includes error.message, "simulated write failure"
    assert_equal before, source_bytes
  ensure
    WeblogAuthoring::FileTransaction.send(:define_method, :replace, original) if defined?(original) && original
  end

  def test_save_draft_restores_created_files_when_transaction_fails
    repository = repository_for
    original = WeblogAuthoring::FileTransaction.instance_method(:replace)
    calls = 0
    WeblogAuthoring::FileTransaction.send(:define_method, :replace) do |path, content|
      calls += 1
      raise IOError, "simulated write failure" if calls == 2

      original.bind_call(self, path, content)
    end

    error = assert_raises(IOError) do
      repository.save_draft(new_date_request(Date.new(2026, 1, 1), "[[page-a]]"))
    end

    assert_includes error.message, "simulated write failure"
    assert_equal [], Pathname.glob(tmpdir.join("content/*.md").to_s)
  ensure
    WeblogAuthoring::FileTransaction.send(:define_method, :replace, original) if defined?(original) && original
  end

  private

  def repository_for
    WeblogAuthoring::ContentRepository.new(
      tmpdir.join("content"),
      tmpdir.join("data/index/authoring.sqlite3"),
      -> { FIXED_TIME }
    )
  end

  def new_date_request(page_date, body = "", title: nil)
    WeblogAuthoring::SaveRequest.new(page_type: "date", page_date:, body:, title:)
  end

  def publish_named_page(path)
    path.write(path.read.sub("status: draft", "status: published"))
  end

  def source_bytes
    Pathname.glob(tmpdir.join("content/*.md").to_s).sort.each_with_object({}) do |path, values|
      values[path] = path.binread
    end
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("weblog-authoring-repository"))
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end
end
