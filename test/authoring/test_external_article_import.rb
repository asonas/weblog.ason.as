# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/external_article_import"
require "weblog_authoring/draft_jobs"
require "weblog_authoring/development_database"

class ExternalArticleImportTest < Minitest::Test
  SCOPE = { "protocol" => 1, "generation" => 1 }.freeze
  SLUG = "2026-06-15-kosendj-42"
  TITLE = "高専DJ 第42回 まとめ"
  # UUIDv5 of "ason.as:#{SLUG}" in the RFC 4122 URL namespace; reruns on any machine must derive the same id.
  ID = "a16c067f-4a17-5db5-843f-aa7ef8334f88"

  class SearchProcess
    attr_reader :corpus

    def build(workdir:, corpus_dir:)
      @corpus = Dir.children(corpus_dir).sort.map { |name| File.read(File.join(corpus_dir, name)) }
      path = File.join(workdir, "index.sqlite3")
      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE documents (id INTEGER PRIMARY KEY, collection TEXT, path TEXT, active INTEGER, hash TEXT)")
      db.execute("CREATE TABLE content (hash TEXT PRIMARY KEY, doc TEXT)")
      db.execute("CREATE VIRTUAL TABLE documents_fts USING fts5(path, title, body)")
      Dir.children(corpus_dir).sort.each_with_index do |name, index|
        body = File.read(File.join(corpus_dir, name))
        hash = Digest::SHA256.hexdigest(body)
        db.execute("INSERT INTO documents VALUES (?, 'weblog', ?, 1, ?)", [index + 1, name, hash])
        db.execute("INSERT INTO content VALUES (?, ?)", [hash, body])
        db.execute("INSERT INTO documents_fts(rowid, path, title, body) VALUES (?, ?, ?, ?)", [index + 1, name, body.lines.first, body])
      end
      db.close
      path
    end
  end

  def setup
    @root = Pathname(Dir.mktmpdir("external-article-import"))
    @path = @root.join("drafts.sqlite3")
    @store = WeblogAuthoring::DraftStore.sqlite(@path)
    @store.setup!
    @store.setup_cutover!
    # Opened directly; the phase transitions themselves are covered by test_draft_cutover.
    set_phase("open")
    @importer = WeblogAuthoring::ExternalArticleImport.new(store: @store)
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    @manifest = {
      "format" => 1, "site_url" => "https://example.com", "source" => "ason.as", "articles" => [{
        "slug" => SLUG, "display_title" => TITLE, "body" => "# 見出し\r\n\r\n![写真](/assets/uploads/2026/06/photo.jpg)\r\n",
        "created_at" => "2026-06-15T09:00:00+09:00", "updated_at" => "2026-06-20T12:00:00.5+09:00", "published_at" => "2026-06-16T10:00:00+09:00",
        "cover_mode" => "explicit", "cover_image_url" => "/assets/uploads/2026/06/photo.jpg",
      }],
    }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_import_publishes_with_historical_times_atom_identity_and_display_title
    result = @importer.import(@manifest)
    assert_equal([{ "slug" => SLUG, "id" => ID, "status" => "imported" }], result.map { |entry| entry.slice("slug", "id", "status") })
    snapshot = @store.published_snapshot(ID)
    assert_equal SLUG, snapshot.fetch("route")
    assert_equal SLUG, snapshot.dig("metadata", "title")
    assert_equal TITLE, snapshot.dig("metadata", "display_title")
    assert_equal "# 見出し\n\n![写真](/assets/uploads/2026/06/photo.jpg)\n", snapshot.fetch("body")
    assert_equal "2026-06-15T00:00:00.000000Z", snapshot.fetch("article_created_at")
    assert_equal "2026-06-16T01:00:00.000000Z", snapshot.fetch("published_at")
    assert_equal "2026-06-20T03:00:00.500000Z", snapshot.fetch("updated_at")
    assert_equal "https://example.com/#{SLUG}", snapshot.fetch("atom_id")
    assert_equal ["2026-06-15T00:00:00.000000Z", "2026-06-20T03:00:00.500000Z"], @store.read(ID, {}).values_at("created_at", "updated_at")
    assert_equal "public", @publication.prepare(ID).fetch("article_state")
    assert_equal "unchanged", @publication.accept(ID, @publication.prepare(ID).merge("request_id" => "unchanged")).fetch("status")
  end

  def test_import_requests_no_cache_invalidation_or_webmention_delivery
    @importer.import(@manifest)
    database = SQLite3::Database.new(@path.to_s)
    %w[article_cache_requests article_webmention_requests].each do |table|
      assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM #{table}"), table
    end
  ensure
    database&.close
  end

  def test_rerun_is_a_no_op_and_never_overwrites_changed_or_edited_articles
    @importer.import(@manifest)
    snapshot = @store.published_snapshot(ID)
    revision = @store.publication_revision
    assert_equal([{ "slug" => SLUG, "id" => ID, "status" => "already-imported" }], @importer.plan(@manifest).map { |entry| entry.slice("slug", "id", "status") })
    assert_equal(["already-imported"], @importer.import(@manifest).map { |entry| entry.fetch("status") })
    assert_equal snapshot, @store.published_snapshot(ID)
    assert_equal revision, @store.publication_revision

    changed = Marshal.load(Marshal.dump(@manifest))
    changed.fetch("articles").first["display_title"] = "別の見出し"
    assert_conflict(changed, "already exists")
    assert_equal snapshot, @store.published_snapshot(ID)

    @store.append(ID, SCOPE.merge("update_id" => "edit", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0,
      "metadata" => { "cover_mode" => { "value" => "none", "expected_revision" => 0 }, "cover_image_url" => { "value" => nil, "expected_revision" => 0 } }))
    assert_conflict(@manifest, "already exists")
    assert_equal "none", @store.read(ID, {}).dig("metadata", "cover_mode", "value")
  end

  def test_import_refuses_an_existing_draft_with_the_same_id_without_writing
    @store.create(ID, SCOPE)
    assert_conflict(@manifest, "already exists")
    assert_empty @store.published_collection.fetch("snapshots")
    assert_equal 0, @store.read(ID, {}).fetch("head")
  end

  def test_import_refuses_a_route_that_is_published_or_reserved_by_another_article
    other = Marshal.load(Marshal.dump(@manifest))
    other["source"] = "other.example"
    @importer.import(other)
    assert_conflict(@manifest, "already published by article")

    # A draft that has claimed a URL keeps it even before it is published.
    database = SQLite3::Database.new(@path.to_s)
    database.execute("INSERT INTO article_route_reservations (route, article_id) VALUES (?, ?)", ["reserved-slug", SecureRandom.uuid])
    database.close
    reserved = @manifest.merge("articles" => [@manifest.fetch("articles").first.merge("slug" => "reserved-slug")])
    assert_conflict(reserved, "is reserved by article")
    assert_equal 1, @store.published_collection.fetch("snapshots").length
  end

  def test_import_requires_the_authoring_window_to_be_open
    set_phase("legacy")
    assert_raises(WeblogAuthoring::DraftStore::CutoverError) { @importer.import(@manifest) }
    assert_empty @store.published_collection.fetch("snapshots")
    assert_empty @store.cutover_status.fetch("operations")
  end

  def test_prepare_rejects_unsafe_manifests_and_lists_every_problem
    article = @manifest.fetch("articles").first
    invalid = [
      [{ "slug" => "published" }, "reserved"],
      [{ "slug" => "search" }, "reserved"],
      [{ "slug" => "llms.txt" }, "reserved"],
      [{ "slug" => "2026-06-15" }, "date route"],
      [{ "slug" => "bad?slug" }, "forbidden character"],
      [{ "display_title" => "一行目\n二行目" }, "display_title"],
      [{ "display_title" => "  " }, "display_title"],
      [{ "created_at" => "2026-06-15T09:00:00" }, "explicit offset"],
      [{ "updated_at" => "2026-06-15T09:00:00Z" }, "updated_at must not be earlier"],
      [{ "body" => "![x](https://example.net/a.png)\n\n![ref][r]\n\n[r]: http://example.net/b.png" }, "https://example.net/a.png, http://example.net/b.png"],
      [{ "cover_mode" => "explicit", "cover_image_url" => "https://example.net/c.png" }, "local asset"],
      [{ "legacy" => true }, "unknown field legacy"],
    ]
    invalid.each do |changes, message|
      error = assert_raises(WeblogAuthoring::DraftStore::Error, changes.inspect) { @importer.prepare(@manifest.merge("articles" => [article.merge(changes)])) }
      assert_includes error.message, message
    end
    code = article.merge("body" => "```\n![x](https://example.net/a.png)\n```\n`![y](https://example.net/b.png)`")
    assert_equal 1, @importer.prepare(@manifest.merge("articles" => [code])).fetch("articles").length
    error = assert_raises(WeblogAuthoring::DraftStore::Error) { @importer.prepare(@manifest.merge("articles" => [article, article])) }
    assert_includes error.message, "slug appears 2 times"
    assert_empty @store.administration_page
  end

  def test_repair_renders_the_display_title_in_page_feed_and_search_while_keeping_original_times
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    objects = WeblogAuthoring::LocalPublicationObjects.new(@root.join("objects"))
    objects.put_object(bucket: "site", key: "index.html", body: '<html><head></head><body><div id="authoring-root"></div></body></html>')
    publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database:, s3_client: objects, site_bucket: "site", site_url: "https://example.com")
    search = SearchProcess.new
    outputs = WeblogAuthoring::DraftOutputs.new(store: @store, s3_client: objects, bucket: "site", site_url: "https://example.com",
      search_runner: search, cache_dir: @root.join("search-cache").to_s)
    jobs = WeblogAuthoring::DraftJobs.new(store: @store, publisher:, outputs:)
    @importer.import(@manifest)
    snapshot = @store.published_snapshot(ID)

    assert_equal "completed", jobs.repair.fetch("status")
    html = publisher.read(@store.published_snapshot(ID)).dup.force_encoding(Encoding::UTF_8)
    assert_includes html, %(<h1 class="p-name">#{TITLE}</h1>)
    assert_includes html, "<title>#{TITLE} | weblog.ason.as</title>"
    assert_includes html, %(<meta property="og:title" content="#{TITLE}" />)
    assert_includes html, %(<link rel="canonical" href="https://example.com/#{SLUG}" />)
    feed = outputs.feed.dup.force_encoding(Encoding::UTF_8)
    assert_includes feed, "<title>#{TITLE}</title>"
    assert_includes feed, "<id>https://example.com/#{SLUG}</id>"
    assert_includes feed, "<published>2026-06-16T01:00:00Z</published>"
    assert_equal ["# #{TITLE}\n\nURL: /#{SLUG}\n\n# 見出し\n\n![写真](/assets/uploads/2026/06/photo.jpg)\n\n"], search.corpus
    assert_equal([TITLE], outputs.search(query: "kosendj", limit: 10).results.map { |entry| entry.fetch("title") })
    assert_equal snapshot, @store.published_snapshot(ID).except("html_key", "html_digest")
    assert_empty database.pending_webmention_outbox
  end

  private

  def assert_conflict(manifest, message)
    error = assert_raises(WeblogAuthoring::DraftStore::Error) { @importer.import(manifest) }
    assert_equal 409, error.status
    assert_includes error.message, message
  end

  def set_phase(phase)
    database = SQLite3::Database.new(@path.to_s)
    database.execute("UPDATE draft_cutover_state SET phase = ? WHERE id = 1", [phase])
  ensure
    database&.close
  end
end
