# frozen_string_literal: true

module WeblogAuthoring
  module DraftOutputStore
    def setup_outputs(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_publication_clock (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL)")
      db.query("INSERT INTO #{db.prefix}draft_publication_clock (id, revision) VALUES (1, 0) ON CONFLICT (id) DO NOTHING")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_publication_stages (article_id TEXT NOT NULL, version_id TEXT NOT NULL, stage TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, token TEXT NOT NULL, next_attempt_at TEXT, error TEXT, completed_at TEXT, PRIMARY KEY (article_id, version_id, stage))")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_output_heads (stage TEXT PRIMARY KEY, revision INTEGER NOT NULL, object_key TEXT NOT NULL, digest TEXT NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_html_outputs (article_id TEXT PRIMARY KEY, version_id TEXT NOT NULL, html_key TEXT NOT NULL, html_digest TEXT NOT NULL)")
    end

    def record_publication_html(id, version_id, artifact)
      @connect.call do |db|
        db.transaction do
          head = db.query("SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $1", [id]).first
          next false unless head && head["active_id"] == version_id
          db.query("UPDATE #{db.prefix}draft_publication_heads SET active_id = active_id WHERE article_id = $1", [id])
          db.query("INSERT INTO #{db.prefix}draft_html_outputs (article_id, version_id, html_key, html_digest) VALUES ($1, $2, $3, $4) ON CONFLICT (article_id) DO UPDATE SET version_id = $2, html_key = $3, html_digest = $4", [id, version_id, artifact.fetch("html_key"), artifact.fetch("html_digest")])
          true
        end
      end
    end

    def published_collection
      before = publication_revision
      snapshots = []
      cursor = ""
      loop do
        page = @connect.call do |db|
          db.query("SELECT v.*, h.published_at, h.updated_at, a.atom_id FROM #{db.prefix}draft_publication_heads h JOIN #{db.prefix}draft_published_versions v ON v.article_id = h.article_id AND v.id = h.active_id LEFT JOIN #{db.prefix}draft_atom_ids a ON a.article_id = h.article_id WHERE h.article_id > $1 ORDER BY h.article_id LIMIT 100", [cursor])
        end
        break if page.empty?
        snapshots.concat(page.map { |row| row.merge("metadata" => JSON.parse(row.fetch("metadata"))).reject { |key, value| key == "atom_id" && value.nil? } })
        cursor = page.last.fetch("article_id")
      end
      raise DraftStore::Error.new("公開版が更新されたため生成を再試行します。", 409) unless before == publication_revision
      { "revision" => before, "snapshots" => snapshots }
    end

    def published_pages(limit: nil, before: nil, after: nil, kind: nil)
      @connect.call do |db|
        db.published_pages(limit:, before:, after:, kind:).map { |row| normalize_published_row(row) }
      end
    end

    def published_timeline_pages(limit:, before: nil, after: nil, month: nil)
      @connect.call do |db|
        db.published_timeline_pages(limit:, before:, after:, month:).map { |row| normalize_published_row(row) }
      end
    end

    def publication_revision
      @connect.call { |db| db.query("SELECT revision FROM #{db.prefix}draft_publication_clock WHERE id = 1").first.fetch("revision").to_i }
    end

    def normalize_published_row(row)
      row.merge("metadata" => JSON.parse(row.fetch("metadata"))).reject { |key, value| key == "atom_id" && value.nil? }
    end
    private :normalize_published_row

    def output_head(stage)
      @connect.call { |db| db.query("SELECT * FROM #{db.prefix}draft_output_heads WHERE stage = $1", [stage]).first }
    end

    def publication_stages(id, version_id)
      @connect.call do |db|
        db.query("SELECT * FROM #{db.prefix}draft_publication_stages WHERE article_id = $1 AND version_id = $2 ORDER BY stage", [id, version_id]).map { |row| row.merge("attempts" => row.fetch("attempts").to_i) }
      end
    end

    def begin_publication_stage(id, version_id, stage, now:, retry_now: false, rebuild: false)
      raise DraftStore::Error, "Unknown publication stage" unless %w[html atom search].include?(stage)
      @connect.call do |db|
        db.transaction do
          job = db.query("SELECT * FROM #{db.prefix}draft_publication_jobs WHERE article_id = $1 AND id = $2", [id, version_id]).first
          raise DraftStore::Error.new("Publication not found", 404) unless job
          previous = db.query("SELECT * FROM #{db.prefix}draft_publication_stages WHERE article_id = $1 AND version_id = $2 AND stage = $3", [id, version_id, stage]).first
          if previous
            next nil if previous.fetch("status") == "completed" && !rebuild
            next nil if previous.fetch("status") == "needs_attention" && !retry_now
            next nil if previous["next_attempt_at"] && Time.iso8601(previous.fetch("next_attempt_at")) > now && !retry_now
          end
          attempts = previous && previous.fetch("status") != "completed" ? previous.fetch("attempts").to_i + 1 : 1
          token = SecureRandom.uuid
          db.query("INSERT INTO #{db.prefix}draft_publication_stages (article_id, version_id, stage, status, attempts, token, next_attempt_at) VALUES ($1, $2, $3, 'running', $4, $5, $6) ON CONFLICT (article_id, version_id, stage) DO UPDATE SET status = 'running', attempts = $4, token = $5, next_attempt_at = $6, error = NULL, completed_at = NULL", [id, version_id, stage, attempts, token, (now + 300).iso8601(6)])
          { "article_id" => id, "version_id" => version_id, "stage" => stage, "token" => token, "attempts" => attempts }
        end
      end
    end

    def complete_publication_stage(claim, now:, output: nil)
      @connect.call do |db|
        db.transaction do
          stage = db.query("SELECT token, status FROM #{db.prefix}draft_publication_stages WHERE article_id = $1 AND version_id = $2 AND stage = $3", claim.values_at("article_id", "version_id", "stage")).first
          next false unless stage && stage.fetch("token") == claim.fetch("token") && stage.fetch("status") == "running"
          if output
            revision = db.query("SELECT revision FROM #{db.prefix}draft_publication_clock WHERE id = 1").first.fetch("revision").to_i
            raise DraftStore::Error.new("新しい公開版があるため生成を再試行します。", 409) unless revision == output.fetch("revision")
            db.query("UPDATE #{db.prefix}draft_publication_clock SET revision = revision WHERE id = 1")
            db.query("INSERT INTO #{db.prefix}draft_output_heads (stage, revision, object_key, digest) VALUES ($1, $2, $3, $4) ON CONFLICT (stage) DO UPDATE SET revision = $2, object_key = $3, digest = $4", [claim.fetch("stage"), revision, output.fetch("object_key"), output.fetch("digest")])
          end
          db.query("UPDATE #{db.prefix}draft_publication_stages SET status = 'completed', next_attempt_at = NULL, error = NULL, completed_at = $1 WHERE token = $2 AND article_id = $3 AND version_id = $4 AND stage = $5", [now.iso8601(6), *claim.values_at("token", "article_id", "version_id", "stage")])
          true
        end
      end
    end

    def fail_publication_stage(claim, error, now:)
      attempts = claim.fetch("attempts")
      status = attempts >= 5 ? "needs_attention" : "retry_wait"
      @connect.call do |db|
        db.query("UPDATE #{db.prefix}draft_publication_stages SET status = $1, error = $2, next_attempt_at = $3 WHERE token = $4 AND article_id = $5 AND version_id = $6 AND stage = $7 AND status = 'running'", [status, error.to_s[0, 1000], (now + [30 * (2**[attempts - 1, 7].min), 3600].min).iso8601(6), *claim.values_at("token", "article_id", "version_id", "stage")])
      end
    end

    def supersede_publication_stages(id, now:)
      @connect.call do |db|
        db.query("UPDATE #{db.prefix}draft_publication_jobs SET status = 'superseded' WHERE article_id = $1 AND status NOT IN ('completed', 'superseded') AND id NOT IN (SELECT latest_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $1) AND id NOT IN (SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $1 AND active_id IS NOT NULL)", [id])
        db.query("UPDATE #{db.prefix}draft_publication_stages SET status = 'superseded', completed_at = $1, next_attempt_at = NULL WHERE article_id = $2 AND status NOT IN ('completed', 'superseded') AND version_id NOT IN (SELECT latest_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $2) AND version_id NOT IN (SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $2 AND active_id IS NOT NULL)", [now.iso8601(6), id])
      end
    end

    def publication_repair_jobs
      heads = []
      cursor = ""
      loop do
        page = @connect.call { |db| db.query("SELECT article_id, latest_id, active_id FROM #{db.prefix}draft_publication_heads WHERE article_id > $1 ORDER BY article_id LIMIT 100", [cursor]) }
        break if page.empty?
        heads.concat(page)
        cursor = page.last.fetch("article_id")
      end
      heads
    end

    def cleanup_publication_stages(now:)
      @connect.call do |db|
        db.query("DELETE FROM #{db.prefix}draft_publication_jobs WHERE status IN ('completed', 'superseded') AND id IN (SELECT id FROM #{db.prefix}draft_published_versions WHERE created_at < $1) AND id NOT IN (SELECT latest_id FROM #{db.prefix}draft_publication_heads) AND id NOT IN (SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE active_id IS NOT NULL) AND id NOT IN (SELECT version_id FROM #{db.prefix}draft_publication_stages WHERE status NOT IN ('completed', 'superseded') OR completed_at >= $1)", [(now - (30 * 86400)).iso8601(6)])
        db.query("DELETE FROM #{db.prefix}draft_publication_stages WHERE status IN ('completed', 'superseded') AND completed_at < $1 AND version_id NOT IN (SELECT latest_id FROM #{db.prefix}draft_publication_heads) AND version_id NOT IN (SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE active_id IS NOT NULL) AND version_id NOT IN (SELECT version_id FROM #{db.prefix}draft_publication_stages WHERE status NOT IN ('completed', 'superseded'))", [(now - (30 * 86400)).iso8601(6)])
      end
    end
  end
end
