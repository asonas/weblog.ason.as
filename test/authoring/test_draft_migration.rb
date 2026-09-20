# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_migration"
require "weblog_authoring/draft_publication"
require "weblog_authoring/draft_outputs"
require "weblog_authoring/development_database"

class DraftMigrationTest < Minitest::Test
  ID = "dc802ad0b89946aeb6b7623c2ba7bc79"

  def setup
    @root = Pathname(Dir.mktmpdir("draft-migration"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    @store.setup!
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    @source = {
      "format" => 1, "site_url" => "https://example.com", "articles" => [{
        "id" => ID, "page_type" => "date", "route" => "2026-09-01", "title" => "日付とは異なる日記タイトル",
        "body" => "# 元の本文\r\n\r\n`ruby` と日本語。", "cover_mode" => "explicit", "cover_image_url" => "/assets/cover.jpg",
        "created_at" => "2026-09-01T01:02:03.123456Z", "updated_at" => "2026-09-03T04:05:06.654321Z",
        "published_at" => "2026-09-02T01:02:03.123456Z",
      }],
    }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_migration_preserves_content_identity_and_feed_times_without_republication
    migration = WeblogAuthoring::DraftMigration.new(store: @store)
    result = migration.import(@source)
    assert_equal 1, result.fetch("articles")
    original = @source.fetch("articles").first
    snapshot = @store.published_snapshot(ID)
    assert_equal ID, snapshot.fetch("article_id")
    assert_equal original.fetch("body"), snapshot.fetch("body")
    assert_equal original.fetch("title"), snapshot.dig("metadata", "title")
    assert_equal "/assets/cover.jpg", snapshot.dig("metadata", "cover_image_url")
    assert_equal "2026-09-01", snapshot.fetch("route")
    assert_equal "2026-09-01T01:02:03.123456Z", snapshot.fetch("article_created_at")
    assert_equal "2026-09-03T04:05:06.654321Z", snapshot.fetch("updated_at")
    assert_equal "2026-09-02T01:02:03.123456Z", snapshot.fetch("published_at")
    assert_equal "https://example.com/2026-09-01", snapshot.fetch("atom_id")
    assert_equal "public", @publication.prepare(ID).fetch("article_state")
    assert_equal original.fetch("updated_at"), @store.read(ID, {}).fetch("updated_at")
    assert_equal result, migration.import(@source)
    assert_equal snapshot, @store.published_snapshot(ID)
    unchanged = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "unchanged"))
    assert_equal "unchanged", unchanged.fetch("status")
    objects = WeblogAuthoring::LocalPublicationObjects.new(@root.join("objects"))
    outputs = WeblogAuthoring::DraftOutputs.new(store: @store, s3_client: objects, bucket: "site", site_url: "https://example.com")
    artifact = outputs.build("atom")
    feed = objects.get_object(bucket: "site", key: artifact.fetch("object_key")).body.read
    assert_includes feed, "<id>https://example.com/2026-09-01</id>"
    assert_includes feed, "<published>2026-09-02T01:02:03Z</published>"
    assert_includes feed, "<updated>2026-09-03T04:05:06Z</updated>"
    legacy = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    legacy.setup!
    publisher = WeblogAuthoring::DraftPublisher.local(publication: @publication, database: legacy, root: @root.join("html"),
      shell: -> { '<html><head></head><body><div id="authoring-root"></div></body></html>' }, site_url: "https://example.com")
    artifact = publisher.repair(snapshot)
    assert @store.record_publication_html(ID, snapshot.fetch("id"), artifact)
    repaired = @store.published_snapshot(ID)
    assert_includes publisher.read(repaired), "日付とは異なる日記タイトル"
    assert_equal snapshot, repaired.except("html_key", "html_digest")
    assert_empty legacy.pending_webmention_outbox
  end

  def test_restart_resumes_a_partial_import_without_replacing_committed_versions
    @source.fetch("articles") << @source.fetch("articles").first.merge("id" => "ff802ad0b89946aeb6b7623c2ba7bc79", "route" => "2026-09-02")
    plan = WeblogAuthoring::DraftMigration.new(store: @store).prepare(@source)
    @store.begin_migration(plan.fetch("fingerprint"))
    output, error, status = Open3.capture3("node", "scripts/seed-draft.mjs", stdin_data: JSON.generate(plan.fetch("articles").first.fetch("body")))
    assert status.success?, error
    @store.import_legacy_article(plan.fetch("fingerprint"), plan.fetch("articles").first, JSON.parse(output))
    first = @store.published_snapshot(ID)
    reopened = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    assert_equal 2, WeblogAuthoring::DraftMigration.new(store: reopened).import(@source).fetch("articles")
    assert_equal first, reopened.published_snapshot(ID)
    assert_equal 2, reopened.published_collection.fetch("snapshots").length
  end

  def test_reimport_refuses_changed_source_and_new_work_and_sealing_is_irreversible
    migration = WeblogAuthoring::DraftMigration.new(store: @store)
    migration.import(@source)
    altered = Marshal.load(Marshal.dump(@source))
    altered.fetch("articles").first["body"] = "違う移行元"
    assert_raises(WeblogAuthoring::DraftStore::Error) { migration.import(altered) }
    @store.append(ID, { "protocol" => 1, "generation" => 1, "update_id" => "edit", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "title" => { "value" => "保持する新しい編集", "expected_revision" => 0 } }, })
    assert_raises(WeblogAuthoring::DraftStore::Error) { migration.import(@source) }
    assert_equal "保持する新しい編集", @store.read(ID, {}).dig("metadata", "title", "value")
    @store.seal_migration
    assert_raises(WeblogAuthoring::DraftStore::Error) { migration.import(@source) }
    assert_equal "保持する新しい編集", @store.read(ID, {}).dig("metadata", "title", "value")
  end

  def test_renaming_an_imported_article_retains_its_original_atom_identity
    WeblogAuthoring::DraftMigration.new(store: @store).import(@source)
    @store.append(ID, { "protocol" => 1, "generation" => 1, "update_id" => "rename", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "page_date" => { "value" => "2026-09-04", "expected_revision" => 0 } }, })
    accepted = @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "rename"))
    @publication.complete(ID, accepted.fetch("id")) { "renamed.html" }
    snapshot = @store.published_snapshot(ID)
    assert_equal "2026-09-04", snapshot.fetch("route")
    assert_equal "https://example.com/2026-09-01", snapshot.fetch("atom_id")
    assert_equal "2026-09-04", @store.published_redirect("2026-09-01")
  end

  def test_invalid_input_is_rejected_before_any_article_is_copied
    @source.fetch("articles") << @source.fetch("articles").first.merge("id" => "ff802ad0b89946aeb6b7623c2ba7bc79", "route" => "2026-09-02", "body" => "x" * 524_289)
    assert_raises(WeblogAuthoring::DraftStore::Error) { WeblogAuthoring::DraftMigration.new(store: @store).import(@source) }
    assert_empty @store.administration_page
    assert_empty @store.published_collection.fetch("snapshots")
  end

  def test_command_preserves_source_and_rehearses_only_in_its_own_destination
    source_path = @root.join("legacy.sqlite3")
    database = WeblogAuthoring::DevelopmentDatabase.new(source_path, content_dir: @root.join("content"))
    database.setup!
    page = database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", title: "移行前の記事", body: "保存する本文"))
    before = Digest::SHA256.file(source_path).hexdigest
    snapshot = @root.join("preserved.json")
    command = ["ruby", "-rbundler/setup", "bin/draft-migration"]
    output, error, status = Open3.capture3(*command, "export", "--database", source_path.to_s, "--snapshot", snapshot.to_s, "--site-url", "https://example.com")
    assert status.success?, error
    assert_equal 1, JSON.parse(output).fetch("articles")
    assert_equal 0o600, snapshot.stat.mode & 0o777
    preserved = snapshot.read
    _output, _error, status = Open3.capture3(*command, "export", "--database", source_path.to_s, "--snapshot", snapshot.to_s, "--site-url", "https://example.com")
    refute status.success?
    assert_equal preserved, snapshot.read
    output, error, status = Open3.capture3(*command, "check", "--snapshot", snapshot.to_s)
    assert status.success?, error
    assert_equal 1, JSON.parse(output).fetch("articles")
    _output, _error, status = Open3.capture3(*command, "rehearse", "--database", source_path.to_s, "--snapshot", snapshot.to_s)
    refute status.success?
    assert_equal before, Digest::SHA256.file(source_path).hexdigest
    destination = @root.join("rehearsal.sqlite3")
    2.times do
      output, error, status = Open3.capture3(*command, "rehearse", "--database", destination.to_s, "--snapshot", snapshot.to_s)
      assert status.success?, error
      assert_equal 1, JSON.parse(output).fetch("articles")
    end
    migrated = WeblogAuthoring::DraftStore.sqlite(destination).published_snapshot(page.id)
    assert_equal "保存する本文", migrated.fetch("body")
    assert_equal "https://example.com/%E7%A7%BB%E8%A1%8C%E5%89%8D%E3%81%AE%E8%A8%98%E4%BA%8B", migrated.fetch("atom_id")
  end
end
