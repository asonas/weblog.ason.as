# frozen_string_literal: true

module WeblogAuthoring
  module DraftDispatches
    def setup_dispatches(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_dispatches (id TEXT PRIMARY KEY, article_id TEXT NOT NULL, version_id TEXT NOT NULL, status TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL, completed_at TEXT)")
    end

    def queue_publication_dispatch(id, version_id)
      publication_job(id, version_id)
      token = SecureRandom.uuid
      @connect.call do |db|
        db.query("INSERT INTO #{db.prefix}draft_dispatches (id, article_id, version_id, status, created_at) VALUES ($1, $2, $3, 'queued', $4)", [token, id, version_id, Time.now.utc.iso8601(6)])
        db.query("DELETE FROM #{db.prefix}draft_dispatches WHERE status = 'completed' AND completed_at < $1", [(Time.now.utc - (30 * 86400)).iso8601(6)])
      end
      publication_dispatch(id, version_id, token)
    end

    def publication_dispatch(id, version_id, token)
      @connect.call do |db|
        row = db.query("SELECT * FROM #{db.prefix}draft_dispatches WHERE id = $1 AND article_id = $2 AND version_id = $3", [token, id, version_id]).first
        raise DraftStore::Error.new("Publication dispatch not found", 404) unless row
        row
      end
    end

    def start_publication_dispatch(token)
      @connect.call do |db|
        db.transaction do
          row = db.query("SELECT * FROM #{db.prefix}draft_dispatches WHERE id = $1", [token]).first
          raise DraftStore::Error.new("Publication dispatch not found", 404) unless row
          next nil if row.fetch("status") == "completed"
          db.query("UPDATE #{db.prefix}draft_dispatches SET status = 'running', error = NULL, completed_at = NULL WHERE id = $1", [token])
          row
        end
      end
    end

    def finish_publication_dispatch(token, error: nil)
      @connect.call do |db|
        db.query("UPDATE #{db.prefix}draft_dispatches SET status = $1, error = $2, completed_at = $3 WHERE id = $4", [error ? "failed" : "completed", error&.to_s&.slice(0, 1000), Time.now.utc.iso8601(6), token])
      end
    end
  end
end
