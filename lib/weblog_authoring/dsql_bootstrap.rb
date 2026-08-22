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
          body TEXT NOT NULL
        )
      SQL
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SCHEMA}.links (
          source_id TEXT NOT NULL,
          target_id TEXT,
          target_name TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (source_id, position)
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
