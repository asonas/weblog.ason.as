# frozen_string_literal: true

require "tmpdir"
require "sqlite3"
require "json"
require "digest"
require "weblog_authoring/draft_migration"
require "weblog_authoring/published_article_reader"
require "weblog_authoring/lambda_api"

class BaselineConnection < WeblogAuthoring::DraftStore::SqliteConnection
  private

  def published_window_sql(key:, limit:, before:, after:, kind:, month:, timeline:, placeholder:)
    sql = "SELECT v.*, h.published_at, h.updated_at, a.atom_id, #{key} AS listing_key FROM draft_publication_heads h JOIN draft_published_versions v ON v.article_id = h.article_id AND v.id = h.active_id LEFT JOIN draft_atom_ids a ON a.article_id = h.article_id"
    conditions = []
    values = []
    conditions << (kind == "diary" ? "v.body LIKE '%[[日記]]%'" : "v.body NOT LIKE '%[[日記]]%'") if kind
    if month
      conditions << "substr(#{key}, 1, 7) = #{placeholder}"
      values << month
    end
    cursor = before || after
    if cursor
      operator = before ? "<" : ">"
      cursor_key = cursor.fetch(timeline ? :key : :timestamp)
      cursor_key = cursor_key.iso8601 if cursor_key.respond_to?(:iso8601)
      conditions << "(#{key} #{operator} #{placeholder} OR (#{key} = #{placeholder} AND v.article_id #{operator} #{placeholder}))"
      values.concat([cursor_key, cursor_key, cursor.fetch(:id)])
    end
    sql += " WHERE #{conditions.join(' AND ')}" unless conditions.empty?
    sql += " ORDER BY #{key} #{after ? 'ASC' : 'DESC'}, v.article_id #{after ? 'ASC' : 'DESC'}"
    if limit
      sql += " LIMIT #{placeholder}"
      values << limit
    end
    [sql, values]
  end
end

def baseline_store(path)
  WeblogAuthoring::DraftStore.new do |&block|
    connection = SQLite3::Database.new(path)
    connection.results_as_hash = true
    block.call(BaselineConnection.new(connection))
  ensure
    connection&.close
  end
end

def median_ms
  samples = 5.times.map do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  end
  samples.sort[2].round(3)
end

