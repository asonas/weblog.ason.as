# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "open3"
require "weblog_authoring/draft_publication"
require "weblog_authoring/development_database"
require "weblog_authoring/webmention_site_publisher"
require "weblog_authoring/lambda_api"
require "weblog_authoring/draft_publisher"
require "weblog_authoring/development_app"
require "rack/mock"

class ArticlePiecesTest < Minitest::Test
  SCOPE = { "protocol" => 1, "generation" => 1, "format" => "pieces" }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("article-pieces"))
    @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"), pieces_enabled: true)
    @store.setup!
    @id = SecureRandom.uuid
    @first = SecureRandom.uuid
    @store.create(@id, SCOPE.merge("piece_id" => @first, "tags" => ["日記"]))
    @publication = WeblogAuthoring::DraftPublication.local(store: @store)
    append_piece(@first, "最初の本文\n\n---\n\n同じかけらの続き", metadata: { "title" => { "value" => "2026-10-01", "expected_revision" => 0 } })
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_order_and_tags_are_published_as_an_immutable_snapshot
    second = SecureRandom.uuid
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 0, "piece_ids" => [@first, second], "tags" => %w[日記 木曜日]))
    append_piece(second, "二つ目 [[テーマ]]")
    confirmation = @publication.prepare(@id)
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 1, "piece_ids" => [second, @first], "tags" => ["日記"]))
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @publication.accept(@id, confirmation.merge("request_id" => "stale")) }.status
    publish
    snapshot = @store.published_snapshot(@id)
    assert_equal([second, @first], snapshot.dig("metadata", "content", "pieces").map { |piece| piece.fetch("id") })
    assert_equal "最初の本文\n\n---\n\n同じかけらの続き", snapshot.dig("metadata", "content", "pieces", 1, "body")
    assert_equal ["日記"], snapshot.dig("metadata", "content", "tags")
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 2, "piece_ids" => [@first], "tags" => []))
    assert_equal snapshot, @store.published_snapshot(@id)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.update_structure(@id, SCOPE.merge("expected_revision" => 3, "piece_ids" => [@first, second], "tags" => []))
    }.status
  end

  def test_daily_creation_uses_the_gate_without_converting_existing_diaries
    legacy_store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"))
    legacy = legacy_store.daily_draft("2026-09-30")
    assert_equal "legacy", @store.daily_draft("2026-09-30", tags: ["日記"]).fetch("format")
    assert_equal legacy.fetch("id"), @store.daily_draft("2026-09-30").fetch("id")
    diary = @store.daily_draft("2026-10-02", tags: %w[金曜日 日記])
    assert_equal "pieces", diary.fetch("format")
    assert_equal %w[金曜日 日記], diary.dig("structure", "tags")
    assert_equal 1, diary.dig("structure", "piece_ids").length
    assert_equal diary, legacy_store.daily_draft("2026-10-02")
    @store.delete_piece_draft(diary.fetch("id"), SCOPE.merge("head" => 0, "structure_revision" => 0))
    refute_equal diary.fetch("id"), @store.daily_draft("2026-10-02", tags: ["日記"]).fetch("id")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.create(SecureRandom.uuid, { "protocol" => 1, "generation" => 1 }) }.status
  end

  def test_import_is_atomic_retryable_and_keeps_original_until_publication
    memo_id = SecureRandom.uuid
    piece_id = SecureRandom.uuid
    @store.save_memo(memo_id, { "operation_id" => SecureRandom.uuid, "expected_revision" => 0, "body" => "持ち込む文章" })
    request = { "memo_id" => memo_id, "piece_id" => piece_id, "operation_id" => SecureRandom.uuid, "expected_revision" => 1, "structure_revision" => 0 }
    result = @publication.adopt_memo(@id, request)
    assert_equal result, @publication.adopt_memo(@id, request)
    assert_empty @store.list_memos
    assert_equal [@first, piece_id], @store.read(@id, { "format" => "pieces" }).dig("structure", "piece_ids")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.delete_published_memo_bodies(@id, "not-published")
    }.status
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => "publish-memo"))
    assert_raises(IOError) { @publication.complete(@id, version.fetch("id")) { raise IOError, "placement failed" } }
    db = SQLite3::Database.new(@root.join("drafts.sqlite3").to_s)
    assert_equal "持ち込む文章", db.get_first_value("SELECT body FROM inbox_memos WHERE id = ?", [memo_id])
    @publication.complete(@id, version.fetch("id")) { "published/memo.html" }
    assert @store.published_memos_pending?(@id, version.fetch("id"))
    @store.delete_published_memo_bodies(@id, version.fetch("id"))
    assert_nil db.get_first_value("SELECT body FROM inbox_memos WHERE id = ?", [memo_id])
    assert_equal result, @publication.adopt_memo(@id, request)
    assert_equal "持ち込む文章", @store.published_snapshot(@id).dig("metadata", "content", "pieces", 1, "body")
  ensure
    db&.close
  end

  def test_old_clients_cannot_overwrite_piece_documents_or_convert_existing_articles
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.read(@id, {}) }.status
    seed = seed_piece(@first, "古い画面の本文")
    payload = { "protocol" => 1, "generation" => 1, "update_id" => SecureRandom.uuid, "metadata" => {} }.merge(seed)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.append(@id, payload) }.status
    legacy = SecureRandom.uuid
    WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3")).create(legacy, { "protocol" => 1, "generation" => 1 })
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.create(legacy, SCOPE.merge("piece_id" => SecureRandom.uuid)) }.status
    assert_equal "legacy", @store.read(legacy, {}).fetch("format")
  end

  def test_deleting_an_unpublished_draft_restores_original_memos_without_recreating_the_draft
    memo_id = SecureRandom.uuid
    @store.save_memo(memo_id, { "operation_id" => SecureRandom.uuid, "expected_revision" => 0, "body" => "取り込み前の本文" })
    @publication.adopt_memo(@id, { "memo_id" => memo_id, "piece_id" => SecureRandom.uuid, "operation_id" => SecureRandom.uuid, "expected_revision" => 1, "structure_revision" => 0 })
    saved = @store.read(@id, { "format" => "pieces" })
    request = SCOPE.merge("head" => saved.fetch("head"), "structure_revision" => 1)
    assert_equal({ "deleted" => true }, @store.delete_piece_draft(@id, request))
    assert_equal({ "deleted" => true }, @store.delete_piece_draft(@id, request))
    assert_equal "取り込み前の本文", @store.find_memo(memo_id).fetch("body")
    assert_equal 410, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.create(@id, SCOPE.merge("piece_id" => @first)) }.status
  end

  def test_unchanged_publication_also_releases_memos_removed_from_the_working_draft
    publish
    memo_id = SecureRandom.uuid
    piece_id = SecureRandom.uuid
    @store.save_memo(memo_id, { "operation_id" => SecureRandom.uuid, "expected_revision" => 0, "body" => "取り込んだあと削除した文章" })
    @publication.adopt_memo(@id, { "memo_id" => memo_id, "piece_id" => piece_id, "operation_id" => SecureRandom.uuid, "expected_revision" => 1, "structure_revision" => 0 })
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 1, "piece_ids" => [@first], "tags" => ["日記"]))
    accepted = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => SecureRandom.uuid))
    assert_equal "unchanged", accepted.fetch("status")
    assert @store.published_memos_pending?(@id, accepted.fetch("id"))
    @store.delete_published_memo_bodies(@id, accepted.fetch("id"))
    refute @store.published_memos_pending?(@id, accepted.fetch("id"))
  end

  def test_failed_import_rolls_back_both_the_new_piece_and_its_body
    memo_id = SecureRandom.uuid
    @store.save_memo(memo_id, { "operation_id" => SecureRandom.uuid, "expected_revision" => 0, "body" => "失敗しても残す" })
    db = SQLite3::Database.new(@root.join("drafts.sqlite3").to_s)
    db.execute("CREATE TRIGGER reject_adoption BEFORE UPDATE OF state ON inbox_memos WHEN NEW.state = 'consumed' BEGIN SELECT RAISE(ABORT, 'test storage rejection'); END")
    before = @store.read(@id, { "format" => "pieces" })
    request = { "memo_id" => memo_id, "piece_id" => SecureRandom.uuid, "operation_id" => SecureRandom.uuid, "expected_revision" => 1, "structure_revision" => 0 }
    assert_raises(SQLite3::ConstraintException) { @publication.adopt_memo(@id, request) }
    assert_equal before, @store.read(@id, { "format" => "pieces" })
    assert_equal "失敗しても残す", @store.find_memo(memo_id).fetch("body")
    db.execute("DROP TRIGGER reject_adoption")
    assert_equal "consumed", @publication.adopt_memo(@id, request).fetch("state")
  ensure
    db&.close
  end

  def test_mentions_use_only_published_diary_pieces_and_link_to_stable_anchors
    diary = @store.daily_draft("2026-10-03", tags: ["タグだけ"])
    @id = diary.fetch("id")
    first = diary.dig("structure", "piece_ids").first
    second = SecureRandom.uuid
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 0, "piece_ids" => [first, second], "tags" => ["タグだけ"]))
    append_piece(first, "[[未作成のテーマ]] [[未作成のテーマ]]\n\n> 引用文\n\n`[[コードのみ]]`\n\n```\n[[コードのみ]]\n```\n\n[[2026-10-03]]")
    append_piece(second, "写真と[[未作成のテーマ]]\n\n![写真](/assets/example.webp)")
    assert_empty @store.mentioned_by_days("未作成のテーマ").fetch("days")
    publish
    result = @store.mentioned_by_days("未作成のテーマ")
    assert_equal(["2026-10-03"], result.fetch("days").map { |day| day.fetch("day") })
    assert_equal([first, second], result.dig("days", 0, "pieces").map { |piece| piece.fetch("id") })
    assert_equal "/2026-10-03#piece-#{first}", result.dig("days", 0, "pieces", 0, "href")
    %w[タグだけ コードのみ 2026-10-03].each { |name| assert_empty @store.mentioned_by_days(name).fetch("days"), name }
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    renderer = WeblogAuthoring::WebmentionSitePublisher.new(database:, s3_client: nil, site_bucket: nil, sqs_client: nil, delivery_queue_url: nil)
    html = renderer.render_document(WeblogAuthoring::ArticleDocument.from_published_version(@store.published_snapshot(@id)), shell: '<html><head></head><div id="authoring-root"></div></html>', source_url: "https://example.com/2026-10-03")
    assert_includes html, %(id="piece-#{first}")
    api = WeblogAuthoring::LambdaApi.new(database:, draft_store: @store)
    response = api.call("rawPath" => "/api/mentioned-by-days", "requestContext" => { "http" => { "method" => "GET" } }, "queryStringParameters" => { "route" => "未作成のテーマ" })
    assert_equal 200, response.fetch(:statusCode), response.fetch(:body)
    assert_includes JSON.parse(response.fetch(:body)).dig("days", 0, "pieces", 0, "html"), "<blockquote>"
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 1, "piece_ids" => [], "tags" => ["日記"]))
    assert_equal 2, @store.mentioned_by_days("未作成のテーマ").dig("days", 0, "pieces").length
    publish
    assert_empty @store.mentioned_by_days("未作成のテーマ").fetch("days")
  end

  def test_mentions_page_by_ten_days_and_follow_a_later_created_and_renamed_target
    11.times do |index|
      date = (Date.new(2026, 10, 1) + index).iso8601
      diary = @store.daily_draft(date, tags: ["日記"])
      @id = diary.fetch("id")
      append_piece(diary.dig("structure", "piece_ids").first, "[[Old topic]]への言及")
      publish
    end
    first = @store.mentioned_by_days("Old topic")
    assert_equal 10, first.fetch("days").length
    assert_equal "2026-10-11", first.dig("days", 0, "day")
    assert_equal "2026-10-02", first.fetch("cursor")
    last = @store.mentioned_by_days("Old topic", before: first.fetch("cursor"))
    assert_equal(["2026-10-01"], last.fetch("days").map { |day| day.fetch("day") })
    assert_nil last.fetch("cursor")
    @id = SecureRandom.uuid
    target_piece = SecureRandom.uuid
    @store.create(@id, SCOPE.merge("piece_id" => target_piece))
    append_piece(target_piece, "ストックする記事", metadata: { "title" => { "value" => "Old topic", "expected_revision" => 0 } })
    publish
    assert_equal first, @store.mentioned_by_days("Old topic")
    append_piece(target_piece, "", metadata: { "title" => { "value" => "New topic", "expected_revision" => 1 } })
    publish
    renamed = @store.mentioned_by_days("New topic")
    assert_equal 10, renamed.fetch("days").length
    assert_equal "[[New topic]]への言及", renamed.dig("days", 0, "pieces", 0, "body")
    assert_equal renamed, @store.mentioned_by_days("Old topic")
  end

  def test_publishing_a_diary_creates_editable_empty_link_targets_without_overwriting_existing_articles
    publish
    existing = @store.published_snapshot(@id)
    diary = @store.daily_draft("2040-01-03", tags: ["タグのみ"])
    @id = diary.fetch("id")
    append_piece(diary.dig("structure", "piece_ids").first, "[[猫]] [[猫]] [[2026-10-01]] `[[コードのみ]]`\n\n```\n[[コードのみ]]\n```\n\n[[api]]")
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    publisher = WeblogAuthoring::DraftPublisher.local(publication: @publication, database:, root: @root.join("published"), shell: -> { '<html><head></head><div id="authoring-root"></div></html>' }, site_url: "https://example.com")
    assert_nil @store.published_route("猫")
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => SecureRandom.uuid))
    assert_nil @store.published_route("猫")
    publisher.run(@id, version.fetch("id"))
    target = @store.published_route("猫")
    assert_equal "", target.fetch("body")
    assert_equal "猫", target.dig("metadata", "title")
    assert_includes publisher.read(target), 'data-public-article="1"'
    assert_includes publisher.read(target), "猫"
    assert_equal "public", @publication.prepare(target.fetch("article_id")).fetch("article_state")
    app = Class.new(WeblogAuthoring::DevelopmentApp)
    app.set :raise_errors, true
    app.set :authentication_required, false
    app.set :draft_store, @store
    app.set :database, database
    app.set :reader_database, WeblogAuthoring::PublishedArticleReader.new(store: @store, database:)
    response = Rack::MockRequest.new(app).get("/#{WeblogAuthoring.encoded_route('猫')}", "HTTP_HOST" => "localhost")
    assert_equal 200, response.status
    assert_includes response.body, 'data-public-article="1"'
    assert_includes response.body, target.fetch("article_id").to_s
    %w[タグのみ コードのみ api].each { |name| assert_nil @store.published_route(name), name }
    assert_equal existing, @store.published_route("2026-10-01")
    publisher.run(@id, version.fetch("id"))
    assert_equal target, @store.published_route("猫")
    @id = target.fetch("article_id")
    piece = SecureRandom.uuid
    @store.update_structure(@id, SCOPE.merge("expected_revision" => 0, "piece_ids" => [piece], "tags" => []))
    append_piece(piece, "あとから書き足した本文")
    updated = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => SecureRandom.uuid))
    publisher.run(@id, updated.fetch("id"))
    assert_equal "あとから書き足した本文", @store.published_route("猫").fetch("body")
    publisher.run(diary.fetch("id"), version.fetch("id"))
    assert_equal "あとから書き足した本文", @store.published_route("猫").fetch("body")
  end

  def test_empty_target_html_placement_can_be_retried_without_creating_another_article
    diary = @store.daily_draft("2040-01-04")
    @id = diary.fetch("id")
    append_piece(diary.dig("structure", "piece_ids").first, "[[再試行する猫]]")
    database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
    database.setup!
    failed = false
    publisher = WeblogAuthoring::DraftPublisher.new(publication: @publication, database:, site_url: "https://example.com", shell: -> { '<html><head></head><div id="authoring-root"></div></html>' }, read: ->(_key) { "" }) do |_key, html|
      if html.include?("<title>再試行する猫") && !failed
        failed = true
        raise IOError, "storage unavailable"
      end
    end
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => SecureRandom.uuid))
    assert_raises(IOError) { publisher.run(@id, version.fetch("id")) }
    assert_nil @store.published_route("再試行する猫")
    publisher.run(@id, version.fetch("id"))
    target = @store.published_route("再試行する猫")
    refute_nil target
    publisher.run(@id, version.fetch("id"))
    assert_equal target, @store.published_route("再試行する猫")
  end

  private

  def seed_piece(id, body)
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "lambda/draft_worker/local.ts", stdin_data: JSON.generate(operation: "seed_piece", piece_id: id, body:))
    raise error unless status.success?
    JSON.parse(output)
  end

  def append_piece(id, body, metadata: {})
    @store.append(@id, SCOPE.merge(seed_piece(id, body)).merge("update_id" => SecureRandom.uuid, "metadata" => metadata))
  end

  def publish
    version = @publication.accept(@id, @publication.prepare(@id).merge("request_id" => SecureRandom.uuid))
    @publication.complete(@id, version.fetch("id")) { "published/pieces.html" }
  end
end
