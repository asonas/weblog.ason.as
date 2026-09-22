# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "time"
require_relative "cover_image"
require_relative "draft_publications"
require_relative "draft_output_store"
require_relative "draft_renames"
require_relative "draft_migration_store"
require_relative "draft_cutover_store"
require_relative "draft_dispatches"

module WeblogAuthoring
  class DraftStore
    include DraftPublications
    include DraftOutputStore
    include DraftRenames
    include DraftMigrationStore
    include DraftCutoverStore
    include DraftDispatches
    class Error < StandardError
      attr_reader :status

      def initialize(message, status = 422)
        super(message)
        @status = status
      end
    end

    class CutoverError < Error
      attr_reader :code

      def initialize(code)
        @code = code
        if code == "upgrade_required"
          super("この編集画面からは保存できません。編集中の内容を退避して、新しい編集画面を開いてください。", 409)
        else
          super("保存・公開を一時停止しています。編集中の内容を保持してお待ちください。", 503)
        end
      end
    end

    BODY_LIMIT = 512 * 1024
    UPDATE_LIMIT = 2 * 1024 * 1024
    CHECKPOINT_LIMIT = 16 * 1024 * 1024
    CHUNK_BYTES = 128 * 1024
    TRANSPORT_CHUNK_BYTES = 256 * 1024
    DEFAULT_METADATA = { "title" => "", "page_type" => "named", "page_date" => "", "cover_mode" => "auto", "cover_image_url" => nil }.freeze

    def self.working_route(metadata)
      metadata.fetch("title")
    end

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
        setup_publications(db)
        setup_outputs(db)
        setup_renames(db)
        setup_migration(db)
        setup_dispatches(db)
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_articles (id TEXT PRIMARY KEY, generation INTEGER NOT NULL, head INTEGER NOT NULL, metadata TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_updates (article_id TEXT NOT NULL, update_id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, fingerprint TEXT NOT NULL, receipt TEXT NOT NULL, chunks INTEGER NOT NULL, PRIMARY KEY (article_id, update_id))")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_chunks (article_id TEXT NOT NULL, update_id TEXT NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, update_id, position))")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_uploads (article_id TEXT NOT NULL, update_id TEXT NOT NULL, digest TEXT NOT NULL, fingerprint TEXT NOT NULL, body_bytes INTEGER NOT NULL, metadata TEXT NOT NULL, chunks INTEGER NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (article_id, update_id))")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_upload_chunks (article_id TEXT NOT NULL, update_id TEXT NOT NULL, position INTEGER NOT NULL, digest TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, update_id, position))")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_checkpoint_heads (article_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL)")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_checkpoints (article_id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, chunks INTEGER NOT NULL, activated_at TEXT NOT NULL, PRIMARY KEY (article_id, sequence))")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_checkpoint_chunks (article_id TEXT NOT NULL, sequence INTEGER NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, sequence, position))")
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
      encoded = payload["data"]
      raise Error, "Update exceeds limit" unless encoded.is_a?(String) && encoded.bytesize <= ((UPDATE_LIMIT + 2) / 3) * 4
      data = decode_update(encoded)
      append_data(id, payload, data)
    end

    def administration_page(cursor = nil)
      @connect.call do |db|
        sql = "SELECT a.id, a.head, a.metadata, a.created_at, a.updated_at, h.latest_id, v.route AS public_route, v.content_hash AS public_hash FROM #{db.prefix}draft_articles a LEFT JOIN #{db.prefix}draft_publication_heads h ON h.article_id = a.id LEFT JOIN #{db.prefix}draft_published_versions v ON v.id = h.active_id"
        params = []
        if cursor
          sql += " WHERE a.updated_at < $1 OR (a.updated_at = $1 AND a.id > $2)"
          params = [cursor.fetch("updated_at"), cursor.fetch("id")]
        end
        sql += " ORDER BY a.updated_at DESC, a.id LIMIT 26"
        db.query(sql, params).map do |row|
          row.merge("head" => row.fetch("head").to_i, "metadata" => JSON.parse(row.fetch("metadata")))
        end
      end
    end

    def daily_draft(date)
      @connect.call do |db|
        db.transaction do
          owner = db.query(<<~SQL, [date]).first
            SELECT routes.article_id
            FROM #{db.prefix}draft_publication_routes routes
            JOIN #{db.prefix}draft_publication_heads heads ON heads.article_id = routes.article_id
            JOIN #{db.prefix}draft_published_versions versions ON versions.id = heads.active_id
            WHERE routes.route = $1 AND versions.route = $1
          SQL
          next owner.fetch("article_id") if owner
          cursor = ""
          found = nil
          loop do
            rows = db.query("SELECT id, metadata FROM #{db.prefix}draft_articles WHERE id > $1 ORDER BY id LIMIT 25", [cursor])
            found = rows.find do |row|
              metadata = JSON.parse(row.fetch("metadata")).transform_values { |field| field.fetch("value") }
              metadata["page_type"] == "date" && self.class.working_route(metadata) == date
            end
            break if found || rows.length < 25
            cursor = rows.last.fetch("id")
          end
          next found.fetch("id") if found
          metadata = DEFAULT_METADATA.merge("title" => date, "page_type" => "date", "page_date" => date).transform_values { |value| { "value" => value, "revision" => 0 } }
          now = Time.now.utc.iso8601(6)
          attempt = 0
          loop do
            hex = Digest::SHA256.hexdigest("draft-diary:#{date}:#{attempt}")[0, 32]
            id = [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
            db.query("INSERT INTO #{db.prefix}draft_articles (id, generation, head, metadata, created_at, updated_at) VALUES ($1, 1, 0, $2, $3, $3) ON CONFLICT (id) DO NOTHING", [id, JSON.generate(metadata), now])
            stored = document(db, id).fetch("metadata").transform_values { |field| field.fetch("value") }
            break id if stored["page_type"] == "date" && self.class.working_route(stored) == date
            # A previous daily draft may have been renamed before publication.
            attempt += 1
          end
        end
      end
    end

    def begin_upload(id, payload)
      validate_scope!(id, payload)
      update_id, digest, body_bytes, changes = validate_update_manifest(payload)
      chunks = payload["chunks"]
      max_chunks = (UPDATE_LIMIT + TRANSPORT_CHUNK_BYTES - 1) / TRANSPORT_CHUNK_BYTES
      raise Error, "Invalid upload manifest" unless chunks.is_a?(Integer) && (1..max_chunks).cover?(chunks)
      fingerprint = update_fingerprint(digest, body_bytes, changes)
      @connect.call do |db|
        document(db, id)
        previous = db.query("SELECT fingerprint, receipt FROM #{db.prefix}draft_updates WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
        if previous
          raise Error.new("Update ID already contains different content", 409) unless previous.fetch("fingerprint") == fingerprint
          next JSON.parse(previous.fetch("receipt"))
        end
        inserted = db.query("INSERT INTO #{db.prefix}draft_uploads (article_id, update_id, digest, fingerprint, body_bytes, metadata, chunks, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (article_id, update_id) DO NOTHING RETURNING update_id", [id, update_id, digest, fingerprint, body_bytes, JSON.generate(changes), chunks, Time.now.utc.iso8601(6)])
        if inserted.empty?
          stored = db.query("SELECT digest, fingerprint, body_bytes, metadata, chunks FROM #{db.prefix}draft_uploads WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
          unless stored && stored.fetch("digest") == digest && stored.fetch("fingerprint") == fingerprint && stored.fetch("body_bytes").to_i == body_bytes && stored.fetch("metadata") == JSON.generate(changes) && stored.fetch("chunks").to_i == chunks
            raise Error.new("Upload manifest already contains different content", 409)
          end
        end
        { "update_id" => update_id, "digest" => digest, "chunks" => chunks }
      end
    end

    def upload_chunk(id, update_id, position, payload)
      validate_scope!(id, payload)
      validate_update_id!(update_id)
      position = integer(position)
      encoded = payload["data"]
      raise Error, "Upload chunk exceeds limit" unless encoded.is_a?(String) && encoded.bytesize <= ((TRANSPORT_CHUNK_BYTES + 2) / 3) * 4
      data = decode_update(encoded)
      raise Error, "Upload chunk exceeds limit" if data.empty? || data.bytesize > TRANSPORT_CHUNK_BYTES
      digest = Digest::SHA256.hexdigest(data)
      raise Error, "Upload chunk digest mismatch" unless digest == payload["digest"]
      @connect.call do |db|
        manifest = db.query("SELECT chunks FROM #{db.prefix}draft_uploads WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
        raise Error.new("Upload manifest not found", 404) unless manifest
        raise Error, "Invalid upload chunk position" unless (0...manifest.fetch("chunks").to_i).cover?(position)
        inserted = db.query("INSERT INTO #{db.prefix}draft_upload_chunks (article_id, update_id, position, digest, data) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (article_id, update_id, position) DO NOTHING RETURNING position", [id, update_id, position, digest, Base64.strict_encode64(data)])
        if inserted.empty?
          stored = db.query("SELECT digest, data FROM #{db.prefix}draft_upload_chunks WHERE article_id = $1 AND update_id = $2 AND position = $3", [id, update_id, position]).first
          unless stored && stored.fetch("digest") == digest && stored.fetch("data") == Base64.strict_encode64(data)
            raise Error.new("Upload chunk already contains different content", 409)
          end
        end
        { "update_id" => update_id, "position" => position, "digest" => digest }
      end
    end

    def commit_upload(id, update_id, payload)
      validate_scope!(id, payload)
      validate_update_id!(update_id)
      manifest, data = @connect.call do |db|
        stored = db.query("SELECT digest, body_bytes, metadata, chunks FROM #{db.prefix}draft_uploads WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
        unless stored
          receipt = db.query("SELECT receipt FROM #{db.prefix}draft_updates WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
          next [JSON.parse(receipt.fetch("receipt")), nil] if receipt
          raise Error.new("Upload manifest not found", 404)
        end
        chunks = db.query("SELECT position, digest, data FROM #{db.prefix}draft_upload_chunks WHERE article_id = $1 AND update_id = $2 ORDER BY position", [id, update_id])
        expected = stored.fetch("chunks").to_i
        raise Error.new("Upload is incomplete", 409) unless chunks.map { |chunk| chunk.fetch("position").to_i } == (0...expected).to_a
        binary = chunks.map do |chunk|
          decoded = decode_update(chunk.fetch("data"))
          raise Error.new("Upload chunk digest mismatch", 409) unless Digest::SHA256.hexdigest(decoded) == chunk.fetch("digest")
          decoded
        end.join
        raise Error.new("Update exceeds limit", 409) if binary.empty? || binary.bytesize > UPDATE_LIMIT
        raise Error.new("Update digest mismatch", 409) unless Digest::SHA256.hexdigest(binary) == stored.fetch("digest")
        [{ "protocol" => 1, "generation" => 1, "update_id" => update_id, "digest" => stored.fetch("digest"),
           "body_bytes" => stored.fetch("body_bytes").to_i, "metadata" => JSON.parse(stored.fetch("metadata")), }, binary,]
      end
      return manifest unless data

      receipt = append_data(id, manifest, data)
      @connect.call do |db|
        db.query("DELETE FROM #{db.prefix}draft_upload_chunks WHERE article_id = $1 AND update_id = $2", [id, update_id])
        db.query("DELETE FROM #{db.prefix}draft_uploads WHERE article_id = $1 AND update_id = $2", [id, update_id])
      end
      receipt
    end

    def append_data(id, payload, data)
      update_id, digest, body_bytes, changes = validate_update_manifest(payload)
      raise Error, "Update exceeds limit" if data.bytesize > UPDATE_LIMIT || data.empty?
      raise Error, "Update digest mismatch" unless Digest::SHA256.hexdigest(data) == digest
      fingerprint = update_fingerprint(digest, body_bytes, changes)
      @connect.call do |db|
        db.transaction do
          current = document(db, id)
          previous = db.query("SELECT fingerprint, receipt FROM #{db.prefix}draft_updates WHERE article_id = $1 AND update_id = $2", [id, update_id]).first
          if previous
            raise Error.new("Update ID already contains different content", 409) unless previous.fetch("fingerprint") == fingerprint
            next JSON.parse(previous.fetch("receipt"))
          end

          metadata = merge_metadata(current.fetch("metadata"), changes)
          if (changes.keys & %w[title page_type page_date]).any? && db.query("SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $1 AND active_id IS NOT NULL", [id]).any?
            reserve_working_route(db, id, self.class.working_route(metadata.transform_values { |field| field.fetch("value") }))
          end
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
    private :append_data

    def read(id, query)
      validate_scope!(id, { "generation" => integer(query.fetch("generation", "1")), "protocol" => integer(query.fetch("protocol", "1")) })
      cursor = integer(query.fetch("cursor", "0"))
      @connect.call do |db|
        current = document(db, id)
        high_water = query.key?("through") ? integer(query["through"]) : current.fetch("head")
        raise Error, "Invalid cursor" unless cursor >= 0 && cursor <= high_water && high_water <= current.fetch("head")
        checkpoint = if query.key?("checkpoint_through")
                       checkpoint_manifest_at(db, id, integer(query.fetch("checkpoint_through")))
                     else
                       active_checkpoint_manifest(db, id)
                     end
        if checkpoint && checkpoint.fetch("through") > cursor && checkpoint.fetch("through") <= high_water
          position = integer(query.fetch("checkpoint_position", "0"))
          chunks = (checkpoint.fetch("chunks") + 1) / 2
          data = checkpoint_transport_chunk(db, id, checkpoint.fetch("through"), checkpoint.fetch("chunks"), position)
          return current.merge("through" => high_water, "cursor" => cursor, "updates" => [],
                               "checkpoint" => checkpoint.slice("through", "digest").merge("chunks" => chunks, "position" => position, "data" => data))
        end
        raise Error.new("Checkpoint is unavailable", 409) if query.key?("checkpoint_through")
        # One complete logical update bounds each page below the Lambda response limit.
        row = db.query("SELECT update_id, sequence, digest, chunks FROM #{db.prefix}draft_updates WHERE article_id = $1 AND sequence > $2 AND sequence <= $3 ORDER BY sequence LIMIT 1", [id, cursor, high_water]).first
        updates = []
        if row
          chunks = db.query("SELECT data FROM #{db.prefix}draft_chunks WHERE article_id = $1 AND update_id = $2 ORDER BY position", [id, row.fetch("update_id")])
          unless chunks.length == row.fetch("chunks").to_i
            status = checkpoint && row.fetch("sequence").to_i <= checkpoint.fetch("through") ? 410 : 503
            raise Error.new(status == 410 ? "Stored history was compacted" : "Incomplete stored update", status)
          end
          binary = chunks.map { |chunk| Base64.strict_decode64(chunk.fetch("data")) }.join
          raise Error.new("Corrupt stored update", 503) unless Digest::SHA256.hexdigest(binary) == row.fetch("digest")
          cursor = row.fetch("sequence").to_i
          updates << { "sequence" => cursor, "update_id" => row.fetch("update_id"), "digest" => row.fetch("digest"), "data" => Base64.strict_encode64(binary) }
        end
        raise Error.new("Missing stored update", 503) if updates.empty? && cursor < high_water
        current.merge("through" => high_water, "cursor" => cursor, "updates" => updates)
      end
    end

    def checkpoint_job(id)
      validate_scope!(id, { "generation" => 1, "protocol" => 1 })
      @connect.call do |db|
        db.transaction do
          current = document(db, id)
          checkpoint = stored_checkpoint(db, id)
          { "article_id" => id, "generation" => current.fetch("generation"), "protocol" => 1,
            "metadata" => current.fetch("metadata"),
            "through" => current.fetch("head"), "expected_checkpoint" => checkpoint ? checkpoint.fetch("through") : 0,
            "checkpoint" => checkpoint, }
        end
      end
    end

    # The block invokes trusted reconstruction outside database transactions.
    def compact(id)
      job = checkpoint_job(id)
      cursor = job.fetch("expected_checkpoint")
      updates = []
      bytes = 0
      while cursor < job.fetch("through")
        page = read(id, { "cursor" => cursor.to_s, "through" => job.fetch("through").to_s })
        page.fetch("updates").each do |update|
          bytes += Base64.strict_decode64(update.fetch("data")).bytesize
          updates << update
        end
        cursor = page.fetch("cursor")
      end
      return nil if updates.length < 1_000 && bytes < 1024 * 1024

      verified = yield job.merge("updates" => updates)
      raise Error, "Worker returned a different checkpoint range" unless verified.fetch("through") == job.fetch("through")
      activate_verified_checkpoint(id, verified, expected_checkpoint: job.fetch("expected_checkpoint"))
    end

    def cleanup_compacted(id, now: Time.now.utc)
      validate_scope!(id, { "generation" => 1, "protocol" => 1 })
      @connect.call do |db|
        checkpoint = active_checkpoint_manifest(db, id)
        next 0 unless checkpoint && Time.iso8601(checkpoint.fetch("activated_at")) <= now - (7 * 24 * 60 * 60)

        updates = db.query("SELECT update_id FROM #{db.prefix}draft_updates WHERE article_id = $1 AND sequence <= $2", [id, checkpoint.fetch("through")])
        updates.sum do |update|
          db.query("DELETE FROM #{db.prefix}draft_chunks WHERE article_id = $1 AND update_id = $2 RETURNING position", [id, update.fetch("update_id")]).length
        end
      end
    end

    # Internal-only: payload must come from trusted reconstruction, never a browser request.
    def activate_verified_checkpoint(id, payload, expected_checkpoint:)
      validate_scope!(id, payload)
      raise Error, "Checkpoint article mismatch" unless payload["article_id"] == id
      sequence = payload["through"]
      raise Error, "Invalid checkpoint sequence" unless sequence.is_a?(Integer) && sequence.positive? && expected_checkpoint.is_a?(Integer) && expected_checkpoint >= 0 && expected_checkpoint < sequence
      encoded = payload["data"]
      raise Error, "Checkpoint exceeds limit" unless encoded.is_a?(String) && encoded.bytesize <= ((CHECKPOINT_LIMIT + 2) / 3) * 4
      data = decode_update(encoded)
      raise Error, "Checkpoint exceeds limit" if data.empty? || data.bytesize > CHECKPOINT_LIMIT
      digest = Digest::SHA256.hexdigest(data)
      raise Error, "Checkpoint digest mismatch" unless digest == payload["digest"]
      @connect.call do |db|
        current = document(db, id)
        raise Error.new("Checkpoint exceeds document head", 409) if sequence > current.fetch("head")
        active = stored_checkpoint(db, id)
        if active && active.fetch("through") == sequence
          raise Error.new("Checkpoint content changed", 409) unless active.fetch("digest") == digest
          next active
        end
        active_sequence = active ? active.fetch("through") : 0
        raise Error.new("Checkpoint changed; reconstruct again", 409) unless active_sequence == expected_checkpoint
        chunks = (data.bytesize + CHUNK_BYTES - 1) / CHUNK_BYTES
        # Each immutable chunk commits separately to stay below DSQL's 10 MiB write limit.
        chunks.times do |position|
          chunk = Base64.strict_encode64(data.byteslice(position * CHUNK_BYTES, CHUNK_BYTES))
          inserted = db.query("INSERT INTO #{db.prefix}draft_checkpoint_chunks (article_id, sequence, position, data) VALUES ($1, $2, $3, $4) ON CONFLICT (article_id, sequence, position) DO NOTHING RETURNING position", [id, sequence, position, chunk])
          next unless inserted.empty?
          stored = db.query("SELECT data FROM #{db.prefix}draft_checkpoint_chunks WHERE article_id = $1 AND sequence = $2 AND position = $3", [id, sequence, position]).first
          raise Error.new("Staged checkpoint content changed", 409) unless stored && stored.fetch("data") == chunk
        end
        db.transaction do
          active = stored_checkpoint(db, id)
          if active && active.fetch("through") == sequence
            raise Error.new("Checkpoint content changed", 409) unless active.fetch("digest") == digest
            next active
          end
          active_sequence = active ? active.fetch("through") : 0
          raise Error.new("Checkpoint changed; reconstruct again", 409) unless active_sequence == expected_checkpoint
          checkpoint_data(db, id, sequence, chunks, digest)
          db.query("INSERT INTO #{db.prefix}draft_checkpoint_heads (article_id, sequence) VALUES ($1, 0) ON CONFLICT (article_id) DO NOTHING", [id])
          rows = db.query("UPDATE #{db.prefix}draft_checkpoint_heads SET sequence = $1 WHERE article_id = $2 AND sequence = $3 RETURNING sequence", [sequence, id, expected_checkpoint])
          raise Error.new("Checkpoint changed; reconstruct again", 409) if rows.empty?
          now = Time.now.utc.iso8601(6)
          db.query("INSERT INTO #{db.prefix}draft_checkpoints (article_id, sequence, digest, chunks, activated_at) VALUES ($1, $2, $3, $4, $5)", [id, sequence, digest, chunks, now])
          { "through" => sequence, "digest" => digest, "data" => encoded, "activated_at" => now }
        end
      end
    end

    private

    def validate_update_manifest(payload)
      update_id = payload["update_id"]
      validate_update_id!(update_id)
      digest = payload["digest"]
      raise Error, "Invalid update digest" unless digest.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(digest)
      body_bytes = payload["body_bytes"]
      raise Error, "Markdown exceeds 512 KiB" unless body_bytes.is_a?(Integer) && (0..BODY_LIMIT).cover?(body_bytes)
      changes = payload.fetch("metadata", {})
      raise Error, "Invalid metadata" unless changes.is_a?(Hash)
      [update_id, digest, body_bytes, changes]
    end

    def validate_update_id!(update_id)
      raise Error, "Invalid update ID" unless update_id.is_a?(String) && /\A[a-zA-Z0-9-]{1,80}\z/.match?(update_id)
    end

    def update_fingerprint(digest, body_bytes, changes)
      Digest::SHA256.hexdigest(JSON.generate([digest, body_bytes, changes.sort.to_h]))
    end

    def stored_checkpoint(db, id)
      manifest = active_checkpoint_manifest(db, id)
      return nil unless manifest

      encoded = checkpoint_data(db, id, manifest.fetch("through"), manifest.fetch("chunks"), manifest.fetch("digest"))
      manifest.slice("through", "digest", "activated_at").merge("data" => encoded)
    end

    def active_checkpoint_manifest(db, id)
      pointer = db.query("SELECT sequence FROM #{db.prefix}draft_checkpoint_heads WHERE article_id = $1", [id]).first
      return nil unless pointer && pointer.fetch("sequence").to_i.positive?
      sequence = pointer.fetch("sequence").to_i
      checkpoint_manifest_at(db, id, sequence) || raise(Error.new("Missing checkpoint manifest", 503))
    end

    def checkpoint_manifest_at(db, id, sequence)
      row = db.query("SELECT digest, chunks, activated_at FROM #{db.prefix}draft_checkpoints WHERE article_id = $1 AND sequence = $2", [id, sequence]).first
      return nil unless row
      { "through" => sequence, "digest" => row.fetch("digest"), "chunks" => row.fetch("chunks").to_i, "activated_at" => row.fetch("activated_at") }
    end

    def checkpoint_transport_chunk(db, id, sequence, count, position)
      raise Error.new("Invalid checkpoint manifest", 503) unless (1..(CHECKPOINT_LIMIT / CHUNK_BYTES)).cover?(count)
      transport_count = (count + 1) / 2
      raise Error, "Invalid checkpoint position" unless position >= 0 && position < transport_count
      first = position * 2
      last = [first + 2, count].min
      chunks = db.query("SELECT position, data FROM #{db.prefix}draft_checkpoint_chunks WHERE article_id = $1 AND sequence = $2 AND position >= $3 AND position < $4 ORDER BY position", [id, sequence, first, last])
      raise Error.new("Incomplete checkpoint", 503) unless chunks.map { |chunk| chunk.fetch("position").to_i } == (first...last).to_a
      binary = chunks.map { |chunk| Base64.strict_decode64(chunk.fetch("data")) }.join
      raise Error.new("Invalid checkpoint chunk", 503) if binary.bytesize > TRANSPORT_CHUNK_BYTES
      Base64.strict_encode64(binary)
    rescue ArgumentError
      raise Error.new("Corrupt checkpoint encoding", 503)
    end

    def checkpoint_data(db, id, sequence, count, digest)
      raise Error.new("Invalid checkpoint manifest", 503) unless (1..(CHECKPOINT_LIMIT / CHUNK_BYTES)).cover?(count)
      chunks = db.query("SELECT position, data FROM #{db.prefix}draft_checkpoint_chunks WHERE article_id = $1 AND sequence = $2 ORDER BY position", [id, sequence])
      raise Error.new("Incomplete checkpoint", 503) unless chunks.map { |chunk| chunk.fetch("position").to_i } == (0...count).to_a
      begin
        binary = chunks.map { |chunk| Base64.strict_decode64(chunk.fetch("data")) }.join
      rescue ArgumentError
        raise Error.new("Corrupt checkpoint encoding", 503)
      end
      raise Error.new("Corrupt checkpoint", 503) unless binary.bytesize <= CHECKPOINT_LIMIT && Digest::SHA256.hexdigest(binary) == digest
      Base64.strict_encode64(binary)
    end

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
      raise Error, "Invalid draft ID" unless /\A(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match?(id)
      raise Error.new("Unsupported document version", 409) unless payload["generation"] == 1 && payload["protocol"] == 1
    end

    def document(db, id)
      row = db.query("SELECT * FROM #{db.prefix}draft_articles WHERE id = $1", [id]).first
      raise Error.new("Draft not found", 404) unless row
      { "id" => id, "generation" => row.fetch("generation").to_i, "protocol" => 1, "head" => row.fetch("head").to_i,
        "metadata" => DEFAULT_METADATA.transform_values { |value| { "value" => value, "revision" => 0 } }.merge(JSON.parse(row.fetch("metadata"))), "created_at" => row.fetch("created_at"), "updated_at" => row.fetch("updated_at"), }
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
      type = current.dig("page_type", "value")
      title = current.dig("title", "value").strip
      date = current.dig("page_date", "value").to_s
      raise Error, "Diary title must match its date" if type == "date" && title != date
      raise Error, "Named articles cannot retain a diary date" if type == "named" && !date.empty?
      raise Error, "Invalid cover mode" unless CoverImage::MODES.include?(current.dig("cover_mode", "value"))
      CoverImage.validate(current.dig("cover_mode", "value"), current.dig("cover_image_url", "value"))
      current
    end

    class SqliteConnection
      def initialize(connection) = @connection = connection
      def prefix = ""
      def query(sql, values = []) = @connection.execute(sql, values)
      def transaction(&block) = @connection.transaction(:immediate, &block)

      def published_pages(limit:, before:, after:, kind:)
        published_window(limit:, before:, after:, kind:)
      end

      def published_timeline_pages(limit:, before:, after:, month:)
        published_window(limit:, before:, after:, month:, timeline: true)
      end

      private

      def published_window(limit:, before:, after:, kind: nil, month: nil, timeline: false)
        key = if timeline
                "CASE WHEN v.body LIKE '%[[日記]]%' AND v.route GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN v.route || 'T00:00:00' ELSE strftime('%Y-%m-%dT%H:%M:%S', h.updated_at, '+9 hours') END"
              else
                kind == "diary" ? "v.article_created_at" : "h.updated_at"
              end
        sql, values = published_window_sql(key:, limit:, before:, after:, kind:, month:, timeline:, placeholder: "?")
        rows = @connection.execute(sql, values).map(&:to_h)
        after ? rows.reverse : rows
      end

      def published_window_sql(key:, limit:, before:, after:, kind:, month:, timeline:, placeholder:)
        sql = "SELECT v.*, h.published_at, h.updated_at, a.atom_id, #{key} AS listing_key FROM draft_publication_heads h JOIN draft_published_versions v ON v.article_id = h.article_id AND v.id = h.active_id LEFT JOIN draft_atom_ids a ON a.article_id = h.article_id"
        conditions = []
        values = []
        if kind
          conditions << (kind == "diary" ? "v.body LIKE '%[[日記]]%'" : "v.body NOT LIKE '%[[日記]]%'")
        end
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

    class PostgresConnection
      def initialize(connection) = @connection = connection
      def prefix = "weblog_authoring."
      def query(sql, values = []) = @connection.exec_params(sql, values).to_a
      def transaction(&block) = @connection.transaction(&block)

      def published_pages(limit:, before:, after:, kind:)
        published_window(limit:, before:, after:, kind:)
      end

      def published_timeline_pages(limit:, before:, after:, month:)
        published_window(limit:, before:, after:, month:, timeline: true)
      end

      private

      def published_window(limit:, before:, after:, kind: nil, month: nil, timeline: false)
        key = if timeline
                "CASE WHEN v.body LIKE '%[[日記]]%' AND v.route ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN v.route || 'T00:00:00' ELSE to_char(h.updated_at::timestamptz AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD\"T\"HH24:MI:SS') END"
              else
                kind == "diary" ? "v.article_created_at" : "h.updated_at"
              end
        conditions = []
        values = []
        if kind
          conditions << (kind == "diary" ? "v.body LIKE '%[[日記]]%'" : "v.body NOT LIKE '%[[日記]]%'")
        end
        if month
          values << month
          conditions << "substr(#{key}, 1, 7) = $#{values.length}"
        end
        cursor = before || after
        if cursor
          operator = before ? "<" : ">"
          cursor_key = cursor.fetch(timeline ? :key : :timestamp)
          cursor_key = cursor_key.iso8601 if cursor_key.respond_to?(:iso8601)
          values.concat([cursor_key, cursor.fetch(:id)])
          conditions << "(#{key} #{operator} $#{values.length - 1} OR (#{key} = $#{values.length - 1} AND v.article_id #{operator} $#{values.length}))"
        end
        sql = "SELECT v.*, h.published_at, h.updated_at, a.atom_id, #{key} AS listing_key FROM weblog_authoring.draft_publication_heads h JOIN weblog_authoring.draft_published_versions v ON v.article_id = h.article_id AND v.id = h.active_id LEFT JOIN weblog_authoring.draft_atom_ids a ON a.article_id = h.article_id"
        sql += " WHERE #{conditions.join(' AND ')}" unless conditions.empty?
        sql += " ORDER BY #{key} #{after ? 'ASC' : 'DESC'}, v.article_id #{after ? 'ASC' : 'DESC'}"
        if limit
          values << limit
          sql += " LIMIT $#{values.length}"
        end
        rows = @connection.exec_params(sql, values).to_a
        after ? rows.reverse : rows
      end
    end
  end
end
