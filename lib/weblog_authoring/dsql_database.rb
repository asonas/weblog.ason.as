# frozen_string_literal: true

require "date"
require "digest"
require "openssl"
require "pathname"
require "securerandom"
require "time"

ENV["PGSSLROOTCERT"] ||= OpenSSL::X509::DEFAULT_CERT_FILE

require "aurora_dsql_pg"

require_relative "links"
require_relative "models"
require_relative "names"

module WeblogAuthoring
  class DsqlDatabase
    DATABASE_ROLE = "weblog_authoring"
    SCHEMA = "weblog_authoring"
    TOKYO_OFFSET = "+09:00"

    def initialize(host:, content_dir:, clock: -> { Time.now.getlocal(TOKYO_OFFSET) }, pool: nil)
      @content_dir = Pathname(content_dir)
      @clock = clock
      @pool = pool || AuroraDsql::Pg.create_pool(
        host:,
        user: DATABASE_ROLE,
        application_name: "weblog-authoring",
        occ_max_retries: 3
      )
    end

    def list_pages
      with_connection do |connection|
        connection.exec(<<~SQL).map { |row| page_from_row(row) }
          SELECT id, page_type, name, page_date, title, status,
                 created_at, updated_at, published_at, path, body
          FROM #{SCHEMA}.pages
          ORDER BY created_at DESC, updated_at DESC
        SQL
      end
    end

    def healthy?
      with_connection { |connection| connection.exec("SELECT 1") }
      true
    end

    def find(id)
      with_connection do |connection|
        result = connection.exec_params("#{select_sql("id")} LIMIT 1", [id])
        result.ntuples.zero? ? nil : page_from_row(result[0])
      end
    end

    def find_route(route)
      normalized_route = route.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      return nil if normalized_route.empty?

      with_connection do |connection|
        result = connection.exec_params(
          <<~SQL,
            SELECT id, page_type, name, page_date, title, status,
                   created_at, updated_at, published_at, path, body
            FROM #{SCHEMA}.pages
            WHERE (page_type = 'date' AND page_date = $1)
               OR (page_type = 'named' AND name = $1)
            LIMIT 1
          SQL
          [normalized_route]
        )
        result.ntuples.zero? ? nil : page_from_row(result[0])
      end
    end

    def save(request)
      current = request.page_id && find(request.page_id)
      document = current.nil? ? new_document(request) : updated_document(current, request)

      with_connection do |connection|
        connection.transaction do
          ensure_unique_route!(connection, document, current)
          current.nil? ? insert_page(connection, document) : update_page(connection, document)
          replace_links(connection, document)
        end
      end

      find(document.id)
    rescue PG::UniqueViolation => error
      raise ConflictError, "ページの保存に失敗しました: #{error.message}"
    end

    def close
      @pool.shutdown
    end

    private

    def new_document(request)
      timestamp = now
      name = WeblogAuthoring.validate_page_name(request.name || request.title.to_s)
      body = request.body.to_s

      PageDocument.new(
        id: SecureRandom.uuid.delete("-"),
        page_type: "named",
        name:,
        page_date: nil,
        title: nil,
        status: "published",
        created_at: timestamp,
        updated_at: timestamp,
        published_at: timestamp,
        path: WeblogAuthoring.page_path(@content_dir, "named", name:, page_date: nil),
        body:,
        links: WeblogAuthoring.extract_wiki_links(body)
      )
    end

    def updated_document(current, request)
      validate_expected_update(current, request)
      body = request.body.to_s
      PageDocument.new(
        **current.to_h,
        body:,
        updated_at: now,
        links: WeblogAuthoring.extract_wiki_links(body)
      )
    end

    def ensure_unique_route!(connection, document, current)
      result = connection.exec_params(
        "SELECT id FROM #{SCHEMA}.pages WHERE page_type = $1 AND name = $2 LIMIT 1",
        [document.page_type, document.name]
      )
      return if result.ntuples.zero? || result[0].fetch("id") == current&.id

      raise ConflictError, "ページが既に存在します: #{document.route}"
    end

    def insert_page(connection, document)
      connection.exec_params(
        <<~SQL,
          INSERT INTO #{SCHEMA}.pages (
            id, page_type, name, page_date, title, status, created_at,
            updated_at, published_at, path, body_hash, is_empty, body
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        SQL
        page_values(document)
      )
    end

    def update_page(connection, document)
      connection.exec_params(
        <<~SQL,
          UPDATE #{SCHEMA}.pages
          SET status = $1, updated_at = $2, published_at = $3,
              body_hash = $4, is_empty = $5, body = $6
          WHERE id = $7
        SQL
        [
          document.status,
          document.updated_at,
          document.published_at,
          Digest::SHA256.hexdigest(document.body),
          document.empty?,
          document.body,
          document.id,
        ]
      )
    end

    def replace_links(connection, document)
      connection.exec_params("DELETE FROM #{SCHEMA}.links WHERE source_id = $1", [document.id])
      document.links.each_with_index do |link, position|
        target = connection.exec_params(
          "SELECT id FROM #{SCHEMA}.pages WHERE page_type = 'named' AND name = $1 LIMIT 1",
          [link.name]
        )
        target_id = target.ntuples.zero? ? nil : target[0].fetch("id")
        connection.exec_params(
          <<~SQL,
            INSERT INTO #{SCHEMA}.links (source_id, target_id, target_name, position)
            VALUES ($1, $2, $3, $4)
          SQL
          [document.id, target_id, link.name, position]
        )
      end
    end

    def page_values(document)
      [
        document.id,
        document.page_type,
        document.name,
        document.page_date&.iso8601,
        document.title,
        document.status,
        document.created_at,
        document.updated_at,
        document.published_at,
        document.path.to_s,
        Digest::SHA256.hexdigest(document.body),
        document.empty?,
        document.body,
      ]
    end

    def page_from_row(row)
      body = row.fetch("body")
      PageDocument.new(
        id: row.fetch("id"),
        page_type: row.fetch("page_type"),
        name: row["name"],
        page_date: row["page_date"] && Date.iso8601(row.fetch("page_date")),
        title: row["title"],
        status: row.fetch("status"),
        created_at: parse_time(row.fetch("created_at")),
        updated_at: parse_time(row.fetch("updated_at")),
        published_at: row["published_at"] && parse_time(row.fetch("published_at")),
        path: Pathname(row.fetch("path")),
        body:,
        links: WeblogAuthoring.extract_wiki_links(body)
      )
    end

    def select_sql(condition)
      <<~SQL.chomp
        SELECT id, page_type, name, page_date, title, status,
               created_at, updated_at, published_at, path, body
        FROM #{SCHEMA}.pages
        WHERE #{condition} = $1
      SQL
    end

    def validate_expected_update(current, request)
      return if request.expected_updated_at.nil? || request.expected_updated_at == current.updated_at

      raise ConflictError, "ページが別の編集で更新されています"
    end

    def now
      value = @clock.call
      raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

      value.getlocal(TOKYO_OFFSET)
    end

    def parse_time(value)
      value.is_a?(Time) ? value : Time.parse(value)
    end

    def with_connection(&)
      @pool.with(&)
    end
  end
end
