# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "time"
require_relative "cover_image"

module WeblogAuthoring
  class DraftStore
    class Error < StandardError
      attr_reader :status

      def initialize(message, status = 422)
        super(message)
        @status = status
      end
    end

    BODY_LIMIT = 512 * 1024
    UPDATE_LIMIT = 2 * 1024 * 1024
    CHUNK_BYTES = 128 * 1024
    DEFAULT_METADATA = { "title" => "", "page_type" => "named", "cover_mode" => "auto", "cover_image_url" => nil }.freeze

    def self.sqlite(path)
      require "sqlite3"
      new do |&block|
        connection = SQLite3::Database.new(path.to_s)
        connection.results_as_hash = true
        connection.busy_timeout = 5_000
        block.call(SqliteConnection.new(connection))
      ensure
        connection&.close
      end
    end

    def self.postgres(pool)
      new do |&block|
        pool.with(retry_occ: 3) { |connection| block.call(PostgresConnection.new(connection)) }
      end
    end

    def initialize(&connect)
      @connect = connect
    end

    def setup!
      @connect.call do |db|
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_articles (id TEXT PRIMARY KEY, generation INTEGER NOT NULL, head INTEGER NOT NULL, metadata TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_updates (article_id TEXT NOT NULL, update_id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, fingerprint TEXT NOT NULL, receipt TEXT NOT NULL, chunks INTEGER NOT NULL, PRIMARY KEY (article_id, update_id))")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_chunks (article_id TEXT NOT NULL, update_id TEXT NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, update_id, position))")
      end
    end

    def create(id, payload)
      validate_scope!(id, payload)
      @connect.call do |db|
        db.transaction do
          metadata = DEFAULT_METADATA.transform_values { |value| { "value" => value, "revision" => 0 } }
          now = Time.now.utc.iso8601(6)
          db.query("INSERT INTO #{db.prefix}draft_articles (id, generation, head, metadata, created_at, updated_at) VALUES ($1, 1, 0, $2, $3, $3) ON CONFLICT (id) DO NOTHING", [id, JSON.generate(metadata), now])
          document(db, id)
        end
      end
    end

    def append(id, payload)
      validate_scope!(id, payload)
      update_id = payload["update_id"]
      raise Error, "Invalid update ID" unless update_id.is_a?(String) && /\A[a-zA-Z0-9-]{1,80}\z/.match?(update_id)
      encoded = payload["data"]
      raise Error, "Update exceeds limit" unless encoded.is_a?(String) && encoded.bytesize <= ((UPDATE_LIMIT + 2) / 3) * 4
      data = decode_update(encoded)
      raise Error, "Update exceeds limit" if data.bytesize > UPDATE_LIMIT || data.empty?
      digest = Digest::SHA256.hexdigest(data)
      raise Error, "Update digest mismatch" unless digest == payload["digest"]
      body_bytes = payload["body_bytes"]
      raise Error, "Markdown exceeds 512 KiB" unless body_bytes.is_a?(Integer) && (0..BODY_LIMIT).cover?(body_bytes)
      changes = payload.fetch("metadata", {})
      raise Error, "Invalid metadata" unless changes.is_a?(Hash)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([digest, body_bytes, changes.sort.to_h]))
      @connect.call do |db|
        db.transaction do
          current = document(db, id)
          previous = db.query("SELECT fingerprint, receipt FROM #{db.prefix}draft_updates WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
          if previous
            raise Error.new("Update ID already contains different content", 409) unless previous.fetch("fingerprint") == fingerprint
            next JSON.parse(previous.fetch("receipt"))
          end

          metadata = merge_metadata(current.fetch("metadata"), changes)
          sequence = current.fetch("head") + 1
          now = Time.now.utc.iso8601(6)
          rows = db.query("UPDATE #{db.prefix}draft_articles SET head = $1, metadata = $2, updated_at = $3 WHERE id = $4 AND head = $5 RETURNING head", [sequence, JSON.generate(metadata), now, id, sequence - 1])
          raise Error.new("Draft changed; retry this update", 409) if rows.empty?
          receipt = { "update_id" => update_id, "digest" => digest, "sequence" => sequence, "generation" => 1, "metadata" => metadata }
          chunks = (data.bytesize + CHUNK_BYTES - 1) / CHUNK_BYTES
          chunks.times do |position|
            chunk = Base64.strict_encode64(data.byteslice(position * CHUNK_BYTES, CHUNK_BYTES))
            db.query("INSERT INTO #{db.prefix}draft_chunks (article_id, update_id, position, data) VALUES ($1, $2, $3, $4)", [id, update_id, position, chunk])
          end
          db.query("INSERT INTO #{db.prefix}draft_updates (article_id, update_id, sequence, digest, fingerprint, receipt, chunks) VALUES ($1, $2, $3, $4, $5, $6, $7)", [id, update_id, sequence, digest, fingerprint, JSON.generate(receipt), chunks])
          receipt
        end
      end
    end

    def read(id, query)
      validate_scope!(id, { "generation" => integer(query.fetch("generation", "1")), "protocol" => integer(query.fetch("protocol", "1")) })
      cursor = integer(query.fetch("cursor", "0"))
      @connect.call do |db|
        current = document(db, id)
        high_water = query.key?("through") ? integer(query["through"]) : current.fetch("head")
        raise Error, "Invalid cursor" unless cursor >= 0 && cursor <= high_water && high_water <= current.fetch("head")
        # One complete logical update bounds each page below the Lambda response limit.
        row = db.query("SELECT update_id, sequence, digest, chunks FROM #{db.prefix}draft_updates WHERE article_id = $1 AND sequence > $2 AND sequence <= $3 ORDER BY sequence LIMIT 1", [id, cursor, high_water]).first
        updates = []
        if row
          chunks = db.query("SELECT data FROM #{db.prefix}draft_chunks WHERE article_id = $1 AND update_id = $2 ORDER BY position", [id, row.fetch("update_id")])
          raise Error.new("Incomplete stored update", 503) unless chunks.length == row.fetch("chunks").to_i
          binary = chunks.map { |chunk| Base64.strict_decode64(chunk.fetch("data")) }.join
          raise Error.new("Corrupt stored update", 503) unless Digest::SHA256.hexdigest(binary) == row.fetch("digest")
          cursor = row.fetch("sequence").to_i
          updates << { "sequence" => cursor, "update_id" => row.fetch("update_id"), "digest" => row.fetch("digest"), "data" => Base64.strict_encode64(binary) }
        end
        raise Error.new("Missing stored update", 503) if updates.empty? && cursor < high_water
        current.merge("through" => high_water, "cursor" => cursor, "updates" => updates)
      end
    end

    private

    def decode_update(encoded)
      Base64.strict_decode64(encoded)
    rescue ArgumentError
      raise Error, "Invalid binary encoding"
    end

    def integer(value)
      Integer(value.to_s, 10)
    rescue ArgumentError
      raise Error, "Invalid integer"
    end

    def validate_scope!(id, payload)
      raise Error, "Invalid draft ID" unless /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(id)
      raise Error.new("Unsupported document version", 409) unless payload["generation"] == 1 && payload["protocol"] == 1
    end

    def document(db, id)
      row = db.query("SELECT * FROM #{db.prefix}draft_articles WHERE id = $1", [id]).first
      raise Error.new("Draft not found", 404) unless row
      { "id" => id, "generation" => row.fetch("generation").to_i, "protocol" => 1, "head" => row.fetch("head").to_i,
        "metadata" => JSON.parse(row.fetch("metadata")), "created_at" => row.fetch("created_at"), "updated_at" => row.fetch("updated_at"), }
    end

    def merge_metadata(current, changes)
      changes.each do |field, change|
        raise Error, "Invalid metadata field" unless DEFAULT_METADATA.key?(field) && change.is_a?(Hash) && change.key?("value")
        raise Error.new("Metadata conflict: #{field}", 409) unless current.fetch(field).fetch("revision") == change["expected_revision"]
        value = change.fetch("value")
        raise Error, "Invalid metadata value" unless value.nil? || (value.is_a?(String) && value.bytesize <= 4096)
        raise Error, "Title must be text" if field == "title" && !value.is_a?(String)
        current[field] = { "value" => value, "revision" => current.fetch(field).fetch("revision") + 1 }
      end
      raise Error, "Invalid article type" unless %w[named date].include?(current.dig("page_type", "value"))
      raise Error, "Invalid cover mode" unless CoverImage::MODES.include?(current.dig("cover_mode", "value"))
      CoverImage.validate(current.dig("cover_mode", "value"), current.dig("cover_image_url", "value"))
      current
    end

    class SqliteConnection
      def initialize(connection) = @connection = connection
      def prefix = ""
      def query(sql, values = []) = @connection.execute(sql, values)
      def transaction(&block) = @connection.transaction(:immediate, &block)
    end

    class PostgresConnection
      def initialize(connection) = @connection = connection
      def prefix = "weblog_authoring."
      def query(sql, values = []) = @connection.exec_params(sql, values).to_a
      def transaction(&block) = @connection.transaction(&block)
    end
  end
end