Dir.mktmpdir("list-reads") do |dir|
  path = File.join(dir, "drafts.sqlite3")
  store = WeblogAuthoring::DraftStore.sqlite(path)
  store.setup!
  timestamp = "2026-09-01T00:00:00Z"
  article = lambda do |id, route, body, page_type|
    { "id" => id, "page_type" => page_type, "route" => route, "title" => route,
      "body" => body, "cover_mode" => "none", "cover_image_url" => nil,
      "created_at" => timestamp, "updated_at" => timestamp, "published_at" => timestamp, }
  end
  source_id = "%032x" % 1
  target_id = "%032x" % 2
  source = article.call(source_id, "2026-09-01", "日記 [[日記]]", "date")
  target = article.call(target_id, "Fixture 2", "公開本文" + ("あ" * 400), "named")
  WeblogAuthoring::DraftMigration.new(store:).import(
    "format" => 1, "site_url" => "https://example.com", "articles" => [source, target]
  )
  db = SQLite3::Database.new(path)
  db.transaction do
    (3..1000).each do |n|
      id = "%032x" % n
      version = "fixture-version-#{n}"
      route = "Fixture #{n}"
      body = "公開本文" + ("あ" * 400) + (n % 4 == 0 ? " [[日記]]" : "")
      updated_at = "2026-09-%02dT%02d:00:00Z" % [1 + (n % 28), n % 24]
      db.execute("INSERT INTO draft_published_versions SELECT ?, ?, content_hash, ?, metadata, ?, created_at, article_created_at FROM draft_published_versions WHERE article_id = ?", [version, id, body, route, target_id])
      db.execute("INSERT INTO draft_publication_heads SELECT ?, ?, ?, published_at, ? FROM draft_publication_heads WHERE article_id = ?", [id, version, version, updated_at, target_id])
      db.execute("INSERT INTO draft_publication_routes (route, article_id) VALUES (?, ?)", [route, id])
      db.execute("INSERT INTO draft_atom_ids (article_id, atom_id) VALUES (?, ?)", [id, "https://example.com/#{route}"]) if n % 5 == 0
    end
  end
  db.close
  old_store = baseline_store(path)
  dummy = Object.new
  old_reader = WeblogAuthoring::PublishedArticleReader.new(store: old_store, database: dummy)
  new_reader = WeblogAuthoring::PublishedArticleReader.new(store:, database: dummy)
  old_api = WeblogAuthoring::LambdaApi.new(database: dummy, reader_database: old_reader)
  new_api = WeblogAuthoring::LambdaApi.new(database: dummy, reader_database: new_reader)
  get = lambda do |api, query|
    event = { "requestContext" => { "http" => { "method" => "GET" } }, "rawPath" => "/api/pages", "queryStringParameters" => query }
    response = api.call(event)
    raise "API status #{response.fetch(:statusCode)}" unless response.fetch(:statusCode) == 200
    JSON.parse(response.fetch(:body))
  end
  queries = [{}, { "kind" => "diary" }, { "kind" => "article" }, { "kind" => "timeline", "month" => "2026-09" }, { "kind" => "timeline", "month" => "2026-08" }]
  api_windows = []
  queries.each do |query|
    first = get.call(old_api, query)
    raise "API differs for #{query}" unless first == get.call(new_api, query)
    api_windows << first
    next unless first["older_cursor"]
    older_query = query.merge("before" => first.fetch("older_cursor"))
    older = get.call(old_api, older_query)
    raise "API older page differs for #{query}" unless older == get.call(new_api, older_query)
    api_windows << older
  end
  old_page = old_store.published_pages(limit: 31)
  new_page = store.published_pages(limit: 31)
  raise "Store rows differ" unless old_page == new_page
  old_timeline = old_store.published_timeline_pages(limit: 13, month: "2026-09")
  new_timeline = store.published_timeline_pages(limit: 13, month: "2026-09")
  raise "Timeline rows differ" unless old_timeline == new_timeline
  plan_db = SQLite3::Database.new(path)
  plan_args = { key: "h.updated_at", limit: 31, before: nil, after: nil, kind: nil, month: nil, timeline: false, placeholder: "?" }
  old_sql, old_values = BaselineConnection.new(plan_db).send(:published_window_sql, **plan_args)
  new_sql, new_values = WeblogAuthoring::DraftStore::SqliteConnection.new(plan_db).send(:published_window_sql, **plan_args)
  old_plan = plan_db.execute("EXPLAIN QUERY PLAN #{old_sql}", old_values).map(&:last)
  new_plan = plan_db.execute("EXPLAIN QUERY PLAN #{new_sql}", new_values).map(&:last)
  plan_db.close
  puts JSON.pretty_generate(
    fixture_articles: 1000, api_windows_compared: api_windows.length,
    list: { old_ms: median_ms { old_store.published_pages(limit: 31) }, new_ms: median_ms { store.published_pages(limit: 31) }, returned_rows: new_page.length, returned_body_bytes: new_page.sum { |row| row.fetch("body").bytesize } },
    timeline: { old_ms: median_ms { old_store.published_timeline_pages(limit: 13, month: "2026-09") }, new_ms: median_ms { store.published_timeline_pages(limit: 13, month: "2026-09") }, returned_rows: new_timeline.length, returned_body_bytes: new_timeline.sum { |row| row.fetch("body").bytesize } },
    list_sha256: Digest::SHA256.hexdigest(JSON.generate(new_page)), timeline_sha256: Digest::SHA256.hexdigest(JSON.generate(new_timeline)),
    api_sha256: Digest::SHA256.hexdigest(JSON.generate(api_windows)),
    sqlite_plan: { old: old_plan, new: new_plan }
  )
end
