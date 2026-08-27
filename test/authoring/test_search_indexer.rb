# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/search_indexer"

class SearchIndexerTest < Minitest::Test
  Page = Data.define(:id, :route, :display_title, :status, :updated_at, :body)

  class FakeS3
    ObjectBody = Data.define(:body)

    attr_reader :objects, :puts

    def initialize
      @objects = {}
      @puts = []
    end

    def get_object(bucket:, key:)
      value = objects[[bucket, key]]
      raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") if value.nil?

      ObjectBody.new(StringIO.new(value))
    end

    def put_object(**request)
      body = request.fetch(:body)
      body = body.read if body.respond_to?(:read)
      objects[[request.fetch(:bucket), request.fetch(:key)]] = body
      puts << request.merge(body:)
    end
  end

  class FakeRunner
    attr_reader :corpus_files

    def initialize(fail: false)
      @fail = fail
    end

    def build(workdir:, corpus_dir:)
      raise "qmd failed" if @fail

      @corpus_files = Dir.children(corpus_dir).sort.map { |name| File.read(File.join(corpus_dir, name)) }
      database = SQLite3::Database.new(File.join(workdir, "index.sqlite3"))
      database.execute("CREATE TABLE documents (id TEXT PRIMARY KEY, active INTEGER NOT NULL)")
      database.execute("INSERT INTO documents VALUES ('page-id', 1)")
      database.close
      File.join(workdir, "index.sqlite3")
    end
  end

  def setup
    @page = Page.new(
      id: "page-id",
      route: "2026-08-27",
      display_title: "2026-08-27",
      status: "published",
      updated_at: Time.iso8601("2026-08-27T12:00:00+09:00"),
      body: "検索できる本文"
    )
    @database = Object.new
    @database.define_singleton_method(:list_pages) { [@page] }
    @database.instance_variable_set(:@page, @page)
    @s3 = FakeS3.new
  end

  def test_publishes_an_immutable_generation_before_the_manifest
    runner = FakeRunner.new
    result = indexer(runner:).call

    assert_equal "published", result.fetch("status")
    assert_equal 1, result.fetch("document_count")
    assert_includes runner.corpus_files.fetch(0), "# 2026-08-27"
    assert_includes runner.corpus_files.fetch(0), "検索できる本文"

    generation, manifest = @s3.puts
    assert_match(%r{\Asearch/generations/[0-9a-f]{64}/index\.sqlite3\z}, generation.fetch(:key))
    assert_equal "public, max-age=31536000, immutable", generation.fetch(:cache_control)
    assert_equal "search/manifest.json", manifest.fetch(:key)
    assert_equal "no-cache", manifest.fetch(:cache_control)
    manifest_body = JSON.parse(manifest.fetch(:body))
    assert_equal generation.fetch(:key), manifest_body.fetch("index_key")
    assert_equal Digest::SHA256.hexdigest(generation.fetch(:body)), manifest_body.fetch("index_sha256")
  end

  def test_skips_qmd_when_the_published_corpus_is_unchanged
    first = indexer(runner: FakeRunner.new).call
    @s3.objects[["site", "search/manifest.json"]] = JSON.generate(first)
    runner = Object.new
    runner.define_singleton_method(:build) { raise "must not run" }

    result = indexer(runner:).call

    assert_equal "unchanged", result.fetch("status")
    assert_empty @s3.puts.drop(2)
  end

  def test_keeps_the_previous_manifest_when_qmd_fails
    old_manifest = JSON.generate("corpus_hash" => "old", "index_key" => "search/generations/old/index.sqlite3")
    @s3.objects[["site", "search/manifest.json"]] = old_manifest

    assert_raises(RuntimeError) { indexer(runner: FakeRunner.new(fail: true)).call }

    assert_equal old_manifest, @s3.objects[["site", "search/manifest.json"]]
    assert_empty @s3.puts
  end

  private

  def indexer(runner:)
    WeblogAuthoring::SearchIndexer.new(
      database: @database,
      s3_client: @s3,
      bucket: "site",
      runner:,
      clock: -> { Time.iso8601("2026-08-27T13:00:00+09:00") }
    )
  end
end
