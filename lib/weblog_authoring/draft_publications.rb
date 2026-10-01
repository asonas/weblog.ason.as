# frozen_string_literal: true

require "securerandom"

module WeblogAuthoring
  module DraftPublications
    def setup_publications(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_published_versions (id TEXT PRIMARY KEY, article_id TEXT NOT NULL, content_hash TEXT NOT NULL, body TEXT NOT NULL, metadata TEXT NOT NULL, route TEXT NOT NULL, created_at TEXT NOT NULL, article_created_at TEXT NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_publication_jobs (id TEXT PRIMARY KEY, article_id TEXT NOT NULL, status TEXT NOT NULL, html_key TEXT, error TEXT)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_publication_heads (article_id TEXT PRIMARY KEY, latest_id TEXT NOT NULL, active_id TEXT, published_at TEXT, updated_at TEXT)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_publication_receipts (article_id TEXT NOT NULL, request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, response TEXT NOT NULL, PRIMARY KEY (article_id, request_id))")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_publication_routes (route TEXT PRIMARY KEY, article_id TEXT NOT NULL)")
    end

    def publication_receipt(id, request_id, fingerprint)
      @connect.call do |db|
        publication_receipt_from(db, id, request_id, fingerprint)
      end
    end

    def accept_verified_publication(id, request, verified)
      validate_scope!(id, request)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(request.sort.to_h))
      @connect.call do |db|
        db.transaction do
          previous = publication_receipt_from(db, id, request.fetch("request_id"), fingerprint)
          next previous if previous
          current = document(db, id)
          require_content_format!(current, request)
          if current["structure"] && (current.dig("structure", "revision") != request["structure_revision"] || current.dig("structure", "revision") != verified["structure_revision"])
            raise DraftStore::Error.new("確認後にかけらやタグが変更されました。内容を再確認してください。", 409)
          end
          revisions = current.fetch("metadata").transform_values { |field| field.fetch("revision") }
          unless current.fetch("head") == request["head"] && revisions == request["metadata_revisions"] && verified.fetch("content_hash") == request["content_hash"] && verified.fetch("through") == current.fetch("head")
            raise DraftStore::Error.new("確認後に記事が変更されました。内容を再確認してください。", 409)
          end
          head = db.query("SELECT * FROM #{db.prefix}article_publication_heads WHERE article_id = $1", [id]).first
          active = head && head["active_id"] && snapshot_from(db, id, head.fetch("active_id"))
          now = Time.now.utc.iso8601(6)
          if active && active.fetch("content_hash") == verified.fetch("content_hash")
            db.query("UPDATE #{db.prefix}article_publication_heads SET latest_id = active_id WHERE article_id = $1", [id])
            response = { "id" => active.fetch("id"), "status" => "unchanged" }
          else
            route = verified.fetch("route")
            if active && active.fetch("route") != route && !verified["rename"]
              raise DraftStore::Error.new("名前変更の影響範囲を再確認してください。", 409)
            end
            reserve_working_route(db, id, route)
            db.query("INSERT INTO #{db.prefix}article_publication_routes (route, article_id) VALUES ($1, $2) ON CONFLICT (route) DO NOTHING", [route, id])
            owner = db.query("SELECT article_id FROM #{db.prefix}article_publication_routes WHERE route = $1", [route]).first
            raise DraftStore::Error.new("このURLは別の記事で使用中です。", 409) unless owner.fetch("article_id") == id
            version_id = verified["batch_id"] || SecureRandom.uuid
            db.query("INSERT INTO #{db.prefix}article_published_versions (id, article_id, content_hash, body, metadata, route, created_at, article_created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)", [version_id, id, verified.fetch("content_hash"), verified.fetch("body"), JSON.generate(verified.fetch("metadata")), route, now, current.fetch("created_at")])
            index_piece_mentions(db, id, version_id, verified.fetch("metadata"))
            db.query("INSERT INTO #{db.prefix}article_publication_jobs (id, article_id, status) VALUES ($1, $2, 'accepted')", [version_id, id])
            db.query("INSERT INTO #{db.prefix}article_publication_heads (article_id, latest_id) VALUES ($1, $2) ON CONFLICT (article_id) DO UPDATE SET latest_id = $2", [id, version_id])
            accept_rename_batch(db, id, version_id, active, verified.fetch("rename")) if verified["rename"]
            response = { "id" => version_id, "status" => "accepted" }
          end
          # Touch the working head so DSQL detects a concurrent edit at commit.
          response["head"] = current.fetch("head") if current["structure"]
          db.query("UPDATE #{db.prefix}articles SET head = head WHERE id = $1", [id])
          db.query("INSERT INTO #{db.prefix}article_publication_receipts (article_id, request_id, fingerprint, response) VALUES ($1, $2, $3, $4)", [id, request.fetch("request_id"), fingerprint, JSON.generate(response)])
          response
        end
      end
    end

    def publication_job(id, version_id)
      @connect.call do |db|
        row = db.query("SELECT * FROM #{db.prefix}article_publication_jobs WHERE article_id = $1 AND id = $2", [id, version_id]).first
        raise DraftStore::Error.new("Publication not found", 404) unless row
        row
      end
    end

    def publication_snapshot(id, version_id)
      @connect.call { |db| snapshot_from(db, id, version_id) }
    end

    def published_snapshot(id)
      @connect.call do |db|
        head = db.query("SELECT * FROM #{db.prefix}article_publication_heads WHERE article_id = $1", [id]).first
        next nil unless head && head["active_id"]
        html = db.query("SELECT html_key, html_digest FROM #{db.prefix}article_html_outputs WHERE article_id = $1 AND version_id = $2", [id, head.fetch("active_id")]).first || {}
        snapshot_from(db, id, head.fetch("active_id")).merge(head.slice("published_at", "updated_at"), html)
      end
    end

    def published_route(route)
      resolve_published_route(route)["snapshot"]
    end

    def linked_article_publications(snapshot, existing_routes: [])
      metadata = snapshot.fetch("metadata")
      return [] unless metadata["page_type"] == "date" && metadata.dig("content", "format") == "pieces"
      names = metadata.fetch("content").fetch("pieces").flat_map { |piece| PieceMentions.names(piece.fetch("body")) }.uniq
      names.filter_map do |name|
        next if existing_routes.include?(name)
        begin
          route = WeblogAuthoring.validate_page_name(name)
        rescue ArgumentError
          next
        end
        next if %w[draft-editor draft-offline.js published editor authoring oauth assets search index.html feed.xml 404.html].include?(route.split("/").first)
        @connect.call do |db|
          db.transaction do
            owner = db.query("SELECT article_id FROM #{db.prefix}article_publication_routes WHERE route = $1", [route]).first
            version_id = Digest::SHA256.hexdigest("linked-article-version:#{route}")[0, 32]
            if owner
              head = db.query("SELECT * FROM #{db.prefix}article_publication_heads WHERE article_id = $1", [owner.fetch("article_id")]).first
              next head && !head["active_id"] && head["latest_id"] == version_id ? snapshot_from(db, owner.fetch("article_id"), version_id) : nil
            end
            next if db.query("SELECT article_id FROM #{db.prefix}article_route_reservations WHERE route = $1", [route]).any?
            id = SecureRandom.uuid
            now = Time.now.utc.iso8601(6)
            values = DraftStore::DEFAULT_METADATA.merge("title" => route)
            content = { "format" => "pieces", "pieces" => [], "tags" => [] }
            published = values.merge("content" => content, "draft_head" => 0)
            hash = Digest::SHA256.hexdigest(JSON.generate(["", *values.values_at("title", "page_type", "cover_mode", "cover_image_url"), content]))
            working = values.transform_values { |value| { "value" => value, "revision" => 0 } }
            db.query("INSERT INTO #{db.prefix}articles (id, generation, head, metadata, created_at, updated_at) VALUES ($1, 1, 0, $2, $3, $3)", [id, JSON.generate(working), now])
            db.query("INSERT INTO #{db.prefix}article_structures (article_id, format, revision, piece_ids, deleted_ids, tags) VALUES ($1, 'pieces', 0, '[]', '[]', '[]')", [id])
            reserve_working_route(db, id, route)
            db.query("INSERT INTO #{db.prefix}article_publication_routes (route, article_id) VALUES ($1, $2)", [route, id])
            db.query("INSERT INTO #{db.prefix}article_published_versions (id, article_id, content_hash, body, metadata, route, created_at, article_created_at) VALUES ($1, $2, $3, '', $4, $5, $6, $6)", [version_id, id, hash, JSON.generate(published), route, now])
            db.query("INSERT INTO #{db.prefix}article_publication_jobs (id, article_id, status) VALUES ($1, $2, 'accepted')", [version_id, id])
            db.query("INSERT INTO #{db.prefix}article_publication_heads (article_id, latest_id) VALUES ($1, $2)", [id, version_id])
            snapshot_from(db, id, version_id)
          end
        end
      end
    end

    def finish_publication(id, version_id, html_key)
      @connect.call do |db|
        db.transaction do
          head = db.query("SELECT * FROM #{db.prefix}article_publication_heads WHERE article_id = $1", [id]).first
          row = db.query("SELECT * FROM #{db.prefix}article_publication_jobs WHERE article_id = $1 AND id = $2", [id, version_id]).first
          raise DraftStore::Error.new("Publication not found", 404) unless head && row
          next row if row.fetch("status") == "completed"
          if head.fetch("latest_id") != version_id
            db.query("UPDATE #{db.prefix}article_publication_jobs SET status = 'superseded' WHERE id = $1", [version_id])
            next row.merge("status" => "superseded")
          end
          now = Time.now.utc.iso8601(6)
          db.query("UPDATE #{db.prefix}article_publication_heads SET active_id = $1, published_at = COALESCE(published_at, $2), updated_at = $2 WHERE article_id = $3", [version_id, now, id])
          unless head["active_id"]
            db.query("INSERT INTO #{db.prefix}article_webmention_requests (article_id, version_id, status) VALUES ($1, $2, 'pending') ON CONFLICT (article_id, version_id) DO NOTHING", [id, version_id])
          end
          db.query("UPDATE #{db.prefix}article_publication_clock SET revision = revision + 1 WHERE id = 1")
          db.query("UPDATE #{db.prefix}article_publication_jobs SET status = 'completed', html_key = $1, error = NULL WHERE id = $2", [html_key, version_id])
          row.merge("status" => "completed", "html_key" => html_key, "error" => nil)
        end
      end
    end

    def fail_publication(id, version_id, error)
      @connect.call do |db|
        db.query("UPDATE #{db.prefix}article_publication_jobs SET status = 'needs_attention', error = $1 WHERE article_id = $2 AND id = $3 AND status NOT IN ('completed', 'superseded')", [error.to_s[0, 1000], id, version_id])
      end
    end

    private

    def publication_receipt_from(db, id, request_id, fingerprint)
      row = db.query("SELECT * FROM #{db.prefix}article_publication_receipts WHERE article_id = $1 AND request_id = $2", [id, request_id]).first
      return nil unless row
      raise DraftStore::Error.new("Publication ID already contains different content", 409) unless row.fetch("fingerprint") == fingerprint
      JSON.parse(row.fetch("response"))
    end

    def snapshot_from(db, id, version_id)
      row = db.query("SELECT * FROM #{db.prefix}article_published_versions WHERE article_id = $1 AND id = $2", [id, version_id]).first
      raise DraftStore::Error.new("Published version not found", 404) unless row
      identity = db.query("SELECT atom_id FROM #{db.prefix}article_atom_ids WHERE article_id = $1", [id]).first || {}
      row.merge("metadata" => JSON.parse(row.fetch("metadata"))).merge(identity)
    end
  end
end
