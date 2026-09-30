# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/scrapbox_hashtag_repair"
require "weblog_authoring/draft_migration"

class ScrapboxHashtagRepairTest < Minitest::Test
  ID = "dc802ad0b89946aeb6b7623c2ba7bc79"

  def setup
    @root = Pathname(Dir.mktmpdir("hashtag-repair"))
    @store = WeblogAuthoring::ScrapboxHashtagRepair.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    @body = "編集後の本文\n#hoge #日本語\n```\n#hoge #日本語\n```\n末尾"
    WeblogAuthoring::DraftMigration.new(store: @store).import({
      "format" => 1, "site_url" => "https://example.com", "articles" => [{
        "id" => ID, "page_type" => "named", "route" => "記事", "title" => "記事", "body" => @body,
        "cover_mode" => "auto", "cover_image_url" => nil,
        "created_at" => "2020-01-01T00:00:00Z", "updated_at" => "2021-01-01T00:00:00Z", "published_at" => "2020-02-01T00:00:00Z",
      }],
    })
    @backup = { "snapshot" => @store.published_snapshot(ID), "document" => @store.read(ID, { "cursor" => "1" }),
      "job" => @publication.send(:reconstruction_job, ID), }
    @differences = [{ "before" => "- #hoge #日本語", "after" => "- [[hoge]] [[日本語]]" }]
    @plan = WeblogAuthoring::ScrapboxHashtagRepair.prepare(@backup, @differences)
    @artifact = { "html_key" => "published/repair.html", "html_digest" => "test-digest" }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_repair_preserves_dates_and_history_and_reconstructs_matching_working_and_published_bodies
    original = @backup.fetch("snapshot")
    assert_equal "repaired", @store.apply_repair(@plan, artifact: @artifact)
    snapshot = @store.published_snapshot(ID)
    assert_equal "編集後の本文\n[[hoge]] [[日本語]]\n```\n#hoge #日本語\n```\n末尾", snapshot.fetch("body")
    assert_equal original.slice("created_at", "article_created_at", "updated_at", "published_at", "metadata", "route", "atom_id"), snapshot.slice("created_at", "article_created_at", "updated_at", "published_at", "metadata", "route", "atom_id")
    assert_equal @backup.fetch("document").slice("created_at", "updated_at"), @store.read(ID, {}).slice("created_at", "updated_at")
    assert_equal "public", @publication.prepare(ID).fetch("article_state")
    assert_equal @body, @store.publication_snapshot(ID, original.fetch("id")).fetch("body")
    assert_equal "already_repaired", @store.apply_repair(@plan, artifact: @artifact)
    assert_equal 2, @store.read(ID, {}).fetch("head")
    assert_equal 2, @store.publication_revision
    db = SQLite3::Database.new(@root.join("drafts.sqlite3").to_s)
    assert_equal 0, db.get_first_value("SELECT count(*) FROM article_webmention_requests")
  ensure
    db&.close
  end

  def test_concurrent_edit_is_rejected_without_changing_publication
    @store.append(ID, { "protocol" => 1, "generation" => 1, "update_id" => "concurrent", "data" => @plan.dig("update", "data"), "digest" => @plan.dig("update", "digest"), "body_bytes" => @plan.dig("update", "body_bytes"), "metadata" => {} })
    assert_raises(WeblogAuthoring::DraftStore::Error) { @store.apply_repair(@plan, artifact: @artifact) }
    assert_equal @backup.fetch("snapshot"), @store.published_snapshot(ID)
  end

  def test_unpublished_body_is_rejected_during_plan
    changed = Marshal.load(Marshal.dump(@backup))
    changed["snapshot"]["body"] = "未公開の差分\n#hoge #日本語"
    assert_raises(WeblogAuthoring::DraftStore::Error) { WeblogAuthoring::ScrapboxHashtagRepair.prepare(changed, @differences) }
  end
end
