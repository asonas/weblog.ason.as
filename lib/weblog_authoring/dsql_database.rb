# frozen_string_literal: true

require "date"
require "digest"
require "json"
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
    INBOX_RETENTION_SECONDS = 7 * 24 * 60 * 60
    ADOPTION_RETENTION_SECONDS = 14 * 24 * 60 * 60
    INBOX_KINDS = {
      "photo" => ["photo"],
      "bluesky" => %w[post like],
      "raindrop" => ["bookmark"],
      "c4p" => ["track"]
    }.freeze
    INBOX_PAYLOAD_KEYS = {
      ["photo", "photo"] => %w[inbox_key preview_url captured_at_source],
      ["bluesky", "post"] => %w[record_uri record_cid canonical_url author_did],
      ["bluesky", "like"] => %w[like_uri like_cid subject_uri subject_cid canonical_url author_did],
      ["raindrop", "bookmark"] => %w[raindrop_id url title],
      ["c4p", "track"] => %w[guid permalink title audio_url duration_seconds]
    }.freeze
    INBOX_PAYLOAD_TYPES = {
      ["photo", "photo"] => { "inbox_key" => String, "preview_url" => String, "captured_at_source" => String },
      ["bluesky", "post"] => %w[record_uri record_cid canonical_url author_did].to_h { |key| [key, String] },
      ["bluesky", "like"] => %w[like_uri like_cid subject_uri subject_cid canonical_url author_did].to_h { |key| [key, String] },
      ["raindrop", "bookmark"] => { "raindrop_id" => Integer, "url" => String, "title" => String },
      ["c4p", "track"] => { "guid" => String, "permalink" => String, "title" => String, "audio_url" => String, "duration_seconds" => Integer }
    }.freeze

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

    def list_pages(limit: nil)
      with_connection do |connection|
        sql = <<~SQL
          SELECT id, page_type, name, page_date, title, status,
                 created_at, updated_at, published_at, path, body
          FROM #{SCHEMA}.pages
          ORDER BY created_at DESC, updated_at DESC
        SQL
        sql += "LIMIT $1\n" if limit
        result = limit ? connection.exec_params(sql, [limit]) : connection.exec(sql)
        result.map { |row| page_from_row(row) }
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
          request.consumed_inbox_item_ids.each do |item_id|
            consume_inbox_item_with_connection(connection, item_id, required: true)
          end
        end
      end

      find(document.id)
    rescue PG::UniqueViolation => error
      raise ConflictError, "ページの保存に失敗しました: #{error.message}"
    end

    def close
      @pool.shutdown
    end

    def upsert_inbox_item(source:, kind:, source_id:, occurred_at:, payload:)
      validate_inbox_identity!(source, kind, source_id)
      raise ArgumentError, "occurred_at must be a Time" unless occurred_at.is_a?(Time)
      raise ArgumentError, "payload must be a Hash" unless payload.is_a?(Hash)
      missing_keys = INBOX_PAYLOAD_KEYS.fetch([source, kind]) - payload.keys
      raise ArgumentError, "missing inbox payload keys: #{missing_keys.join(', ')}" unless missing_keys.empty?
      invalid_keys = INBOX_PAYLOAD_TYPES.fetch([source, kind]).filter_map do |key, type|
        key unless payload.fetch(key).is_a?(type)
      end
      raise ArgumentError, "invalid inbox payload values: #{invalid_keys.join(', ')}" unless invalid_keys.empty?

      timestamp = now
      with_connection do |connection|
        connection.transaction do
          consumed = connection.exec_params(
            <<~SQL,
              SELECT 1 FROM #{SCHEMA}.consumed_inbox_items
              WHERE source = $1 AND kind = $2 AND source_id = $3 AND expires_at > $4
              LIMIT 1
            SQL
            [source, kind, source_id, timestamp]
          )
          next nil if consumed.ntuples.positive?

          result = connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.inbox_items (
                source, kind, source_id, occurred_at, payload, id, ingested_at,
                expires_at, created_at, updated_at
              ) VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $7, $7)
              ON CONFLICT (source, kind, source_id) DO UPDATE
              SET occurred_at = EXCLUDED.occurred_at,
                  payload = EXCLUDED.payload,
                  updated_at = EXCLUDED.updated_at
              RETURNING id, source, kind, source_id, occurred_at, ingested_at,
                        expires_at, payload, created_at, updated_at
            SQL
            [
              source, kind, source_id, occurred_at, JSON.generate(payload),
              SecureRandom.uuid.delete("-"), timestamp, timestamp + INBOX_RETENTION_SECONDS
            ]
          )
          inbox_item_from_row(result[0])
        end
      end
    end

    def list_inbox_items(source: nil, kind: nil)
      timestamp = now
      with_connection do |connection|
        clauses = ["expires_at > $1"]
        values = [timestamp]
        unless source.nil?
          values << source
          clauses << "source = $#{values.length}"
        end
        unless kind.nil?
          values << kind
          clauses << "kind = $#{values.length}"
        end
        connection.exec_params(
          <<~SQL,
            SELECT id, source, kind, source_id, occurred_at, ingested_at,
                   expires_at, payload, created_at, updated_at
            FROM #{SCHEMA}.inbox_items
            WHERE #{clauses.join(' AND ')}
            ORDER BY occurred_at DESC, ingested_at DESC, id DESC
          SQL
          values
        ).map { |row| inbox_item_from_row(row) }
      end
    end

    def find_inbox_item(id)
      timestamp = now
      with_connection do |connection|
        result = connection.exec_params(
          <<~SQL,
            SELECT id, source, kind, source_id, occurred_at, ingested_at,
                   expires_at, payload, created_at, updated_at
            FROM #{SCHEMA}.inbox_items
            WHERE id = $1 AND expires_at > $2
            LIMIT 1
          SQL
          [id, timestamp]
        )
        result.ntuples.zero? ? nil : inbox_item_from_row(result[0])
      end
    end

    def prepare_inbox_image_adoption(item_id:, inbox_key:, public_key:)
      timestamp = now
      with_connection do |connection|
        result = connection.exec_params(
          <<~SQL,
            INSERT INTO #{SCHEMA}.inbox_image_adoptions (
              item_id, inbox_key, public_key, prepared_at, committed_at, expires_at
            ) VALUES ($1, $2, $3, $4, NULL, $5)
            ON CONFLICT (item_id) DO UPDATE SET item_id = EXCLUDED.item_id
            RETURNING item_id, inbox_key, public_key, prepared_at, committed_at, expires_at
          SQL
          [item_id, inbox_key, public_key, timestamp, timestamp + ADOPTION_RETENTION_SECONDS]
        )
        inbox_image_adoption_from_row(result[0])
      end
    end

    def consume_inbox_item(id)
      with_connection do |connection|
        connection.transaction do
          consume_inbox_item_with_connection(connection, id, required: false)
        end
      end
    end

    def list_pending_inbox_image_finalizations(limit: 100)
      raise ArgumentError, "limit must be positive" unless limit.is_a?(Integer) && limit.positive?

      with_connection do |connection|
        connection.exec_params(
          <<~SQL,
            SELECT item_id, inbox_key, public_key, prepared_at, committed_at, expires_at
            FROM #{SCHEMA}.inbox_image_adoptions
            WHERE committed_at IS NOT NULL AND expires_at > $1
            ORDER BY committed_at, item_id
            LIMIT $2
          SQL
          [now, limit]
        ).map { |row| inbox_image_adoption_from_row(row) }
      end
    end

    def complete_inbox_image_adoption(item_id:)
      with_connection do |connection|
        connection.exec_params("DELETE FROM #{SCHEMA}.inbox_image_adoptions WHERE item_id = $1", [item_id])
      end
    end

    def cleanup_inbox_items(limit: 100)
      raise ArgumentError, "limit must be positive" unless limit.is_a?(Integer) && limit.positive?

      timestamp = now
      with_connection do |connection|
        connection.transaction do
          inbox = connection.exec_params(
            <<~SQL,
              DELETE FROM #{SCHEMA}.inbox_items
              WHERE id IN (
                SELECT id FROM #{SCHEMA}.inbox_items
                WHERE expires_at <= $1 ORDER BY expires_at LIMIT $2
              )
            SQL
            [timestamp, limit]
          )
          consumed = connection.exec_params(
            <<~SQL,
              DELETE FROM #{SCHEMA}.consumed_inbox_items
              WHERE (source, kind, source_id) IN (
                SELECT source, kind, source_id FROM #{SCHEMA}.consumed_inbox_items
                WHERE expires_at <= $1 ORDER BY expires_at LIMIT $2
              )
            SQL
            [timestamp, limit]
          )
          connection.exec_params(
            "DELETE FROM #{SCHEMA}.inbox_image_adoptions WHERE expires_at <= $1",
            [timestamp]
          )
          { inbox_items: inbox.cmd_tuples, consumed_items: consumed.cmd_tuples }
        end
      end
    end

    private

    def consume_inbox_item_with_connection(connection, id, required:)
      timestamp = now
      result = connection.exec_params(
        <<~SQL,
          SELECT id, source, kind, source_id, occurred_at, ingested_at,
                 expires_at, payload, created_at, updated_at
          FROM #{SCHEMA}.inbox_items
          WHERE id = $1 AND expires_at > $2
          LIMIT 1
          FOR UPDATE
        SQL
        [id, timestamp]
      )
      if result.ntuples.zero?
        raise ConflictError, "inbox_item_expired" if required

        return false
      end

      item = inbox_item_from_row(result[0])
      if item.source == "photo" && item.kind == "photo"
        adoption = connection.exec_params(
          <<~SQL,
            SELECT 1 FROM #{SCHEMA}.inbox_image_adoptions
            WHERE item_id = $1 AND expires_at > $2
            LIMIT 1
          SQL
          [id, timestamp]
        )
        raise ConflictError, "inbox_item_expired" if adoption.ntuples.zero?
      end

      connection.exec_params(
        <<~SQL,
          INSERT INTO #{SCHEMA}.consumed_inbox_items (
            source, kind, source_id, consumed_at, expires_at
          )
          SELECT source, kind, source_id, $2, expires_at
          FROM #{SCHEMA}.inbox_items WHERE id = $1
          ON CONFLICT (source, kind, source_id) DO UPDATE
          SET consumed_at = EXCLUDED.consumed_at,
              expires_at = EXCLUDED.expires_at
        SQL
        [id, timestamp]
      )
      connection.exec_params(
        "UPDATE #{SCHEMA}.inbox_image_adoptions SET committed_at = $2 WHERE item_id = $1",
        [id, timestamp]
      )
      connection.exec_params("DELETE FROM #{SCHEMA}.inbox_items WHERE id = $1", [id])
      true
    end

    def validate_inbox_identity!(source, kind, source_id)
      raise ArgumentError, "unknown inbox source and kind" unless INBOX_KINDS.fetch(source, []).include?(kind)
      raise ArgumentError, "source_id must not be empty" if source_id.to_s.empty?
    end

    def inbox_item_from_row(row)
      payload = row.fetch("payload")
      InboxItem.new(
        id: row.fetch("id"), source: row.fetch("source"), kind: row.fetch("kind"),
        source_id: row.fetch("source_id"), occurred_at: parse_time(row.fetch("occurred_at")),
        ingested_at: parse_time(row.fetch("ingested_at")), expires_at: parse_time(row.fetch("expires_at")),
        payload: payload.is_a?(String) ? JSON.parse(payload) : payload,
        created_at: parse_time(row.fetch("created_at")), updated_at: parse_time(row.fetch("updated_at"))
      )
    end

    def inbox_image_adoption_from_row(row)
      InboxImageAdoption.new(
        item_id: row.fetch("item_id"),
        inbox_key: row.fetch("inbox_key"),
        public_key: row.fetch("public_key"),
        prepared_at: parse_time(row.fetch("prepared_at")),
        committed_at: row["committed_at"] && parse_time(row.fetch("committed_at")),
        expires_at: parse_time(row.fetch("expires_at"))
      )
    end

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
