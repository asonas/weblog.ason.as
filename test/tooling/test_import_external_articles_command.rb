# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "weblog_authoring/draft_store"

class ImportExternalArticlesCommandTest < Minitest::Test
  COMMAND = ["ruby", "-rbundler/setup", "bin/import-external-articles"].freeze
  SLUG = "2026-06-15-kosendj-42"

  def setup
    @root = Pathname(Dir.mktmpdir("import-external-articles"))
    @database = @root.join("drafts.sqlite3")
    @manifest = @root.join("manifest.json")
    @manifest.write(JSON.generate("format" => 1, "site_url" => "https://example.com", "source" => "ason.as", "articles" => [{
      "slug" => SLUG, "display_title" => "高専DJ 第42回 まとめ", "body" => "本文",
      "created_at" => "2026-06-15T09:00:00+09:00", "updated_at" => "2026-06-20T12:00:00+09:00", "published_at" => "2026-06-16T10:00:00+09:00",
    }]))
    WeblogAuthoring::DraftStore.sqlite(@database).setup!
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_applying_to_a_host_requires_the_exact_host_before_connecting
    host = "example.dsql.ap-northeast-1.on.aws"
    output, error, status = Open3.capture3(*COMMAND, "--manifest", @manifest.to_s, "--host", host, "--apply")
    refute status.success?
    assert_empty output
    assert_includes error, "Confirm the exact host"
    _output, error, status = Open3.capture3(*COMMAND, "--manifest", @manifest.to_s, "--host", host, "--confirm-host", "other.dsql.ap-northeast-1.on.aws", "--apply")
    refute status.success?
    assert_includes error, "Confirm the exact host"
  end

  def test_dry_run_plans_without_writing_and_apply_is_idempotent
    store = WeblogAuthoring::DraftStore.sqlite(@database)
    arguments = ["--manifest", @manifest.to_s, "--database", @database.to_s]
    planned = plan(arguments)
    assert_equal([{ "slug" => SLUG, "status" => "new" }], planned.fetch("articles").map { |entry| entry.slice("slug", "status") })
    assert_empty store.published_collection.fetch("snapshots")

    output, error, status = Open3.capture3(*COMMAND, *arguments, "--apply")
    assert status.success?, error
    assert_equal(["imported"], JSON.parse(output).fetch("articles").map { |entry| entry.fetch("status") })
    assert_equal SLUG, store.published_collection.fetch("snapshots").first.fetch("route")
    assert_equal(["already-imported"], plan(arguments).fetch("articles").map { |entry| entry.fetch("status") })

    @manifest.write(@manifest.read.sub("本文", "別の本文"))
    output, _error, status = Open3.capture3(*COMMAND, *arguments)
    refute status.success?
    assert_equal(["conflict"], JSON.parse(output).fetch("articles").map { |entry| entry.fetch("status") })
  end

  private

  def plan(arguments)
    output, error, status = Open3.capture3(*COMMAND, *arguments)
    assert status.success?, error
    JSON.parse(output)
  end
end
