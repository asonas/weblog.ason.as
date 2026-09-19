# frozen_string_literal: true

require "openssl"
require "securerandom"
require "open3"
require "json"
ENV["PGSSLROOTCERT"] ||= OpenSSL::X509::DEFAULT_CERT_FILE
require "aurora_dsql_pg"
require_relative "../../../lib/weblog_authoring/draft_publication"

SCHEMA = "draft_publish_verify_#{SecureRandom.hex(6)}"
TABLES = %w[draft_articles draft_updates draft_chunks draft_uploads draft_upload_chunks draft_checkpoint_heads draft_checkpoints draft_checkpoint_chunks draft_published_versions draft_publication_jobs draft_publication_heads draft_publication_receipts draft_publication_routes draft_publication_clock draft_publication_stages draft_output_heads draft_html_outputs].freeze
$stdout.sync = true

module IsolatedPublicationSchema
  def prefix = "#{SCHEMA}."

  def query(sql, values = [])
    raise "SQL outside verification schema" unless sql.include?(prefix) && !sql.include?("weblog_authoring.")
    super
  end
end
WeblogAuthoring::DraftStore::PostgresConnection.prepend(IsolatedPublicationSchema)

def check(label)
  raise "FAIL: #{label}" unless yield
  puts "PASS: #{label}"
end

pool = AuroraDsql::Pg.create_pool(host: ENV.fetch("DSQL_HOST"), user: "admin", application_name: "draft-publication-verification", occ_max_retries: 5)
created = false
begin
  pool.with { |connection| connection.exec("CREATE SCHEMA #{SCHEMA}") }
  created = true
  puts "Created isolated schema: #{SCHEMA}"
  store = WeblogAuthoring::DraftStore.postgres(pool)
  store.setup!
  id = SecureRandom.uuid
  scope = { "protocol" => 1, "generation" => 1 }
  store.create(id, scope)
  output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", "history")
  raise error unless status.success?
  JSON.parse(output).each_with_index do |update, index|
    metadata = index.zero? ? { "title" => { "value" => "DSQL公開の確認", "expected_revision" => 0 } } : {}
    store.append(id, scope.merge(update).merge("update_id" => "initial-#{index}", "body_bytes" => 12, "metadata" => metadata))
  end
  publication = WeblogAuthoring::DraftPublication.local(store:)
  request = publication.prepare(id).merge("request_id" => "same-request")
  results = 4.times.map { Thread.new { publication.accept(id, request) } }.map(&:value)
  check("concurrent retries share one immutable version") { results.uniq.length == 1 }
  version = results.first.fetch("id")
  check("acceptance does not activate") { store.published_snapshot(id).nil? }
  publication.complete(id, version) { "published/#{id}/#{version}.html" }
  active = store.published_snapshot(id)
  check("confirmed persisted Y.Text is active") { active.fetch("body") == "残す" }
  check("identical content is a no-op") { publication.accept(id, publication.prepare(id).merge("request_id" => "identical")).fetch("status") == "unchanged" }
  check("no-op retains publication timestamps") { store.published_snapshot(id) == active }
  change = scope.merge("update_id" => "cover-change", "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 6,
    "metadata" => { "cover_mode" => { "value" => "none", "expected_revision" => 0 } })
  stale = publication.prepare(id).merge("request_id" => "stale")
  store.append(id, change)
  begin
    publication.accept(id, stale)
    raise "Stale content published"
  rescue WeblogAuthoring::DraftStore::Error => error
    check("changed head rejects publication") { error.status == 409 }
  end
  second = publication.accept(id, publication.prepare(id).merge("request_id" => "second"))
  publication.complete(id, second.fetch("id")) do
    store.append(id, change.merge("update_id" => "newer-cover", "metadata" => { "cover_mode" => { "value" => "explicit", "expected_revision" => 1 }, "cover_image_url" => { "value" => "/assets/cover.jpg", "expected_revision" => 0 } }))
    third = publication.accept(id, publication.prepare(id).merge("request_id" => "third"))
    publication.complete(id, third.fetch("id")) { "published/#{id}/#{third.fetch('id')}.html" }
    "published/#{id}/#{second.fetch('id')}.html"
  end
  check("old completion cannot replace newer publication") { store.publication_job(id, second.fetch("id")).fetch("status") == "superseded" && store.published_snapshot(id).dig("metadata", "cover_mode") == "explicit" }
  check("first publication time is preserved") { store.published_snapshot(id).fetch("published_at") == active.fetch("published_at") }
  now = Time.now.utc
  current_id = store.published_snapshot(id).fetch("id")
  store.record_publication_html(id, current_id, { "html_key" => "test/current.html", "html_digest" => "b" * 64 })
  check("HTML repair pointer follows the active version") { store.published_snapshot(id).fetch("html_key") == "test/current.html" }
  check("old HTML repair cannot replace the active pointer") { !store.record_publication_html(id, second.fetch("id"), { "html_key" => "test/old.html", "html_digest" => "c" * 64 }) }
  claim = store.begin_publication_stage(id, current_id, "atom", now:)
  collection = store.published_collection
  store.complete_publication_stage(claim, now:, output: { "revision" => collection.fetch("revision"), "object_key" => "test/feed.xml", "digest" => "a" * 64 })
  check("derived pointer and completed stage commit atomically") { store.output_head("atom").fetch("revision").to_i == collection.fetch("revision") && store.publication_stages(id, current_id).first.fetch("status") == "completed" }
  failed = store.begin_publication_stage(id, current_id, "search", now:)
  store.fail_publication_stage(failed, "temporary failure", now:)
  check("backoff defers a stage") { store.begin_publication_stage(id, current_id, "search", now:).nil? }
  store.cleanup_publication_stages(now: now + (31 * 86400))
  check("unfinished stage survives retention") { store.publication_stages(id, current_id).any? { |stage| stage.fetch("status") == "retry_wait" } }
  begin
    store.publication_job(id, second.fetch("id"))
    raise "Expired job retained"
  rescue WeblogAuthoring::DraftStore::Error => error
    check("completed old jobs expire without removing snapshots") { error.status == 404 && store.publication_snapshot(id, second.fetch("id")).fetch("id") == second.fetch("id") }
  end
  store.supersede_publication_stages(id, now:)
ensure
  if created
    pool.with do |connection|
      tables = connection.exec_params("SELECT table_name FROM information_schema.tables WHERE table_schema = $1", [SCHEMA]).map { |row| row.fetch("table_name") }
      raise "Unexpected verification tables; refusing cleanup" unless (tables - TABLES).empty?
      tables.each { |table| connection.exec("DROP TABLE #{SCHEMA}.#{table}") }
      connection.exec("DROP SCHEMA #{SCHEMA}")
      check("isolated schema removed") { connection.exec_params("SELECT schema_name FROM information_schema.schemata WHERE schema_name = $1", [SCHEMA]).ntuples.zero? }
    end
  end
  pool.shutdown
end
