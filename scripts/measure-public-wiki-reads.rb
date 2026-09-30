# frozen_string_literal: true

require "tmpdir"
require "sqlite3"
require "digest"
require "weblog_authoring/draft_migration"
require "weblog_authoring/published_article_reader"

Database = Class.new do
  def find_image_dimensions(_url) = nil
  def approved_webmentions_for_page(_id) = []
end

Dir.mktmpdir("wiki-reads") do |dir|
  path = File.join(dir, "drafts.sqlite3")
  store = WeblogAuthoring::DraftStore.sqlite(path)
  store.setup!
  date = "2026-09-01T00:00:00Z"
  article = lambda do |id, route, body|
    { "id" => id, "page_type" => "named", "route" => route, "title" => route,
      "body" => body, "cover_mode" => "none", "cover_image_url" => nil,
      "created_at" => date, "updated_at" => date, "published_at" => date, }
  end
  source_id = "%032x" % 1
  target_id = "%032x" % 2
  source = article.call(source_id, "Source", "本文 [[KORG multi/poly]] [[未作成]]")
  target = article.call(target_id, "KORG multi/poly", "公開済み本文" + ("あ" * 400))
  WeblogAuthoring::DraftMigration.new(store:).import(
    "format" => 1, "site_url" => "https://example.com", "articles" => [source, target]
  )
  db = SQLite3::Database.new(path)
  db.transaction do
    (3..1000).each do |n|
      id = "%032x" % n
      version = "fixture-version-#{n}"
      route = "Fixture #{n}"
      db.execute("INSERT INTO draft_published_versions SELECT ?, ?, content_hash, body, metadata, ?, created_at, article_created_at FROM draft_published_versions WHERE article_id = ?", [version, id, route, target_id])
      db.execute("INSERT INTO draft_publication_heads SELECT ?, ?, ?, published_at, updated_at FROM draft_publication_heads WHERE article_id = ?", [id, version, version, target_id])
      db.execute("INSERT INTO draft_publication_routes (route, article_id) VALUES (?, ?)", [route, id])
    end
  end
  plan = db.execute("EXPLAIN QUERY PLAN SELECT v.*, h.published_at, h.updated_at FROM draft_publication_routes r JOIN draft_publication_heads h ON h.article_id = r.article_id JOIN draft_published_versions v ON v.id = h.active_id AND v.article_id = h.article_id WHERE r.route IN (?) AND v.route = r.route", ["KORG multi/poly"])
  db.close

  reader = WeblogAuthoring::PublishedArticleReader.new(store:, database: Database.new)
  baseline = Class.new(WeblogAuthoring::PublishedArticleReader) do
    def find_pages_by_routes(_routes) = list_pages
  end.new(store:, database: Database.new)
  page = reader.find(source_id)
  shell = '<html><head><title>weblog.ason.as</title></head><body><div id="authoring-root"></div></body></html>'
  render = lambda do |db_reader|
    WeblogAuthoring::WebmentionSitePublisher.new(database: db_reader, s3_client: nil,
      site_bucket: nil, sqs_client: nil, delivery_queue_url: nil, sender_enabled: false)
      .render_document(page, shell:, source_url: "https://example.com/Source")
  end
  old_html = render.call(baseline)
  new_html = render.call(reader)
  raise "HTML differs" unless old_html == new_html

  results = [baseline, reader].map do |db_reader|
    samples = 5.times.map do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pages = db_reader.find_pages_by_routes(["KORG multi/poly", "未作成"])
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      [elapsed_ms, pages.length, pages.sum { |p| p.body.bytesize }]
    end
    [samples.map(&:first).sort[2].round(3), samples.first[1], samples.first[2]]
  end
  puts({ fixture_articles: 1000, old: results[0], new: results[1], html_sha256: Digest::SHA256.hexdigest(new_html) }.inspect)
  puts({ sqlite_plan: plan.map(&:last) }.inspect)
end
