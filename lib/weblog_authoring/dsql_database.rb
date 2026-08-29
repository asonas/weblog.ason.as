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

    def list_pages(limit: nil, before: nil, after: nil, kind: nil)
      with_connection do |connection|
        sql = <<~SQL
          SELECT id, page_type, name, page_date, title, status,
                 created_at, updated_at, published_at, path, body
          FROM #{SCHEMA}.pages
        SQL
        conditions = []
        values = []
        if kind
          values << "日記"
          exists = "EXISTS (SELECT 1 FROM #{SCHEMA}.links WHERE links.source_id = pages.id AND links.target_name = $#{values.length})"
          conditions << (kind == "diary" ? exists : "NOT #{exists}")
        end
        if before
          values.concat([before.fetch(:updated_at).iso8601(9), before.fetch(:id)])
          conditions << "(updated_at < $#{values.length - 1} OR (updated_at = $#{values.length - 1} AND id < $#{values.length}))"
        elsif after
          values.concat([after.fetch(:updated_at).iso8601(9), after.fetch(:id)])
          conditions << "(updated_at > $#{values.length - 1} OR (updated_at = $#{values.length - 1} AND id > $#{values.length}))"
        end
        sql += "WHERE #{conditions.join(' AND ')}\n" unless conditions.empty?
        sql += "ORDER BY updated_at #{after ? 'ASC' : 'DESC'}, id #{after ? 'ASC' : 'DESC'}\n"
        if limit
          values << limit
          sql += "LIMIT $#{values.length}\n"
        end
        result = values.empty? ? connection.exec(sql) : connection.exec_params(sql, values)
        pages = result.map { |row| page_from_row(row) }
        after ? pages.reverse : pages
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
            record_inbox_item_usage_with_connection(connection, item_id, document.id)
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

    def create_mobile_pairing(code_digest:, expires_at:)
      timestamp = now
      with_connection do |connection|
        connection.transaction do
          connection.exec_params(
            "UPDATE #{SCHEMA}.mobile_pairings SET used_at = $1 WHERE used_at IS NULL",
            [timestamp]
          )
          connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.mobile_pairings (
                id, code_digest, attempts, expires_at, used_at, created_at
              ) VALUES ($1, $2, 0, $3, NULL, $4)
            SQL
            [SecureRandom.uuid.delete("-"), code_digest, expires_at, timestamp]
          )
        end
      end
    end

    def exchange_mobile_pairing(code_digest:, device_name:, token_digest:)
      timestamp = now
      with_connection do |connection|
        connection.transaction do
          pairing = connection.exec_params(
            <<~SQL,
              SELECT id FROM #{SCHEMA}.mobile_pairings
              WHERE code_digest = $1 AND used_at IS NULL AND expires_at > $2 AND attempts < 5
              LIMIT 1 FOR UPDATE
            SQL
            [code_digest, timestamp]
          )
          if pairing.ntuples.zero?
            candidate = connection.exec_params(
              <<~SQL,
                SELECT id, attempts FROM #{SCHEMA}.mobile_pairings
                WHERE used_at IS NULL AND expires_at > $1
                ORDER BY created_at DESC LIMIT 1 FOR UPDATE
              SQL
              [timestamp]
            )
            next nil if candidate.ntuples.zero?

            attempts = Integer(candidate[0].fetch("attempts")) + 1
            connection.exec_params(
              "UPDATE #{SCHEMA}.mobile_pairings SET attempts = $2 WHERE id = $1",
              [candidate[0].fetch("id"), attempts]
            )
            next(attempts >= 5 ? :too_many_attempts : nil)
          end

          device = {
            "id" => SecureRandom.uuid.delete("-"), "name" => device_name,
            "created_at" => timestamp.iso8601, "last_used_at" => nil, "revoked_at" => nil,
          }
          connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.mobile_devices (
                id, name, token_digest, created_at, last_used_at, revoked_at
              ) VALUES ($1, $2, $3, $4, NULL, NULL)
            SQL
            [device.fetch("id"), device_name, token_digest, timestamp]
          )
          connection.exec_params(
            "UPDATE #{SCHEMA}.mobile_pairings SET used_at = $2 WHERE id = $1",
            [pairing[0].fetch("id"), timestamp]
          )
          device
        end
      end
    end

    def revoke_mobile_device(id)
      with_connection do |connection|
        result = connection.exec_params(
          "UPDATE #{SCHEMA}.mobile_devices SET revoked_at = $2 WHERE id = $1 AND revoked_at IS NULL",
          [id, now]
        )
        result.cmd_tuples.positive?
      end
    end

    def active_mobile_devices
      with_connection do |connection|
        connection.exec(
          "SELECT id, name, token_digest, created_at, last_used_at, revoked_at FROM #{SCHEMA}.mobile_devices WHERE revoked_at IS NULL"
        ).map do |row|
          {
            "id" => row.fetch("id"), "name" => row.fetch("name"), "token_digest" => row.fetch("token_digest"),
            "created_at" => row.fetch("created_at"), "last_used_at" => row["last_used_at"], "revoked_at" => row["revoked_at"],
          }
        end
      end
    end

    def touch_mobile_device(id)
      with_connection do |connection|
        connection.exec_params("UPDATE #{SCHEMA}.mobile_devices SET last_used_at = $2 WHERE id = $1", [id, now])
      end
    end

    def create_mobile_upload(device_id:, upload_id:, s3_key:, client_upload_id:, content_type:, size:, sha256:,
                             captured_at:, captured_at_source:)
      timestamp = now
      with_connection do |connection|
        connection.transaction do
          existing = connection.exec_params(
            "SELECT #{mobile_upload_columns} FROM #{SCHEMA}.mobile_uploads WHERE device_id = $1 AND client_upload_id = $2 LIMIT 1 FOR UPDATE",
            [device_id, client_upload_id]
          )
          if existing.ntuples.positive?
            upload = mobile_upload_from_row(existing[0])
            expected = [content_type, size, sha256, captured_at&.iso8601, captured_at_source]
            actual = upload.values_at("content_type", "size", "sha256", "captured_at", "captured_at_source")
            raise ConflictError, "client_upload_id metadata conflict" unless actual == expected

            next [upload, false]
          end

          result = connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.mobile_uploads (
                id, device_id, client_upload_id, s3_key, content_type, size, sha256,
                captured_at, captured_at_source, state, created_at, completed_at
              ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'awaiting_upload', $10, NULL)
              RETURNING #{mobile_upload_columns}
            SQL
            [upload_id, device_id, client_upload_id, s3_key, content_type, size, sha256,
             captured_at, captured_at_source, timestamp]
          )
          [mobile_upload_from_row(result[0]), true]
        end
      end
    end

    def find_mobile_upload(upload_id:, device_id:)
      with_connection do |connection|
        result = connection.exec_params(
          "SELECT #{mobile_upload_columns} FROM #{SCHEMA}.mobile_uploads WHERE id = $1 AND device_id = $2 LIMIT 1",
          [upload_id, device_id]
        )
        result.ntuples.zero? ? nil : mobile_upload_from_row(result[0])
      end
    end

    def find_inbox_item_by_source(source:, kind:, source_id:)
      with_connection do |connection|
        result = connection.exec_params(
          "SELECT id, source, kind, source_id, occurred_at, ingested_at, expires_at, payload, created_at, updated_at FROM #{SCHEMA}.inbox_items WHERE source = $1 AND kind = $2 AND source_id = $3 LIMIT 1",
          [source, kind, source_id]
        )
        result.ntuples.zero? ? nil : inbox_item_from_row(result[0])
      end
    end

    def complete_mobile_upload(upload_id:, device_id:)
      timestamp = now
      with_connection do |connection|
        connection.transaction do
          result = connection.exec_params(
            "SELECT #{mobile_upload_columns} FROM #{SCHEMA}.mobile_uploads WHERE id = $1 AND device_id = $2 LIMIT 1 FOR UPDATE",
            [upload_id, device_id]
          )
          next nil if result.ntuples.zero?

          upload = mobile_upload_from_row(result[0])
          existing = connection.exec_params(
            "SELECT id, source, kind, source_id, occurred_at, ingested_at, expires_at, payload, created_at, updated_at FROM #{SCHEMA}.inbox_items WHERE source = 'photo' AND kind = 'photo' AND source_id = $1 LIMIT 1",
            [upload_id]
          )
          next [inbox_item_from_row(existing[0]), false] if existing.ntuples.positive?

          payload = JSON.generate(
            "inbox_key" => upload.fetch("s3_key"), "preview_url" => "/#{upload.fetch("s3_key")}",
            "captured_at_source" => upload.fetch("captured_at_source")
          )
          item = connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.inbox_items (
                id, source, kind, source_id, occurred_at, ingested_at, expires_at,
                payload, created_at, updated_at
              ) VALUES ($1, 'photo', 'photo', $2, $3, $4, $5, $6::jsonb, $4, $4)
              RETURNING id, source, kind, source_id, occurred_at, ingested_at,
                        expires_at, payload, created_at, updated_at
            SQL
            [SecureRandom.uuid.delete("-"), upload_id, upload.fetch("captured_at") ? parse_time(upload.fetch("captured_at")) : timestamp, timestamp,
             timestamp + INBOX_RETENTION_SECONDS, payload]
          )
          connection.exec_params(
            "UPDATE #{SCHEMA}.mobile_uploads SET state = 'completed', captured_at = COALESCE(captured_at, $2), completed_at = $2 WHERE id = $1",
            [upload_id, timestamp]
          )
          [inbox_item_from_row(item[0]), true]
        end
      end
    end

    def cleanup_mobile_uploads(limit: 100)
      raise ArgumentError, "limit must be positive" unless limit.is_a?(Integer) && limit.positive?

      timestamp = now
      with_connection do |connection|
        connection.transaction do
          uploads = connection.exec_params(
            <<~SQL,
              DELETE FROM #{SCHEMA}.mobile_uploads
              WHERE id IN (
                SELECT id FROM #{SCHEMA}.mobile_uploads
                WHERE state != 'completed' AND created_at <= $1
                ORDER BY created_at LIMIT $2
              )
            SQL
            [timestamp - INBOX_RETENTION_SECONDS, limit]
          )
          connection.exec_params(
            "DELETE FROM #{SCHEMA}.mobile_pairings WHERE expires_at <= $1",
            [timestamp]
          )
          uploads.cmd_tuples
        end
      end
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

    def start_inbox_sync_run(run_id:, trigger:, started_at:)
      with_connection do |connection|
        connection.transaction do
          connection.exec_params(
            <<~SQL,
              DELETE FROM #{SCHEMA}.inbox_sync_run_sources
              WHERE run_id IN (
                SELECT id FROM #{SCHEMA}.inbox_sync_runs WHERE expires_at <= $1
              )
            SQL
            [started_at]
          )
          connection.exec_params(
            "DELETE FROM #{SCHEMA}.inbox_sync_runs WHERE expires_at <= $1",
            [started_at]
          )
          active = connection.exec(
            "SELECT id FROM #{SCHEMA}.inbox_sync_runs WHERE status IN ('queued', 'running') ORDER BY started_at LIMIT 1"
          )
          next false if active.ntuples.positive? && active[0].fetch("id") != run_id

          connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.inbox_sync_runs (
                id, trigger, status, started_at, completed_at, expires_at
              ) VALUES ($1, $2, 'running', $3, NULL, $4)
              ON CONFLICT (id) DO UPDATE
              SET status = 'running',
                  started_at = EXCLUDED.started_at,
                  completed_at = NULL,
                  expires_at = EXCLUDED.expires_at
            SQL
            [run_id, trigger, started_at, started_at + 86_400]
          )
          true
        end
      end
    end

    def queue_inbox_sync_run(run_id:, trigger:, queued_at:)
      with_connection do |connection|
        connection.transaction do
          connection.exec_params(
            <<~SQL,
              DELETE FROM #{SCHEMA}.inbox_sync_run_sources
              WHERE run_id IN (
                SELECT id FROM #{SCHEMA}.inbox_sync_runs WHERE expires_at <= $1
              )
            SQL
            [queued_at]
          )
          connection.exec_params("DELETE FROM #{SCHEMA}.inbox_sync_runs WHERE expires_at <= $1", [queued_at])
          active = connection.exec(
            "SELECT 1 FROM #{SCHEMA}.inbox_sync_runs WHERE status IN ('queued', 'running') LIMIT 1"
          )
          next false if active.ntuples.positive?

          connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.inbox_sync_runs (
                id, trigger, status, started_at, completed_at, expires_at
              ) VALUES ($1, $2, 'queued', $3, NULL, $4)
            SQL
            [run_id, trigger, queued_at, queued_at + 86_400]
          )
          true
        end
      end
    end

    def inbox_sync_run(run_id:)
      with_connection do |connection|
        result = connection.exec_params(
          <<~SQL,
            SELECT id, trigger, status, started_at, completed_at
            FROM #{SCHEMA}.inbox_sync_runs
            WHERE id = $1
            LIMIT 1
          SQL
          [run_id]
        )
        next nil if result.ntuples.zero?

        row = result[0]
        sources = connection.exec_params(
          <<~SQL,
            SELECT source, status, fetched_count, created_count, updated_count,
                   deleted_count, error, completed_at
            FROM #{SCHEMA}.inbox_sync_run_sources
            WHERE run_id = $1
            ORDER BY completed_at, source
          SQL
          [run_id]
        ).map do |source|
          {
            "source" => source.fetch("source"), "status" => source.fetch("status"),
            "fetched_count" => Integer(source.fetch("fetched_count")),
            "created_count" => Integer(source.fetch("created_count")),
            "updated_count" => Integer(source.fetch("updated_count")),
            "deleted_count" => Integer(source.fetch("deleted_count")),
            "error" => source["error"], "completed_at" => source.fetch("completed_at"),
          }
        end
        {
          "id" => row.fetch("id"), "trigger" => row.fetch("trigger"), "status" => row.fetch("status"),
          "started_at" => row.fetch("started_at"), "completed_at" => row["completed_at"], "sources" => sources,
        }
      end
    end

    def inbox_source_sync_state(source:)
      with_connection do |connection|
        result = connection.exec_params(
          <<~SQL,
            SELECT source, last_attempted_at, last_succeeded_at, watermark, last_error, updated_at
            FROM #{SCHEMA}.inbox_source_sync_states
            WHERE source = $1
            LIMIT 1
          SQL
          [source]
        )
        next nil if result.ntuples.zero?

        row = result[0]
        {
          "source" => row.fetch("source"),
          "last_attempted_at" => row.fetch("last_attempted_at"),
          "last_succeeded_at" => row["last_succeeded_at"],
          "watermark" => row["watermark"],
          "last_error" => row["last_error"],
          "updated_at" => row.fetch("updated_at"),
        }
      end
    end

    def apply_inbox_source_snapshot(run_id:, source:, snapshot:, completed_at:)
      with_connection do |connection|
        connection.transaction do
          counts = { created_count: 0, updated_count: 0, deleted_count: 0 }
          snapshot.items.each do |item|
            suppressed = connection.exec_params(
              <<~SQL,
                SELECT 1 FROM #{SCHEMA}.consumed_inbox_items
                WHERE source = $1 AND kind = $2 AND source_id = $3 AND expires_at > $4
                LIMIT 1
              SQL
              [source, item.kind, item.source_id, completed_at]
            )
            next if suppressed.ntuples.positive?

            existing = connection.exec_params(
              "SELECT 1 FROM #{SCHEMA}.inbox_items WHERE source = $1 AND kind = $2 AND source_id = $3 LIMIT 1",
              [source, item.kind, item.source_id]
            )
            connection.exec_params(
              <<~SQL,
                INSERT INTO #{SCHEMA}.inbox_items (
                  source, kind, source_id, occurred_at, payload, id, ingested_at,
                  expires_at, created_at, updated_at
                ) VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $7, $7)
                ON CONFLICT (source, kind, source_id) DO UPDATE
                SET occurred_at = EXCLUDED.occurred_at,
                    payload = EXCLUDED.payload,
                    updated_at = EXCLUDED.updated_at
              SQL
              [
                source, item.kind, item.source_id, item.occurred_at, JSON.generate(item.payload),
                SecureRandom.uuid.delete("-"), completed_at, completed_at + INBOX_RETENTION_SECONDS,
              ]
            )
            counts[existing.ntuples.positive? ? :updated_count : :created_count] += 1
          end

          if snapshot.complete
            identities = snapshot.items.map { |item| [item.kind, item.source_id] }
            deletion = if identities.empty?
                         connection.exec_params("DELETE FROM #{SCHEMA}.inbox_items WHERE source = $1", [source])
                       else
                         retained = identities.each_index.map do |index|
                           offset = (index * 2) + 2
                           "(kind = $#{offset} AND source_id = $#{offset + 1})"
                         end.join(" OR ")
                         connection.exec_params(
                           "DELETE FROM #{SCHEMA}.inbox_items WHERE source = $1 AND NOT (#{retained})",
                           [source, *identities.flatten]
                         )
                       end
            counts[:deleted_count] = deletion.cmd_tuples
          end

          record_inbox_source_success(connection, run_id:, source:, snapshot:, counts:, completed_at:)
          counts
        end
      end
    end

    def fail_inbox_source_sync(run_id:, source:, error:, completed_at:)
      with_connection do |connection|
        connection.transaction do
          connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.inbox_sync_run_sources (
                run_id, source, status, fetched_count, created_count, updated_count,
                deleted_count, error, completed_at
              ) VALUES ($1, $2, 'failed', 0, 0, 0, 0, $3, $4)
            SQL
            [run_id, source, error, completed_at]
          )
          connection.exec_params(
            <<~SQL,
              INSERT INTO #{SCHEMA}.inbox_source_sync_states (
                source, last_attempted_at, last_succeeded_at, watermark, last_error, updated_at
              ) VALUES ($1, $2, NULL, NULL, $3, $2)
              ON CONFLICT (source) DO UPDATE
              SET last_attempted_at = EXCLUDED.last_attempted_at,
                  last_error = EXCLUDED.last_error,
                  updated_at = EXCLUDED.updated_at
            SQL
            [source, completed_at, error]
          )
        end
      end
    end

    def finish_inbox_sync_run(run_id:, status:, completed_at:)
      with_connection do |connection|
        connection.exec_params(
          "UPDATE #{SCHEMA}.inbox_sync_runs SET status = $2, completed_at = $3 WHERE id = $1",
          [run_id, status, completed_at]
        )
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

    def list_inbox_item_usages
      with_connection do |connection|
        connection.exec_params(
          <<~SQL,
            SELECT usage.item_id, usage.page_id,
                   COALESCE(page.name, page.page_date::text) AS page_route,
                   usage.used_at
            FROM #{SCHEMA}.inbox_item_usages usage
            JOIN #{SCHEMA}.pages page ON page.id = usage.page_id
            WHERE usage.expires_at > $1
            ORDER BY usage.used_at, usage.item_id, usage.page_id
          SQL
          [now]
        ).map do |row|
          InboxItemUsage.new(
            item_id: row.fetch("item_id"), page_id: row.fetch("page_id"),
            page_route: row.fetch("page_route"), used_at: parse_time(row.fetch("used_at"))
          )
        end
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
          connection.exec_params(
            "DELETE FROM #{SCHEMA}.inbox_item_usages WHERE expires_at <= $1",
            [timestamp]
          )
          { inbox_items: inbox.cmd_tuples, consumed_items: consumed.cmd_tuples }
        end
      end
    end

    private

    def record_inbox_source_success(connection, run_id:, source:, snapshot:, counts:, completed_at:)
      connection.exec_params(
        <<~SQL,
          INSERT INTO #{SCHEMA}.inbox_sync_run_sources (
            run_id, source, status, fetched_count, created_count, updated_count,
            deleted_count, error, completed_at
          ) VALUES ($1, $2, 'succeeded', $3, $4, $5, $6, NULL, $7)
        SQL
        [
          run_id, source, snapshot.items.length, counts.fetch(:created_count),
          counts.fetch(:updated_count), counts.fetch(:deleted_count), completed_at,
        ]
      )
      connection.exec_params(
        <<~SQL,
          INSERT INTO #{SCHEMA}.inbox_source_sync_states (
            source, last_attempted_at, last_succeeded_at, watermark, last_error, updated_at
          ) VALUES ($1, $2, $2, $3, NULL, $2)
          ON CONFLICT (source) DO UPDATE
          SET last_attempted_at = EXCLUDED.last_attempted_at,
              last_succeeded_at = EXCLUDED.last_succeeded_at,
              watermark = EXCLUDED.watermark,
              last_error = NULL,
              updated_at = EXCLUDED.updated_at
        SQL
        [source, completed_at, snapshot.watermark]
      )
    end

    def record_inbox_item_usage_with_connection(connection, id, page_id)
      timestamp = now
      result = connection.exec_params(
        <<~SQL,
          SELECT id, source, kind, expires_at
          FROM #{SCHEMA}.inbox_items
          WHERE id = $1 AND expires_at > $2
          LIMIT 1
          FOR UPDATE
        SQL
        [id, timestamp]
      )
      raise ConflictError, "inbox_item_expired" if result.ntuples.zero?

      item = result[0]
      if item.fetch("source") == "photo" && item.fetch("kind") == "photo"
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
          INSERT INTO #{SCHEMA}.inbox_item_usages (item_id, page_id, used_at, expires_at)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (item_id, page_id) DO UPDATE SET used_at = EXCLUDED.used_at
        SQL
        [id, page_id, timestamp, item.fetch("expires_at")]
      )
      connection.exec_params(
        "UPDATE #{SCHEMA}.inbox_image_adoptions SET committed_at = $2 WHERE item_id = $1",
        [id, timestamp]
      )
    end

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

    def mobile_upload_columns
      "id, device_id, client_upload_id, s3_key, content_type, size, sha256, captured_at, captured_at_source, state, created_at, completed_at"
    end

    def mobile_upload_from_row(row)
      {
        "id" => row.fetch("id"), "device_id" => row.fetch("device_id"),
        "client_upload_id" => row.fetch("client_upload_id"), "s3_key" => row.fetch("s3_key"),
        "content_type" => row.fetch("content_type"), "size" => Integer(row.fetch("size")),
        "sha256" => row.fetch("sha256"),
        "captured_at" => row["captured_at"] && parse_time(row.fetch("captured_at")).iso8601,
        "captured_at_source" => row.fetch("captured_at_source"), "state" => row.fetch("state"),
        "created_at" => parse_time(row.fetch("created_at")).iso8601,
        "completed_at" => row["completed_at"] && parse_time(row.fetch("completed_at")).iso8601,
      }
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
