# frozen_string_literal: true

require_relative "public_cache"

module WeblogAuthoring
  module DraftCacheStore
    def setup_cache(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_cache_requests (article_id TEXT NOT NULL, version_id TEXT PRIMARY KEY, routes TEXT NOT NULL, paths TEXT NOT NULL)")
    end

    def cache_request(id, version_id)
      @connect.call { |db| db.query("SELECT * FROM #{db.prefix}article_cache_requests WHERE article_id = $1 AND version_id = $2", [id, version_id]).first }
    end

    def wait_publication_cache(claim, now:)
      @connect.call do |db|
        db.query("UPDATE #{db.prefix}article_publication_stages SET status = 'retry_wait', attempts = 0, next_attempt_at = $1, error = 'キャッシュ更新中です。' WHERE article_id = $2 AND version_id = $3 AND stage = 'cache' AND token = $4 AND status = 'running'", [(now + 30).iso8601(6), *claim.values_at("article_id", "version_id", "token")])
      end
    end

    def prepare_cache_request(db, id, version_id, routes)
      paths = PublicCache.paths(routes)
      db.query("INSERT INTO #{db.prefix}article_cache_requests (article_id, version_id, routes, paths) VALUES ($1, $2, $3, $4)", [id, version_id, JSON.generate(routes), JSON.generate(paths)])
      db.query("INSERT INTO #{db.prefix}article_publication_stages (article_id, version_id, stage, status, attempts, token) VALUES ($1, $2, 'cache', 'queued', 0, '')", [id, version_id])
    rescue ArgumentError => error
      db.query("INSERT INTO #{db.prefix}article_publication_stages (article_id, version_id, stage, status, attempts, token, error) VALUES ($1, $2, 'cache', 'needs_attention', 0, '', $3)", [id, version_id, error.message])
    end
    private :prepare_cache_request
  end
end
