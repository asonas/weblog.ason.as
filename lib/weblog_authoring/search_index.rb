# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "sqlite3"
require "aws-sdk-s3"

module WeblogAuthoring
  class SearchIndex
    class Unavailable < StandardError; end
    Result = Data.define(:results, :generated_at)

    MANIFEST_KEY = "search/manifest.json"
    QUERY = <<~SQL
      SELECT p.route, p.title, p.updated_at, c.doc AS body
      FROM documents_fts
      JOIN documents AS documents ON documents.id = documents_fts.rowid
      JOIN content AS c ON c.hash = documents.hash
      JOIN weblog_pages AS p ON p.document_id = documents.id
      WHERE documents_fts MATCH ? AND documents.active = 1
      ORDER BY bm25(documents_fts, 0.0, 5.0, 1.0) ASC, p.updated_at DESC
      LIMIT ?
    SQL

    def initialize(s3_client:, bucket:, cache_dir: "/tmp/search-index")
      @s3_client = s3_client
      @bucket = bucket
      @cache_dir = cache_dir
    end

    def search(query:, limit:)
      refresh
      expression = fts_query(query)
      return Result.new(results: [], generated_at: @generated_at) if expression.nil?

      results = @database.execute(QUERY, [expression, limit]).map do |row|
        {
          "route" => row.fetch("route"),
          "title" => row.fetch("title"),
          "excerpt" => excerpt(row.fetch("body"), query),
          "updated_at" => row.fetch("updated_at"),
        }
      end
      Result.new(results:, generated_at: @generated_at)
    end

    private

    def refresh
      manifest = read_manifest
      corpus_hash = manifest.fetch("corpus_hash")
      return if @corpus_hash == corpus_hash

      FileUtils.mkdir_p(@cache_dir)
      path = File.join(@cache_dir, "#{corpus_hash}.sqlite3")
      download(path, manifest) unless valid_checksum?(path, manifest.fetch("index_sha256"))
      database = SQLite3::Database.new("file:#{path}?mode=ro&immutable=1", uri: true)
      database.results_as_hash = true
      database.execute("PRAGMA query_only = ON")
      database.get_first_value("SELECT COUNT(*) FROM weblog_pages")
      @database&.close
      @database = database
      @corpus_hash = corpus_hash
      @generated_at = manifest.fetch("generated_at")
    rescue KeyError, JSON::ParserError, SQLite3::Exception, Aws::S3::Errors::ServiceError, Unavailable => error
      raise Unavailable, error.message if @database.nil?
    end

    def read_manifest
      response = @s3_client.get_object(bucket: @bucket, key: MANIFEST_KEY)
      JSON.parse(response.body.read)
    end

    def download(path, manifest)
      temporary = "#{path}.download"
      @s3_client.get_object(bucket: @bucket, key: manifest.fetch("index_key"), response_target: temporary)
      raise Unavailable, "search index checksum mismatch" unless valid_checksum?(temporary, manifest.fetch("index_sha256"))

      File.rename(temporary, path)
    ensure
      File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
    end

    def valid_checksum?(path, expected)
      File.file?(path) && Digest::SHA256.file(path).hexdigest == expected
    end

    def fts_query(query)
      if query.match?(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/)
        tokens = query.scan(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]|[^\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+/)
          .flat_map { |part| part.match?(/\A[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+\z/) ? part.chars : part.split }
          .filter_map { |token| search_token(token) }
        %Q("#{tokens.join(" ")}")
      else
        tokens = query.scan(/[\p{L}\p{N}'_]+/).filter_map { |token| search_token(token) }
        tokens.empty? ? nil : %Q("#{tokens.join(" ")}"*)
      end
    end

    def search_token(token)
      token.downcase.gsub(/[^\p{L}\p{N}'_]/, "").then { |value| value unless value.empty? }
    end

    def excerpt(body, query)
      text = body.gsub(/\s+/, " ").strip
      match = text.downcase.index(query.downcase) || 0
      start = [match - 60, 0].max
      value = text.slice(start, 160).to_s
      value = "…#{value}" if start.positive?
      value += "…" if start + 160 < text.length
      value
    end
  end
end
