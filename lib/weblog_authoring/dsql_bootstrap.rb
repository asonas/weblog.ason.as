# frozen_string_literal: true

require "openssl"

ENV["PGSSLROOTCERT"] ||= OpenSSL::X509::DEFAULT_CERT_FILE

require "aurora_dsql_pg"

module WeblogAuthoring
  class DsqlBootstrap
    DATABASE_ROLE = "weblog_authoring"
    SCHEMA = "weblog_authoring"

    def initialize(host:, runtime_role_arn:, connector: AuroraDsql::Pg)
      @host = host
      @runtime_role_arn = runtime_role_arn
      @connector = connector
    end

    def run
      connection = @connector.connect(host: @host)
      create_database_role(connection)
      grant_iam_role(connection)
      create_schema(connection)
      grant_privileges(connection)
    ensure
      connection&.close
    end

    private

    def create_database_role(connection)
      return if connection.exec_params(
        "SELECT 1 FROM pg_roles WHERE rolname = $1",
        [DATABASE_ROLE]
      ).ntuples.positive?

      connection.exec("CREATE ROLE #{DATABASE_ROLE} WITH LOGIN")
    end

    def grant_iam_role(connection)
      return if connection.exec_params(
        "SELECT 1 FROM sys.iam_pg_role_mappings WHERE pg_role_name = $1 AND arn = $2",
        [DATABASE_ROLE, @runtime_role_arn]
      ).ntuples.positive?

      connection.exec("AWS IAM GRANT #{DATABASE_ROLE} TO #{connection.escape_literal(@runtime_role_arn)}")
    end

    def create_schema(connection)
      connection.exec("CREATE SCHEMA IF NOT EXISTS #{SCHEMA}")
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.pages (
          id TEXT PRIMARY KEY,
          page_type TEXT NOT NULL,
          name TEXT UNIQUE,
          page_date TEXT,
          title TEXT,
          status TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL,
          published_at TIMESTAMPTZ,
          path TEXT NOT NULL,
          body_hash TEXT NOT NULL,
          is_empty BOOLEAN NOT NULL,
          body TEXT NOT NULL,
          cover_mode TEXT NOT NULL DEFAULT 'auto',
          cover_image_url TEXT
        )
      SQL
      connection.exec("ALTER TABLE #{SCHEMA}.pages ADD COLUMN IF NOT EXISTS cover_mode TEXT")
      connection.exec("ALTER TABLE #{SCHEMA}.pages ALTER COLUMN cover_mode SET DEFAULT 'auto'")
      connection.exec("UPDATE #{SCHEMA}.pages SET cover_mode = 'auto' WHERE cover_mode IS NULL")
      connection.exec("ALTER TABLE #{SCHEMA}.pages ADD COLUMN IF NOT EXISTS cover_image_url TEXT")
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.links (
          source_id TEXT NOT NULL,
          target_id TEXT,
          target_name TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (source_id, position)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.scrapbox_line_metadata (
          page_id TEXT NOT NULL,
          body_hash TEXT NOT NULL,
          line_index INTEGER NOT NULL,
          created_at TIMESTAMPTZ,
          updated_at TIMESTAMPTZ,
          user_id TEXT,
          PRIMARY KEY (page_id, line_index)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.inbox_items (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          kind TEXT NOT NULL,
          source_id TEXT NOT NULL,
          occurred_at TIMESTAMPTZ NOT NULL,
          ingested_at TIMESTAMPTZ NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL,
          payload JSONB NOT NULL,
          created_at TIMESTAMPTZ NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL,
          UNIQUE (source, kind, source_id),
          CHECK ((source, kind) IN (
            ('photo', 'photo'),
            ('bluesky', 'post'),
            ('bluesky', 'like'),
            ('raindrop', 'bookmark'),
            ('c4p', 'track')
          ))
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.consumed_inbox_items (
          source TEXT NOT NULL,
          kind TEXT NOT NULL,
          source_id TEXT NOT NULL,
          consumed_at TIMESTAMPTZ NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL,
          PRIMARY KEY (source, kind, source_id)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.inbox_item_usages (
          item_id TEXT NOT NULL,
          page_id TEXT NOT NULL,
          used_at TIMESTAMPTZ NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL,
          PRIMARY KEY (item_id, page_id)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.inbox_image_adoptions (
          item_id TEXT PRIMARY KEY,
          inbox_key TEXT NOT NULL,
          public_key TEXT NOT NULL,
          prepared_at TIMESTAMPTZ NOT NULL,
          committed_at TIMESTAMPTZ,
          expires_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.mobile_pairings (
          id TEXT PRIMARY KEY,
          code_digest TEXT NOT NULL UNIQUE,
          attempts INTEGER NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL,
          used_at TIMESTAMPTZ,
          created_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.mobile_devices (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          token_digest TEXT NOT NULL UNIQUE,
          created_at TIMESTAMPTZ NOT NULL,
          last_used_at TIMESTAMPTZ,
          revoked_at TIMESTAMPTZ
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.mobile_uploads (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL,
          client_upload_id TEXT NOT NULL,
          s3_key TEXT NOT NULL,
          content_type TEXT NOT NULL,
          size INTEGER NOT NULL,
          sha256 TEXT NOT NULL,
          captured_at TIMESTAMPTZ,
          captured_at_source TEXT NOT NULL,
          state TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL,
          completed_at TIMESTAMPTZ,
          UNIQUE (device_id, client_upload_id)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.inbox_source_sync_states (
          source TEXT PRIMARY KEY,
          last_attempted_at TIMESTAMPTZ NOT NULL,
          last_succeeded_at TIMESTAMPTZ,
          watermark TEXT,
          last_error TEXT,
          updated_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.inbox_sync_runs (
          id TEXT PRIMARY KEY,
          trigger TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at TIMESTAMPTZ NOT NULL,
          completed_at TIMESTAMPTZ,
          expires_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.inbox_sync_run_sources (
          run_id TEXT NOT NULL,
          source TEXT NOT NULL,
          status TEXT NOT NULL,
          fetched_count INTEGER NOT NULL,
          created_count INTEGER NOT NULL,
          updated_count INTEGER NOT NULL,
          deleted_count INTEGER NOT NULL,
          error TEXT,
          completed_at TIMESTAMPTZ NOT NULL,
          PRIMARY KEY (run_id, source)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.bluesky_oauth_states (
          state TEXT PRIMARY KEY,
          encrypted_value TEXT NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL,
          created_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.bluesky_oauth_sessions (
          did TEXT PRIMARY KEY,
          encrypted_value TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('connected', 'reauthorization_required')),
          created_at TIMESTAMPTZ NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.bluesky_oauth_locks (
          lock_key TEXT PRIMARY KEY,
          expires_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.webmention_relations (
          id TEXT PRIMARY KEY,
          source_url TEXT NOT NULL,
          target_url TEXT NOT NULL,
          target_page_id TEXT NOT NULL,
          verification_status TEXT NOT NULL,
          moderation_status TEXT NOT NULL,
          first_verified_at TIMESTAMPTZ,
          last_notified_at TIMESTAMPTZ NOT NULL,
          last_verified_at TIMESTAMPTZ,
          deleted_at TIMESTAMPTZ,
          deletion_reason TEXT,
          created_at TIMESTAMPTZ NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL,
          UNIQUE (source_url, target_url)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.webmention_snapshots (
          id TEXT PRIMARY KEY,
          relation_id TEXT NOT NULL,
          snapshot_kind TEXT NOT NULL,
          source_url TEXT NOT NULL,
          title TEXT,
          site_name TEXT,
          content_hash TEXT NOT NULL,
          is_current BOOLEAN NOT NULL,
          created_at TIMESTAMPTZ NOT NULL,
          expires_at TIMESTAMPTZ
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.webmention_attempts (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL,
          relation_id TEXT,
          source_url TEXT NOT NULL,
          target_url TEXT NOT NULL,
          target_page_id TEXT,
          result TEXT NOT NULL,
          http_status INTEGER,
          redirect_count INTEGER NOT NULL,
          fetched_bytes INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL,
          content_hash TEXT,
          attempted_at TIMESTAMPTZ NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.webmention_page_targets (
          page_id TEXT NOT NULL,
          target_url TEXT NOT NULL,
          first_seen_at TIMESTAMPTZ NOT NULL,
          last_seen_at TIMESTAMPTZ NOT NULL,
          active BOOLEAN NOT NULL,
          PRIMARY KEY (page_id, target_url)
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.webmention_outbox (
          id TEXT PRIMARY KEY,
          event_type TEXT NOT NULL,
          page_id TEXT NOT NULL,
          payload JSONB NOT NULL,
          status TEXT NOT NULL,
          attempt_count INTEGER NOT NULL,
          created_at TIMESTAMPTZ NOT NULL,
          notified_at TIMESTAMPTZ,
          completed_at TIMESTAMPTZ
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.webmention_deliveries (
          id TEXT PRIMARY KEY,
          page_id TEXT NOT NULL,
          source_url TEXT NOT NULL,
          target_url TEXT NOT NULL,
          status TEXT NOT NULL,
          attempt_count INTEGER NOT NULL,
          last_http_status INTEGER,
          last_error TEXT,
          created_at TIMESTAMPTZ NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL,
          completed_at TIMESTAMPTZ,
          expires_at TIMESTAMPTZ
        )
      SQL
    end

    def grant_privileges(connection)
      connection.exec("GRANT USAGE ON SCHEMA #{SCHEMA} TO #{DATABASE_ROLE}")
      connection.exec(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{SCHEMA} TO #{DATABASE_ROLE}"
      )
    end
  end
end
