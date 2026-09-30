# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

module WeblogAuthoring
  module InboxMemos
    def self.schema(prefix)
      [
        "CREATE TABLE IF NOT EXISTS #{prefix}inbox_memos (id TEXT PRIMARY KEY, body TEXT, body_digest TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL, article_id TEXT, adopted_head INTEGER, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS #{prefix}inbox_memo_operations (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)",
      ]
    end

    def list_memos
      @connect.call do |db|
        db.query("SELECT id, body, revision, created_at, updated_at FROM #{db.prefix}inbox_memos WHERE state = 'available' ORDER BY updated_at DESC, id DESC").map { |row| row.merge("revision" => row.fetch("revision").to_i) }
      end
    end

    def find_memo(id)
      validate_memo_id!(id)
      @connect.call do |db|
        row = db.query("SELECT id, body, revision, created_at, updated_at FROM #{db.prefix}inbox_memos WHERE id = $1 AND state = 'available'", [id]).first
        raise DraftStore::Error.new("Memo not found", 404) unless row
        row.merge("revision" => row.fetch("revision").to_i)
      end
    end

    def save_memo(id, payload)
      body = payload["body"]
      unless body.is_a?(String) && body.valid_encoding? && body.bytesize <= 512 * 1024
        raise DraftStore::Error, "Memo must be UTF-8 text within 512 KiB"
      end
      memo_operation(id, "save", payload) do |db, current, revision|
        now = Time.now.utc.iso8601(6)
        digest = Digest::SHA256.hexdigest(body)
        if current && current.fetch("body_digest") == digest
          next memo_result(current, "unchanged")
        end
        if current && current.fetch("state") == "available" && current.fetch("revision").to_i == revision
          rows = db.query("UPDATE #{db.prefix}inbox_memos SET body = $1, body_digest = $2, revision = revision + 1, updated_at = $3 WHERE id = $4 AND revision = $5 AND state = 'available' RETURNING *", [body, digest, now, id, revision])
          raise DraftStore::Error.new("Memo changed; retry this operation", 409) if rows.empty?
          next memo_result(rows.first, "saved")
        end
        # A missing record with a nonzero revision is an offline edit, not a new memo.
        conflict = !current.nil? || revision.positive?
        memo_id = conflict ? SecureRandom.uuid : id
        db.query("INSERT INTO #{db.prefix}inbox_memos (id, body, body_digest, revision, state, created_at, updated_at) VALUES ($1, $2, $3, 1, 'available', $4, $4)", [memo_id, body, digest, now])
        { "id" => memo_id, "revision" => 1, "state" => "available", "result" => conflict ? "preserved_as_new" : "saved" }
      end
    end

    def delete_memo(id, payload)
      memo_operation(id, "delete", payload) do |db, current, revision|
        raise DraftStore::Error.new("Memo not found", 404) unless current
        if current.fetch("state") != "available" || current.fetch("revision").to_i != revision
          raise DraftStore::Error.new("Memo changed; reload before deleting", 409)
        end
        rows = db.query("UPDATE #{db.prefix}inbox_memos SET body = NULL, state = 'deleted', revision = revision + 1, updated_at = $1 WHERE id = $2 AND revision = $3 AND state = 'available' RETURNING *", [Time.now.utc.iso8601(6), id, revision])
        raise DraftStore::Error.new("Memo changed; reload before deleting", 409) if rows.empty?
        memo_result(rows.first, "deleted")
      end
    end

    def memo_receipt(id, action, payload)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([action, id, payload.reject { |key, _| key == "operation_id" }.sort.to_h]))
      @connect.call do |db|
        previous = db.query("SELECT fingerprint, result FROM #{db.prefix}inbox_memo_operations WHERE id = $1", [payload["operation_id"]]).first
        next nil unless previous
        raise DraftStore::Error.new("Operation ID already used", 409) unless previous.fetch("fingerprint") == fingerprint
        JSON.parse(previous.fetch("result"))
      end
    end

    def adopt_memo(id, payload, seed)
      memo_operation(id, "adopt", payload) do |db, current, revision|
        unless current && current.fetch("state") == "available" && current.fetch("revision").to_i == revision && current.fetch("body_digest") == seed["body_digest"]
          raise DraftStore::Error.new("Memo changed or was already taken; reload before importing", 409)
        end
        article_id = payload.fetch("article_id")
        document = document(db, article_id)
        structure = document["structure"]
        unless structure && structure.fetch("revision") == payload["structure_revision"]
          raise DraftStore::Error.new("Piece structure changed; reload before importing", 409)
        end
        piece_id = payload.fetch("piece_id")
        raise DraftStore::Error, "Piece initialization does not match" unless seed["piece_id"] == piece_id
        ids, = validate_structure!(structure.fetch("piece_ids") + [piece_id], structure.fetch("tags"))
        raise DraftStore::Error.new("Piece ID was already deleted", 409) if structure.fetch("deleted_ids").include?(piece_id)
        update = { "format" => "pieces", "update_id" => payload.fetch("operation_id"), "digest" => seed.fetch("digest"), "body_bytes" => seed.fetch("body_bytes"), "metadata" => {} }
        receipt = append_data(article_id, update, decode_update(seed.fetch("data")), connection: db)
        new_revision = structure.fetch("revision") + 1
        db.query("UPDATE #{db.prefix}article_structures SET revision = $1, piece_ids = $2 WHERE article_id = $3", [new_revision, JSON.generate(ids), article_id])
        db.query("UPDATE #{db.prefix}inbox_memos SET state = 'consumed', article_id = $1, adopted_head = $2, revision = revision + 1, updated_at = $3 WHERE id = $4", [article_id, receipt.fetch("sequence"), Time.now.utc.iso8601(6), id])
        { "id" => id, "state" => "consumed", "article_id" => article_id, "piece_id" => piece_id, "structure_revision" => new_revision, "head" => receipt.fetch("sequence") }
      end
    end

    def published_memos_pending?(article_id, version_id)
      @connect.call do |db|
        next false if db.query("SELECT id FROM #{db.prefix}inbox_memos WHERE article_id = $1 AND state = 'consumed' LIMIT 1", [article_id]).empty?
        head = confirmed_memo_head(db, article_id, version_id)
        db.query("SELECT id FROM #{db.prefix}inbox_memos WHERE article_id = $1 AND state = 'consumed' AND adopted_head <= $2 LIMIT 1", [article_id, head]).any?
      end
    end

    def delete_published_memo_bodies(article_id, version_id)
      snapshot = published_snapshot(article_id)
      raise DraftStore::Error.new("Published version changed", 409) unless snapshot && snapshot.fetch("id") == version_id
      @connect.call do |db|
        head = confirmed_memo_head(db, article_id, version_id)
        db.query("UPDATE #{db.prefix}inbox_memos SET body = NULL, state = 'published', revision = revision + 1 WHERE article_id = $1 AND state = 'consumed' AND adopted_head <= $2", [article_id, head])
      end
    end

    private

    def confirmed_memo_head(db, article_id, version_id)
      db.query("SELECT response FROM #{db.prefix}article_publication_receipts WHERE article_id = $1", [article_id]).filter_map do |row|
        receipt = JSON.parse(row.fetch("response"))
        receipt["head"] if receipt["id"] == version_id
      end.max || 0
    end

    def memo_operation(id, action, payload)
      validate_memo_id!(id)
      operation_id = payload["operation_id"]
      validate_memo_id!(operation_id)
      revision = payload["expected_revision"]
      raise DraftStore::Error, "Expected a nonnegative memo revision" unless revision.is_a?(Integer) && revision >= 0
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([action, id, payload.reject { |key, _| key == "operation_id" }.sort.to_h]))
      @connect.call do |db|
        db.transaction do
          previous = db.query("SELECT fingerprint, result FROM #{db.prefix}inbox_memo_operations WHERE id = $1", [operation_id]).first
          if previous
            raise DraftStore::Error.new("Operation ID already used", 409) unless previous.fetch("fingerprint") == fingerprint
            next JSON.parse(previous.fetch("result"))
          end
          current = db.query("SELECT * FROM #{db.prefix}inbox_memos WHERE id = $1", [id]).first
          result = yield(db, current, revision)
          db.query("INSERT INTO #{db.prefix}inbox_memo_operations (id, fingerprint, result) VALUES ($1, $2, $3)", [operation_id, fingerprint, JSON.generate(result)])
          result
        end
      end
    end

    def memo_result(row, result)
      { "id" => row.fetch("id"), "revision" => row.fetch("revision").to_i, "state" => row.fetch("state"), "result" => result }
    end

    def validate_memo_id!(id)
      raise DraftStore::Error, "Expected a memo or operation UUID" unless id.is_a?(String) && /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.match?(id)
    end
  end
end
