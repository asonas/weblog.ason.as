# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "weblog_authoring/development_diary_migration"

class DevelopmentDiaryMigrationTest < Minitest::Test
  SCOPE = { "protocol" => 1, "generation" => 1 }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("diary-migration"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @id = SecureRandom.uuid
    @body = "以前の日記\n\n---\n\n続き [[猫]]\n\n```\n---\n```\n\n[[日記]]"
    @store.create(@id, SCOPE)
    output, error, status = Open3.capture3("node", "scripts/seed-draft.mjs", stdin_data: JSON.generate(@body))
    raise error unless status.success?
    @store.append(@id, SCOPE.merge(JSON.parse(output), "update_id" => SecureRandom.uuid, "body_bytes" => @body.bytesize, "metadata" => {
      "title" => { "value" => "2026-09-23", "expected_revision" => 0 },
      "page_type" => { "value" => "date", "expected_revision" => 0 },
      "page_date" => { "value" => "2026-09-23", "expected_revision" => 0 },
    }))
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    publish
    @migration = WeblogAuthoring::DevelopmentDiaryMigration.new(store: @store)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_preserves_the_entire_body_and_public_version_until_the_next_publication
    working = @store.read(@id, {})
    public_version = @store.published_snapshot(@id)
    assert_equal "planned", @migration.migrate(@id).fetch("status")
    assert_equal working, @store.read(@id, {})
    assert_equal "migrated", @migration.migrate(@id, apply: true).fetch("status")
    migrated = @store.read(@id, "format" => "pieces")
    assert_equal working.slice("id", "created_at", "updated_at", "metadata"), migrated.slice("id", "created_at", "updated_at", "metadata")
    assert_equal 1, migrated.dig("structure", "piece_ids").length
    assert_equal public_version, @store.published_snapshot(@id)
    assert_equal "already_pieces", @migration.migrate(@id, apply: true).fetch("status")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.read(@id, {}) }.status
    publish
    current = @store.published_snapshot(@id)
    assert_equal public_version.values_at("article_id", "route", "published_at", "article_created_at"), current.values_at("article_id", "route", "published_at", "article_created_at")
    assert_equal [{ "id" => migrated.dig("structure", "piece_ids", 0), "body" => @body }], current.dig("metadata", "content", "pieces")
    assert_equal @body, current.fetch("body")
    assert_equal 1, @store.mentioned_by_days("猫").dig("days", 0, "pieces").length
  end

  def test_rejects_a_diary_edited_after_reconstruction_without_changing_its_format
    job = @store.checkpoint_job(@id)
    @store.append(@id, SCOPE.merge("data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0, "update_id" => SecureRandom.uuid, "metadata" => {}))
    seed = { "piece_id" => SecureRandom.uuid, "data" => "AAA=" }
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.convert_legacy_diary(@id, job, seed) }.status
    assert_equal "legacy", @store.read(@id, {}).fetch("format")
  end

  def test_moves_only_the_trailing_tag_footer_out_of_the_body
    [false, true].each do |inside_code|
      id = SecureRandom.uuid
      prefix = inside_code ? "本文\n```\n" : "本文 [[猫]]\n\n---\n\n続き\n"
      body = prefix + "\n---\n\n[[水曜日]] [[202609]] [[0923]] [[日記]]"
      @store.create(id, SCOPE)
      output, error, status = Open3.capture3("node", "scripts/seed-draft.mjs", stdin_data: JSON.generate(body))
      raise error unless status.success?
      @store.append(id, SCOPE.merge(JSON.parse(output), "update_id" => SecureRandom.uuid, "body_bytes" => body.bytesize, "metadata" => {
        "title" => { "value" => inside_code ? "2026-09-25" : "2026-09-24", "expected_revision" => 0 },
        "page_type" => { "value" => "date", "expected_revision" => 0 },
        "page_date" => { "value" => inside_code ? "2026-09-25" : "2026-09-24", "expected_revision" => 0 },
      }))
      plan = @migration.migrate(id, apply: true)
      expected_tags = inside_code ? [] : %w[水曜日 202609 0923 日記]
      assert_equal expected_tags, plan.fetch("tags")
      assert_equal expected_tags, @store.read(id, "format" => "pieces").dig("structure", "tags")
      prepared = @publication.prepare(id)
      version = @publication.accept(id, prepared.merge("request_id" => SecureRandom.uuid))
      @publication.complete(id, version.fetch("id")) { "published/test.html" }
      assert_equal inside_code ? body : prefix.chomp, @store.published_snapshot(id).dig("metadata", "content", "pieces", 0, "body")
    end
  end

  private

  def publish
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => SecureRandom.uuid))
    @publication.complete(@id, version.fetch("id")) { "published/diary.html" }
  end
end
