# frozen_string_literal: true

module WeblogAuthoring
  module ArticleStructure
    def self.schema(prefix)
      "CREATE TABLE IF NOT EXISTS #{prefix}article_structures (article_id TEXT PRIMARY KEY, format TEXT NOT NULL, revision INTEGER NOT NULL, piece_ids TEXT NOT NULL, deleted_ids TEXT NOT NULL, tags TEXT NOT NULL)"
    end

    def update_structure(id, payload)
      validate_scope!(id, payload)
      ids, tags = validate_structure!(payload["piece_ids"], payload["tags"])
      retired, = validate_structure!(payload.fetch("deleted_ids", []), [])
      raise DraftStore::Error, "Active pieces cannot be retired" unless (ids & retired).empty?
      @connect.call do |db|
        db.transaction do
          current = document(db, id)
          require_content_format!(current, payload)
          structure = current["structure"]
          raise DraftStore::Error, "This article has no pieces" unless structure
          unless structure.fetch("revision") == payload["expected_revision"]
            raise DraftStore::Error.new("Piece order or tags changed; reload and retry", 409)
          end
          unless (ids & structure.fetch("deleted_ids")).empty?
            raise DraftStore::Error.new("A deleted piece cannot be restored with the same ID", 409)
          end
          deleted = (structure.fetch("deleted_ids") + structure.fetch("piece_ids") + retired - ids).uniq
          updated = { "revision" => structure.fetch("revision") + 1, "piece_ids" => ids, "deleted_ids" => deleted, "tags" => tags }
          db.query("UPDATE #{db.prefix}article_structures SET revision = $1, piece_ids = $2, deleted_ids = $3, tags = $4 WHERE article_id = $5", [updated.fetch("revision"), JSON.generate(ids), JSON.generate(deleted), JSON.generate(tags), id])
          # Structural edits share the existing publication and cache version boundary.
          append_data(id, { "format" => "pieces", "update_id" => SecureRandom.uuid, "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0, "metadata" => {} }, "\0\0", connection: db)
          db.query("DELETE FROM #{db.prefix}draft_working_hashes WHERE article_id = $1", [id])
          updated
        end
      end
    end

    def delete_piece_draft(id, payload)
      validate_scope!(id, payload)
      raise DraftStore::Error, "Only a piece draft can be deleted here" unless payload["format"] == "pieces"
      @connect.call do |db|
        db.transaction do
          format = db.query("SELECT format FROM #{db.prefix}article_structures WHERE article_id = $1", [id]).first
          next({ "deleted" => true }) if format && format.fetch("format") == "deleted"
          current = document(db, id)
          require_content_format!(current, payload)
          unless current.fetch("head") == payload["head"] && current.dig("structure", "revision") == payload["structure_revision"]
            raise DraftStore::Error.new("Draft changed; reload before deleting", 409)
          end
          if db.query("SELECT article_id FROM #{db.prefix}article_publication_heads WHERE article_id = $1 AND published_at IS NOT NULL", [id]).any?
            raise DraftStore::Error.new("This article has already been published", 409)
          end
          db.query("UPDATE #{db.prefix}inbox_memos SET state = 'available', article_id = NULL, adopted_head = NULL, revision = revision + 1, updated_at = $1 WHERE article_id = $2 AND state = 'consumed'", [Time.now.utc.iso8601(6), id])
          %w[draft_updates draft_chunks draft_uploads draft_upload_chunks draft_checkpoint_heads draft_checkpoints draft_checkpoint_chunks draft_working_hashes article_published_versions article_publication_jobs article_publication_heads article_publication_receipts article_publication_routes article_publication_stages article_publication_dispatches article_html_outputs article_atom_ids article_webmention_requests article_route_reservations article_redirects article_rename_members].each do |table|
            db.query("DELETE FROM #{db.prefix}#{table} WHERE article_id = $1", [id])
          end
          db.query("DELETE FROM #{db.prefix}article_piece_links WHERE article_id = $1", [id])
          db.query("DELETE FROM #{db.prefix}articles WHERE id = $1", [id])
          db.query("UPDATE #{db.prefix}article_structures SET format = 'deleted', piece_ids = '[]', deleted_ids = '[]', tags = '[]', revision = revision + 1 WHERE article_id = $1", [id])
          { "deleted" => true }
        end
      end
    end

    private

    def content_structure(db, id)
      row = db.query("SELECT * FROM #{db.prefix}article_structures WHERE article_id = $1", [id]).first
      return { "format" => "legacy" } unless row && row.fetch("format") == "pieces"
      { "format" => "pieces", "structure" => { "revision" => row.fetch("revision").to_i,
        "piece_ids" => JSON.parse(row.fetch("piece_ids")), "deleted_ids" => JSON.parse(row.fetch("deleted_ids")), "tags" => JSON.parse(row.fetch("tags")), } }
    end

    def require_content_format!(current, payload)
      return if current.fetch("format", "legacy") == payload.fetch("format", "legacy")
      raise DraftStore::Error.new("Article format requires a compatible editor; keep unsent edits and reload", 409)
    end

    def validate_structure!(ids, tags)
      unless ids.is_a?(Array) && ids.uniq == ids && ids.all? { |id| id.is_a?(String) && /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(id) } && JSON.generate(ids).bytesize <= 64 * 1024
        raise DraftStore::Error, "Invalid piece IDs"
      end
      unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && !tag.strip.empty? && !tag.match?(/[\[\]\r\n]/) } && JSON.generate(tags).bytesize <= 4096
        raise DraftStore::Error, "Invalid article tags"
      end
      [ids, tags.map(&:strip).uniq]
    end
  end
end
