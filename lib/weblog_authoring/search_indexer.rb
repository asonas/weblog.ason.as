# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "aws-sdk-s3"
require "sqlite3"

module WeblogAuthoring
  class SearchIndexer
    MANIFEST_KEY = "search/manifest.json"

    class QmdRunner
      def build(workdir:, corpus_dir:)
        environment = {
          "HOME" => workdir,
          "PWD" => workdir,
          "XDG_CACHE_HOME" => File.join(workdir, ".cache"),
          "XDG_CONFIG_HOME" => File.join(workdir, ".config"),
        }
        run(environment, workdir, "qmd", "collection", "add", corpus_dir, "--name", "weblog")
        run(environment, workdir, "qmd", "update")

        source = File.join(environment.fetch("XDG_CACHE_HOME"), "qmd", "index.sqlite")
        destination = File.join(workdir, "index.sqlite3")
        database = SQLite3::Database.new(source)
        database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        database.execute("VACUUM INTO ?", destination)
        database.close
        destination
      end

      private

      def run(environment, workdir, *command)
        output, error, status = Open3.capture3(environment, *command, chdir: workdir)
        return if status.success?

        raise "#{command.join(' ')} failed: #{error.empty? ? output : error}"
      end
    end

    def initialize(database:, s3_client:, bucket:, runner: QmdRunner.new, clock: Time.method(:now))
      @database = database
      @s3_client = s3_client
      @bucket = bucket
      @runner = runner
      @clock = clock
    end

    def call
      pages = @database.list_pages.select { |page| page.status == "published" && !page.body.to_s.strip.empty? }
      corpus_hash = corpus_hash(pages)
      current = read_manifest
      return current.merge("status" => "unchanged") if current["corpus_hash"] == corpus_hash

      Dir.mktmpdir("weblog-search-") do |workdir|
        corpus_dir = File.join(workdir, "articles")
        FileUtils.mkdir(corpus_dir)
        write_corpus(pages, corpus_dir)
        index_path = @runner.build(workdir:, corpus_dir:)
        validate_index(index_path, expected_documents: pages.length)
        publish(index_path, corpus_hash, pages.length)
      end
    end

    private

    def corpus_hash(pages)
      records = pages.sort_by(&:id).map do |page|
        [page.id, page.route, page.updated_at&.iso8601, Digest::SHA256.hexdigest(page.body.to_s)]
      end
      Digest::SHA256.hexdigest(JSON.generate(records))
    end

    def read_manifest
      response = @s3_client.get_object(bucket: @bucket, key: MANIFEST_KEY)
      JSON.parse(response.body.read)
    rescue Aws::S3::Errors::NoSuchKey
      {}
    end

    def write_corpus(pages, corpus_dir)
      pages.each do |page|
        content = "# #{page.display_title}\n\nURL: /#{page.route}\n\n#{page.body}\n"
        File.write(File.join(corpus_dir, "#{page.id}.md"), content)
      end
    end

    def validate_index(path, expected_documents:)
      database = SQLite3::Database.new(path, readonly: true)
      result = database.get_first_value("PRAGMA quick_check")
      document_count = database.get_first_value("SELECT COUNT(*) FROM documents WHERE active = 1")
      database.close
      raise "generated search index failed quick_check" unless result == "ok"
      return if document_count == expected_documents

      raise "generated search index contains #{document_count} documents; expected #{expected_documents}"
    end

    def publish(index_path, corpus_hash, document_count)
      index_key = "search/generations/#{corpus_hash}/index.sqlite3"
      File.open(index_path, "rb") do |index|
        @s3_client.put_object(
          bucket: @bucket,
          key: index_key,
          body: index,
          content_type: "application/vnd.sqlite3",
          cache_control: "public, max-age=31536000, immutable"
        )
      end
      manifest = {
        "status" => "published",
        "corpus_hash" => corpus_hash,
        "index_key" => index_key,
        "index_sha256" => Digest::SHA256.file(index_path).hexdigest,
        "document_count" => document_count,
        "generated_at" => @clock.call.iso8601,
      }
      @s3_client.put_object(
        bucket: @bucket,
        key: MANIFEST_KEY,
        body: JSON.generate(manifest),
        content_type: "application/json; charset=utf-8",
        cache_control: "no-cache"
      )
      manifest
    end
  end
end
