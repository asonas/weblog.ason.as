# frozen_string_literal: true

module WeblogAuthoring
  module DraftMigrationStore
    def setup_migration(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_migration_state (id INTEGER PRIMARY KEY, fingerprint TEXT NOT NULL, state TEXT NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_migration_articles (article_id TEXT PRIMARY KEY, version_id TEXT NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}article_atom_ids (article_id TEXT PRIMARY KEY, atom_id TEXT NOT NULL)")
    end

    def begin_migration(fingerprint)
      @connect.call do |db|
        db.transaction do
          state = db.query("SELECT * FROM #{db.prefix}draft_migration_state WHERE id = 1").first
          if state
            check_migration(db, fingerprint)
          else
            raise DraftStore::Error.new("Migration requires an empty destination", 409) if db.query("SELECT id FROM #{db.prefix}articles LIMIT 1").any?
            db.query("INSERT INTO #{db.prefix}draft_migration_state (id, fingerprint, state) VALUES (1, $1, 'importing')", [fingerprint])
          end
        end
      end
    end

    def import_legacy_article(fingerprint, source, seed)
      id = source.fetch("id")
      validate_scope!(id, { "protocol" => 1, "generation" => 1 })
      data = decoded_seed(seed)
      @connect.call do |db|
        db.transaction do
          check_migration(db, fingerprint)
          previous = db.query("SELECT version_id FROM #{db.prefix}draft_migration_articles WHERE article_id = $1", [id]).first
          if previous
            head = db.query("SELECT latest_id, active_id FROM #{db.prefix}article_publication_heads WHERE article_id = $1", [id]).first
            unless document(db, id).fetch("head") == 1 && head && head.values_at("latest_id", "active_id") == [previous.fetch("version_id")] * 2
              raise DraftStore::Error.new("Destination changed after migration; preserve it and repair forward", 409)
            end
            next previous.fetch("version_id")
          end
          raise DraftStore::Error.new("Migration must not overwrite an existing article", 409) if db.query("SELECT id FROM #{db.prefix}articles WHERE id = $1", [id]).any?
          version = SecureRandom.uuid
          insert_published_article(db, source, seed, data, version)
          db.query("INSERT INTO #{db.prefix}draft_migration_articles (article_id, version_id) VALUES ($1, $2)", [id, version])
          version
        end
      end
    end

    # Adds an already-published article from another site without the legacy
    # freeze/verify state machine. Rerunning the same source is a no-op; an id,
    # route, or published content that differs is never overwritten.
    # cutover: false is only for a local development database, which has no
    # cutover control tables.
    def import_external_article(source, seed, cutover: true)
      validate_scope!(source.fetch("id"), { "protocol" => 1, "generation" => 1 })
      data = decoded_seed(seed)
      return write_external_article(source, seed, data) unless cutover
      with_cutover_operation("draft_write") { write_external_article(source, seed, data) }
    end

    # Read-only classification for a dry run: new, already-imported, or conflict with a reason.
    def external_article_status(source)
      @connect.call { |db| classify_external_article(db, source) }
    end

    def complete_migration(fingerprint)
      @connect.call do |db|
        db.transaction do
          check_migration(db, fingerprint)
          db.query("UPDATE #{db.prefix}draft_migration_state SET state = 'verified' WHERE id = 1")
        end
      end
    end

    def seal_migration
      @connect.call do |db|
        db.transaction do
          state = db.query("SELECT state FROM #{db.prefix}draft_migration_state WHERE id = 1").first
          raise DraftStore::Error.new("Verify migration before reopening", 409) unless state && %w[verified sealed].include?(state.fetch("state"))
          db.query("UPDATE #{db.prefix}draft_migration_state SET state = 'sealed' WHERE id = 1")
        end
      end
    end

    private

    def decoded_seed(seed)
      data = decode_update(seed.fetch("data"))
      raise DraftStore::Error, "Invalid migration seed" unless data.bytesize <= DraftStore::UPDATE_LIMIT && Digest::SHA256.hexdigest(data) == seed.fetch("digest")
      data
    end

    def insert_published_article(db, source, seed, data, version)
      id = source.fetch("id")
      metadata = source.fetch("metadata").transform_values { |value| { "value" => value, "revision" => 0 } }
      db.query("INSERT INTO #{db.prefix}articles (id, generation, head, metadata, created_at, updated_at) VALUES ($1, 1, 1, $2, $3, $4)", [id, JSON.generate(metadata), source.fetch("created_at"), source.fetch("updated_at")])
      chunks = (data.bytesize + DraftStore::CHUNK_BYTES - 1) / DraftStore::CHUNK_BYTES
      chunks.times do |position|
        db.query("INSERT INTO #{db.prefix}draft_chunks (article_id, update_id, position, data) VALUES ($1, 'migration-seed', $2, $3)", [id, position, Base64.strict_encode64(data.byteslice(position * DraftStore::CHUNK_BYTES, DraftStore::CHUNK_BYTES))])
      end
      receipt = { "update_id" => "migration-seed", "digest" => seed.fetch("digest"), "sequence" => 1, "generation" => 1, "metadata" => metadata }
      update_hash = update_fingerprint(seed.fetch("digest"), source.fetch("body").bytesize, {})
      db.query("INSERT INTO #{db.prefix}draft_updates (article_id, update_id, sequence, digest, fingerprint, receipt, chunks) VALUES ($1, 'migration-seed', 1, $2, $3, $4, $5)", [id, seed.fetch("digest"), update_hash, JSON.generate(receipt), chunks])
      db.query("INSERT INTO #{db.prefix}article_published_versions (id, article_id, content_hash, body, metadata, route, created_at, article_created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)", [version, id, source.fetch("content_hash"), source.fetch("body"), JSON.generate(source.fetch("metadata")), source.fetch("route"), source.fetch("updated_at"), source.fetch("created_at")])
      db.query("INSERT INTO #{db.prefix}article_publication_heads (article_id, latest_id, active_id, published_at, updated_at) VALUES ($1, $2, $2, $3, $4)", [id, version, source.fetch("published_at"), source.fetch("updated_at")])
      db.query("INSERT INTO #{db.prefix}article_publication_routes (route, article_id) VALUES ($1, $2)", [source.fetch("route"), id])
      # Completed bookkeeping lets output repair render the imported snapshot without publishing it again.
      db.query("INSERT INTO #{db.prefix}article_publication_jobs (id, article_id, status) VALUES ($1, $2, 'completed')", [version, id])
      db.query("INSERT INTO #{db.prefix}article_atom_ids (article_id, atom_id) VALUES ($1, $2)", [id, source.fetch("atom_id")])
      db.query("UPDATE #{db.prefix}article_publication_clock SET revision = revision + 1 WHERE id = 1")
    end

    def write_external_article(source, seed, data)
      version = source.fetch("version_id")
      @connect.call do |db|
        db.transaction do
          state = classify_external_article(db, source)
          raise DraftStore::Error.new(state.fetch("reason"), 409) if state.fetch("status") == "conflict"
          if state.fetch("status") == "new"
            # Writing the reservation row makes a concurrent rename to the same route conflict under DSQL OCC; reading it alone does not
            reserve_working_route(db, source.fetch("id"), source.fetch("route"))
            insert_published_article(db, source, seed, data, version)
          end
          version
        end
      end
    end

    def classify_external_article(db, source)
      id = source.fetch("id")
      route = source.fetch("route")
      version = source.fetch("version_id")
      article = db.query("SELECT head, created_at, updated_at FROM #{db.prefix}articles WHERE id = $1", [id]).first
      if article
        return { "status" => "already-imported" } if external_article_unchanged?(db, source, article)
        return { "status" => "conflict", "reason" => "article #{id} already exists and is not the imported version #{version}" }
      end
      owner = db.query("SELECT article_id FROM #{db.prefix}article_publication_routes WHERE route = $1", [route]).first
      return { "status" => "conflict", "reason" => "route #{route} is already published by article #{owner.fetch('article_id')}" } if owner
      reserved = db.query("SELECT article_id FROM #{db.prefix}article_route_reservations WHERE route = $1", [route]).first
      return { "status" => "conflict", "reason" => "route #{route} is reserved by article #{reserved.fetch('article_id')}" } if reserved
      { "status" => "new" }
    end

    # The version id is derived from the article id alone, so an edited source
    # is only caught by comparing the stored content and timestamps.
    def external_article_unchanged?(db, source, article)
      id = source.fetch("id")
      version = source.fetch("version_id")
      head = db.query("SELECT latest_id, active_id, published_at, updated_at FROM #{db.prefix}article_publication_heads WHERE article_id = $1", [id]).first
      return false unless article.fetch("head").to_i == 1 && head && head.values_at("latest_id", "active_id") == [version] * 2
      return false unless article.values_at("created_at", "updated_at") == source.values_at("created_at", "updated_at")
      return false unless head.values_at("published_at", "updated_at") == source.values_at("published_at", "updated_at")
      stored = db.query("SELECT content_hash, body, metadata, route, created_at, article_created_at FROM #{db.prefix}article_published_versions WHERE id = $1 AND article_id = $2", [version, id]).first
      return false unless stored && stored.fetch("content_hash") == source.fetch("content_hash") && stored.fetch("body") == source.fetch("body") && stored.fetch("route") == source.fetch("route")
      return false unless JSON.parse(stored.fetch("metadata")) == source.fetch("metadata") && stored.values_at("created_at", "article_created_at") == source.values_at("updated_at", "created_at")
      atom = db.query("SELECT atom_id FROM #{db.prefix}article_atom_ids WHERE article_id = $1", [id]).first
      owner = db.query("SELECT article_id FROM #{db.prefix}article_publication_routes WHERE route = $1", [source.fetch("route")]).first
      atom && atom.fetch("atom_id") == source.fetch("atom_id") && owner && owner.fetch("article_id") == id
    end

    def check_migration(db, fingerprint)
      state = db.query("SELECT * FROM #{db.prefix}draft_migration_state WHERE id = 1").first
      unless state && state.fetch("fingerprint") == fingerprint && state.fetch("state") != "sealed"
        raise DraftStore::Error.new("Migration input changed or editing was reopened; refusing import", 409)
      end
      db.query("UPDATE #{db.prefix}draft_migration_state SET state = state WHERE id = 1")
    end
  end
end
