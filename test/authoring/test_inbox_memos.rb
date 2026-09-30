# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "sqlite3"
require "weblog_authoring/draft_store"

class InboxMemosTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("inbox-memos"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @id = SecureRandom.uuid
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_autosaves_plain_markdown_and_preserves_conflicting_edits_once
    initial = save("思いついたこと\n\n[[記事]]", 0)
    assert_equal 1, initial.fetch("revision")
    saved = save("先に保存した追記", 1)
    operation = payload("別の端末からの追記", 1)
    conflict = @store.save_memo(@id, operation)
    assert_equal "preserved_as_new", conflict.fetch("result")
    refute_equal @id, conflict.fetch("id")
    assert_equal conflict, @store.save_memo(@id, operation)
    assert_equal 2, @store.list_memos.length
    assert_equal "先に保存した追記", @store.find_memo(@id).fetch("body")
    assert_equal "別の端末からの追記", @store.find_memo(conflict.fetch("id")).fetch("body")
    assert_equal 2, saved.fetch("revision")
  end

  def test_deleted_body_is_removed_without_reviving_it_on_retry
    operation = payload("消す本文", 0)
    saved = @store.save_memo(@id, operation)
    deletion = payload(nil, 1).reject { |key, _| key == "body" }
    deleted = @store.delete_memo(@id, deletion)
    assert_equal deleted, @store.delete_memo(@id, deletion)
    assert_equal saved, @store.save_memo(@id, operation)
    assert_empty @store.list_memos
    assert_equal "deleted", save("消す本文", 1).fetch("state")
    preserved = save("未送信だった新しい文章", 1)
    assert_equal "preserved_as_new", preserved.fetch("result")
    assert_equal "未送信だった新しい文章", @store.find_memo(preserved.fetch("id")).fetch("body")
    db = SQLite3::Database.new(@root.join("drafts.sqlite3").to_s)
    assert_nil db.get_first_value("SELECT body FROM inbox_memos WHERE id = ?", [@id])
    db.execute("SELECT result FROM inbox_memo_operations").each { |row| refute_includes row.first, "消す本文" }
  ensure
    db&.close
  end

  def test_stale_delete_and_reused_operation_id_cannot_overwrite_a_memo
    operation = payload("最初", 0)
    @store.save_memo(@id, operation)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.save_memo(@id, operation.merge("body" => "別内容"))
    }.status
    save("更新後", 1)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.delete_memo(@id, payload(nil, 1))
    }.status
    assert_equal "更新後", @store.find_memo(@id).fetch("body")
  end

  private

  def payload(body, revision)
    { "operation_id" => SecureRandom.uuid, "expected_revision" => revision, "body" => body }
  end

  def save(body, revision)
    @store.save_memo(@id, payload(body, revision))
  end
end
