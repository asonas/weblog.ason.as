# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "weblog_authoring/draft_publication"

class ArticleMigrationTest < Minitest::Test
  SCOPE = { "protocol" => 1, "generation" => 1 }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("article-migration"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @id = SecureRandom.uuid
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_splits_working_diary_and_moves_footer_without_changing_the_public_version
    body = "最初\n---\n続き\n```markdown\n---\n```\n---\n[[水曜日]] [[202609]] [[0923]] [[日記]]"
    seed(body, "2026-09-23")
    prepared = @publication.prepare(@id)
    version = @publication.accept(@id, prepared.merge("request_id" => SecureRandom.uuid))
    @publication.complete(@id, version.fetch("id")) { "published/day.html" }
    public_before = @store.published_snapshot(@id)
    before = @store.read(@id, {})
    migrated = @publication.migrate_article(@id, SCOPE.merge("head" => before.fetch("head")))
    assert_equal "pieces", migrated.fetch("format")
    assert_equal %w[水曜日 202609 0923 日記], migrated.dig("structure", "tags")
    assert_equal "date", migrated.dig("metadata", "page_type", "value")
    assert_equal "2026-09-23", migrated.dig("metadata", "page_date", "value")
    assert_equal before.values_at("id", "created_at", "updated_at"), migrated.values_at("id", "created_at", "updated_at")
    assert_equal public_before, @store.published_snapshot(@id)
    assert_equal migrated.fetch("structure"), @publication.migrate_article(@id, SCOPE.merge("head" => before.fetch("head"))).fetch("structure")
    prepared = @publication.prepare(@id)
    version = @publication.accept(@id, prepared.merge("request_id" => SecureRandom.uuid))
    @publication.complete(@id, version.fetch("id")) { "published/day.html" }
    pieces = @store.published_snapshot(@id).dig("metadata", "content", "pieces")
    assert_equal(["最初", "続き\n```markdown\n---\n```"], pieces.map { |piece| piece.fetch("body") })
  end

  def test_rejects_stale_head_and_preserves_named_article_metadata_on_migration
    seed("前半\n---\n後半 [[猫]]", "普通の記事")
    before = @store.read(@id, {})
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @publication.migrate_article(@id, SCOPE.merge("head" => 0)) }.status
    assert_equal before, @store.read(@id, {})
    migrated = @publication.migrate_article(@id, SCOPE.merge("head" => before.fetch("head")))
    assert_equal before.fetch("metadata"), migrated.fetch("metadata")
    assert_equal 2, migrated.dig("structure", "piece_ids").length
  end

  private

  def seed(body, title)
    @store.create(@id, SCOPE)
    output, error, status = Open3.capture3("node", "scripts/seed-draft.mjs", stdin_data: JSON.generate(body))
    raise error unless status.success?
    @store.append(@id, SCOPE.merge(JSON.parse(output), "update_id" => SecureRandom.uuid, "body_bytes" => body.bytesize,
      "metadata" => { "title" => { "value" => title, "expected_revision" => 0 } }))
  end
end
