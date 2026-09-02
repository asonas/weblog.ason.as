# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"
require "uri"

require_relative "cover_image"
require_relative "links"
require_relative "models"
require_relative "names"
require_relative "webmention_targets"

module WeblogAuthoring
  class DevelopmentDatabase
    SCHEMA_VERSION = 10
    INBOX_RETENTION_SECONDS = 7 * 24 * 60 * 60
    ADOPTION_RETENTION_SECONDS = 14 * 24 * 60 * 60
    TOKYO_OFFSET = "+09:00"

    attr_reader :path

    def initialize(path, content_dir:, site_url: "https://weblog.ason.as", clock: -> { Time.now.getlocal(TOKYO_OFFSET) })
      @path = Pathname(path)
      @content_dir = Pathname(content_dir)
      @clock = clock
      @site_url = site_url
      @webmention_targets = WebmentionTargets.new(site_url:)
    end

    def setup!
      with_connection { |database| create_schema(database) }
    end

    def list_pages(limit: nil, before: nil, after: nil, kind: nil)
      with_connection do |database|
        order_column = kind == "diary" ? "created_at" : "updated_at"
        sql = <<~SQL
            SELECT id, page_type, name, page_date, title, status,
                   created_at, updated_at, published_at, path, body, cover_mode, cover_image_url
            FROM pages
        SQL
        conditions = []
        values = []
        if kind
          exists = "EXISTS (SELECT 1 FROM links WHERE links.source_id = pages.id AND links.target_name = ?)"
          conditions << (kind == "diary" ? exists : "NOT #{exists}")
          values << "日記"
        end
        if before
          conditions << "(#{order_column} < ? OR (#{order_column} = ? AND id < ?))"
          values.concat([before.fetch(:timestamp).iso8601(9), before.fetch(:timestamp).iso8601(9), before.fetch(:id)])
        elsif after
          conditions << "(#{order_column} > ? OR (#{order_column} = ? AND id > ?))"
          values.concat([after.fetch(:timestamp).iso8601(9), after.fetch(:timestamp).iso8601(9), after.fetch(:id)])
        end
        sql += "WHERE #{conditions.join(' AND ')}\n" unless conditions.empty?
        sql += "ORDER BY #{order_column} #{after ? 'ASC' : 'DESC'}, id #{after ? 'ASC' : 'DESC'}\n"
        if limit
          sql += "LIMIT ?\n"
          values << limit
        end
        pages = database.execute(sql, values).map { |row| page_from_row(row) }
        after ? pages.reverse : pages
      end
    end

    def find(id)
      with_connection do |database|
        row = database.get_first_row(select_sql("id"), id)
        row && page_from_row(row)
      end
    end

    def find_route(route)
      normalized_route = route.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      return nil if normalized_route.empty?

      with_connection do |database|
        row = database.get_first_row(
          <<~SQL,
            SELECT id, page_type, name, page_date, title, status,
                   created_at, updated_at, published_at, path, body, cover_mode, cover_image_url
            FROM pages
            WHERE (page_type = 'date' AND page_date = ?)
               OR (page_type = 'named' AND name = ?)
            LIMIT 1
          SQL
          [normalized_route, normalized_route]
        )
        row && page_from_row(row)
      end
    end

    def replace_scrapbox_line_metadata(page_id, body_hash:, lines:)
      with_connection do |database|
        database.transaction do
          database.execute("DELETE FROM scrapbox_line_metadata WHERE page_id = ?", page_id)
          lines.each_with_index do |line, line_index|
            database.execute(
              <<~SQL,
                INSERT INTO scrapbox_line_metadata (
                  page_id, body_hash, line_index, created_at, updated_at, user_id
                ) VALUES (?, ?, ?, ?, ?, ?)
              SQL
              [
                page_id,
                body_hash,
                line_index,
                serialize_time(line[:created_at]),
                serialize_time(line[:updated_at]),
                line[:user_id],
              ]
            )
          end
        end
      end
    end

    def scrapbox_line_metadata(page_id)
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT metadata.line_index, metadata.created_at, metadata.updated_at, metadata.user_id
            FROM scrapbox_line_metadata metadata
            JOIN pages ON pages.id = metadata.page_id AND pages.body_hash = metadata.body_hash
            WHERE metadata.page_id = ?
            ORDER BY metadata.line_index
          SQL
          page_id
        ).map do |line_index, created_at, updated_at, user_id|
          {
            line_index:,
            created_at: created_at && Time.iso8601(created_at),
            updated_at: updated_at && Time.iso8601(updated_at),
            user_id:,
          }
        end
      end
    end

    def save(request)
      current = request.page_id && find(request.page_id)
      current_line_metadata = current && scrapbox_line_metadata(current.id)
      document = current.nil? ? new_document(request) : updated_document(current, request)

      with_connection do |database|
        database.transaction do
          ensure_unique_route!(database, document, current)
          if current.nil?
            insert_page(database, document)
          else
            update_page(database, document)
          end
          replace_line_metadata_after_save(database, document, current, current_line_metadata || [])
          replace_links(database, document)
          enqueue_webmention_outbox(database, current, document)
          request.consumed_inbox_item_ids.each do |item_id|
            record_inbox_item_usage_with_connection(database, item_id, document.id)
          end
        end
      rescue SQLite3::ConstraintException => error
        raise ConflictError, "ページの保存に失敗しました: #{error.message}"
      end

      find(document.id)
    end

    def record_verified_webmention(job:, response:, title:, site_name:, content_hash:)
      timestamp = now
      with_connection do |database|
        database.transaction do
          relation = find_or_create_webmention_relation(database, job, timestamp)
          relation_id, moderation_status = relation.values_at("id", "moderation_status")
          if relation.fetch("verification_status") == "deleted"
            moderation_status = "pending"
            database.execute("UPDATE webmention_relations SET moderation_status = 'pending' WHERE id = ?", relation_id)
          end
          database.execute(
            <<~SQL,
              UPDATE webmention_relations SET
                verification_status = 'verified',
                first_verified_at = COALESCE(first_verified_at, ?),
                last_notified_at = ?, last_verified_at = ?, deleted_at = NULL,
                deletion_reason = NULL, updated_at = ?
              WHERE id = ?
            SQL
            [
              serialize_time(timestamp), job.fetch("received_at"), serialize_time(timestamp),
              serialize_time(timestamp), relation_id,
            ]
          )
          unless moderation_status == "rejected"
            upsert_webmention_snapshot(
              database, relation_id:, source_url: job.fetch("source"), title:, site_name:,
              content_hash:, timestamp:
            )
          end
          record_webmention_attempt(
            database, job:, relation_id:, result: "verified", response:, content_hash:, timestamp:
          )
        end
      end
    end

    def record_webmention_deletion(job:, response:, reason:)
      timestamp = now
      with_connection do |database|
        database.transaction do
          relation_id = database.get_first_value(
            "SELECT id FROM webmention_relations WHERE source_url = ? AND target_url = ?",
            [job.fetch("source"), job.fetch("target")]
          )
          if relation_id
            database.execute(
              <<~SQL,
                UPDATE webmention_relations SET
                  verification_status = 'deleted', last_notified_at = ?, last_verified_at = ?,
                  deleted_at = ?, deletion_reason = ?, updated_at = ? WHERE id = ?
              SQL
              [
                job.fetch("received_at"), serialize_time(timestamp), serialize_time(timestamp),
                reason, serialize_time(timestamp), relation_id,
              ]
            )
            database.execute("DELETE FROM webmention_snapshots WHERE relation_id = ?", relation_id)
          end
          record_webmention_attempt(database, job:, relation_id:, result: reason, response:, timestamp:)
        end
      end
    end

    def record_webmention_failure(job:, result:, message:)
      _message = message
      timestamp = now
      with_connection do |database|
        relation_id = database.get_first_value(
          "SELECT id FROM webmention_relations WHERE source_url = ? AND target_url = ?",
          [job.fetch("source"), job.fetch("target")]
        )
        record_webmention_attempt(database, job:, relation_id:, result:, timestamp:)
      end
    end

    def list_webmentions(moderation_status: nil, verification_status: nil)
      with_connection do |database|
        conditions = []
        values = []
        if moderation_status
          conditions << "relations.moderation_status = ?"
          values << moderation_status
        end
        if verification_status
          conditions << "relations.verification_status = ?"
          values << verification_status
        end
        where = conditions.empty? ? "" : "WHERE #{conditions.join(' AND ')}"
        database.execute(
          <<~SQL,
            SELECT relations.id, relations.source_url, relations.target_url,
                   relations.target_page_id, relations.verification_status,
                   relations.moderation_status, relations.first_verified_at,
                   relations.last_notified_at, relations.last_verified_at,
                   candidate.title, candidate.site_name, candidate.content_hash,
                   approved.title, approved.site_name, approved.content_hash
            FROM webmention_relations relations
            LEFT JOIN webmention_snapshots candidate
              ON candidate.relation_id = relations.id
             AND candidate.snapshot_kind = 'candidate' AND candidate.is_current = 1
            LEFT JOIN webmention_snapshots approved
              ON approved.relation_id = relations.id
             AND approved.snapshot_kind = 'approved' AND approved.is_current = 1
            #{where}
            ORDER BY relations.last_notified_at DESC, relations.id DESC
          SQL
          values
        ).map { |row| webmention_from_row(row) }
      end
    end

    def list_webmention_failures
      with_connection do |database|
        rows = database.execute(
          <<~SQL,
            SELECT id, job_id, source_url, target_url, target_page_id, result,
                   http_status, redirect_count, fetched_bytes, duration_ms, attempted_at
            FROM webmention_attempts
            WHERE result NOT IN ('verified', 'link_missing', 'source_gone') AND expires_at > ?
            ORDER BY attempted_at DESC, id DESC
          SQL
          serialize_time(now)
        )
        rows.each_with_object({}) do |row, failures|
          key = [row.fetch(2), row.fetch(3)]
          failures[key] ||= webmention_failure_from_row(row)
        end.values
      end
    end

    def webmention_reverification(id)
      mention = list_webmentions.find { |candidate| candidate.fetch("id") == id }
      if mention
        return {
          "source" => mention.fetch("source_url"), "target" => mention.fetch("target_url"),
          "target_page_id" => mention.fetch("target_page_id"),
        }
      end

      failure = list_webmention_failures.find { |candidate| candidate.fetch("id") == id }
      return nil unless failure

      {
        "source" => failure.fetch("source_url"), "target" => failure.fetch("target_url"),
        "target_page_id" => failure.fetch("target_page_id"),
      }
    end

    def stale_approved_webmentions(before:, limit:)
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT source_url, target_url, target_page_id
            FROM webmention_relations
            WHERE verification_status = 'verified' AND moderation_status = 'approved'
              AND last_verified_at <= ?
            ORDER BY last_verified_at, id LIMIT ?
          SQL
          [serialize_time(before), limit]
        ).map do |row|
          { "source" => row.fetch(0), "target" => row.fetch(1), "target_page_id" => row.fetch(2) }
        end
      end
    end

    def webmention_outbox(id)
      with_connection do |database|
        row = database.get_first_row(
          <<~SQL,
            SELECT id, event_type, page_id, payload, status, attempt_count, created_at, notified_at, completed_at
            FROM webmention_outbox WHERE id = ? AND status = 'pending'
          SQL
          id
        )
        row && webmention_outbox_from_row(row)
      end
    end

    def request_publication_refresh(page_id)
      page = find(page_id)
      raise KeyError, "Page not found" unless page

      with_connection do |database|
        database.transaction { enqueue_webmention_outbox(database, nil, page) }
      end
      pending_webmention_outbox_for_page(page_id)
    end

    def compact_webmention_outbox(dry_run: true)
      with_connection do |database|
        page_ids = database.execute(
          "SELECT DISTINCT page_id FROM webmention_outbox WHERE status = 'pending' ORDER BY page_id"
        ).flatten
        summary = { "pages" => page_ids.length, "superseded" => 0, "retained" => page_ids.length }
        next summary if dry_run

        database.transaction do
          page_ids.each do |page_id|
            page_row = database.get_first_row(select_sql("id"), page_id)
            next unless page_row

            page = page_from_row(page_row)
            enqueue_webmention_outbox(database, nil, page)
            retained_id = Digest::SHA256.hexdigest("publication-refresh\0#{page_id}")
            database.execute(
              <<~SQL,
                UPDATE webmention_outbox
                SET status = 'superseded', completed_at = ?
                WHERE page_id = ? AND status = 'pending' AND id <> ?
              SQL
              [serialize_time(now), page_id, retained_id]
            )
            summary["superseded"] += database.changes
          end
        end
        summary
      end
    end

    def pending_webmention_outbox(limit: 100)
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT id, event_type, page_id, payload, status, attempt_count, created_at, notified_at, completed_at
            FROM webmention_outbox WHERE status = 'pending' ORDER BY created_at, id LIMIT ?
          SQL
          limit
        ).map { |row| webmention_outbox_from_row(row) }
      end
    end

    def pending_webmention_outbox_for_page(page_id)
      with_connection do |database|
        row = database.get_first_row(
          <<~SQL,
            SELECT id, event_type, page_id, payload, status, attempt_count, created_at, notified_at, completed_at
            FROM webmention_outbox
            WHERE page_id = ? AND status = 'pending' ORDER BY created_at DESC, id DESC LIMIT 1
          SQL
          page_id
        )
        row && webmention_outbox_from_row(row)
      end
    end

    def webmention_page_targets(page_id)
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT target_url, active, first_seen_at, last_seen_at
            FROM webmention_page_targets WHERE page_id = ? ORDER BY target_url
          SQL
          page_id
        ).map do |row|
          {
            "target_url" => row.fetch(0), "active" => row.fetch(1) == 1,
            "first_seen_at" => row.fetch(2), "last_seen_at" => row.fetch(3),
          }
        end
      end
    end

    def mark_webmention_outbox_notified(id)
      with_connection do |database|
        database.execute(
          "UPDATE webmention_outbox SET notified_at = ? WHERE id = ? AND status = 'pending'",
          [serialize_time(now), id]
        )
      end
    end

    def complete_webmention_outbox(id, revision: nil)
      with_connection do |database|
        database.transaction do
          row = database.get_first_row(
            "SELECT page_id, payload FROM webmention_outbox WHERE id = ? AND status = 'pending'", id
          )
          next false unless row

          payload = JSON.parse(row.fetch(1))
          next false if revision && payload["revision"] != revision

          timestamp = serialize_time(now)
          database.execute(
            <<~SQL,
              INSERT INTO webmention_page_publications (page_id, source_url, published_at)
              VALUES (?, ?, ?)
              ON CONFLICT(page_id) DO UPDATE SET
                source_url = excluded.source_url, published_at = excluded.published_at
            SQL
            [row.fetch(0), payload.fetch("source_url"), timestamp]
          )
          database.execute("UPDATE webmention_page_targets SET active = 0 WHERE page_id = ?", row.fetch(0))
          payload.fetch("current_targets").each do |target|
            database.execute(
              <<~SQL,
                INSERT INTO webmention_page_targets (page_id, target_url, first_seen_at, last_seen_at, active)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(page_id, target_url) DO UPDATE SET
                  last_seen_at = excluded.last_seen_at, active = 1
              SQL
              [row.fetch(0), target, timestamp, timestamp]
            )
          end
          database.execute(
            <<~SQL,
              UPDATE webmention_outbox
              SET status = 'completed', attempt_count = attempt_count + 1, completed_at = ?
              WHERE id = ? AND status = 'pending'
            SQL
            [timestamp, id]
          )
          true
        end
      end
    end

    def fail_webmention_outbox(id)
      with_connection do |database|
        database.execute(
          <<~SQL,
            UPDATE webmention_outbox
            SET status = 'pending', attempt_count = attempt_count + 1, completed_at = NULL
            WHERE id = ?
          SQL
          id
        )
      end
    end

    def record_webmention_delivery(job:, status:, http_status: nil, error: nil)
      timestamp = now
      completed = %w[succeeded not_supported].include?(status) ? timestamp : nil
      expires = completed && (timestamp + (30 * 24 * 60 * 60))
      with_connection do |database|
        database.execute(
          <<~SQL,
            INSERT INTO webmention_deliveries (
              id, page_id, source_url, target_url, status, attempt_count, last_http_status,
              last_error, created_at, updated_at, completed_at, expires_at
            ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              status = excluded.status,
              attempt_count = webmention_deliveries.attempt_count + 1,
              last_http_status = excluded.last_http_status,
              last_error = excluded.last_error,
              updated_at = excluded.updated_at,
              completed_at = excluded.completed_at,
              expires_at = excluded.expires_at
          SQL
          [
            job.fetch("delivery_id"), job.fetch("page_id"), job.fetch("source"), job.fetch("target"),
            status, http_status, error&.slice(0, 500), serialize_time(timestamp), serialize_time(timestamp),
            serialize_time(completed), serialize_time(expires),
          ]
        )
      end
    end

    def list_webmention_delivery_failures
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT id, page_id, source_url, target_url, status, attempt_count,
                   last_http_status, last_error, updated_at
            FROM webmention_deliveries
            WHERE status NOT IN ('succeeded', 'not_supported')
            ORDER BY updated_at DESC, id DESC
          SQL
        ).map do |row|
          {
            "id" => row.fetch(0), "page_id" => row.fetch(1), "source_url" => row.fetch(2),
            "target_url" => row.fetch(3), "status" => row.fetch(4), "attempt_count" => row.fetch(5),
            "http_status" => row[6], "error" => row[7], "updated_at" => row.fetch(8),
          }
        end
      end
    end

    def webmention_delivery_retry(id)
      with_connection do |database|
        row = database.get_first_row(
          <<~SQL,
            SELECT id, page_id, source_url, target_url
            FROM webmention_deliveries
            WHERE id = ? AND status NOT IN ('succeeded', 'not_supported')
          SQL
          id
        )
        next nil unless row

        {
          "delivery_id" => row.fetch(0), "page_id" => row.fetch(1),
          "source" => row.fetch(2), "target" => row.fetch(3),
        }
      end
    end

    def delete_webmention(id:)
      with_connection do |database|
        database.transaction do
          raise KeyError, "Webmention not found" unless database.get_first_value(
            "SELECT 1 FROM webmention_relations WHERE id = ?", id
          )

          database.execute("DELETE FROM webmention_attempts WHERE relation_id = ?", id)
          database.execute("DELETE FROM webmention_snapshots WHERE relation_id = ?", id)
          database.execute("DELETE FROM webmention_relations WHERE id = ?", id)
        end
      end
    end

    WEBMENTION_CLEANUP_QUERIES = {
      "attempts" => ["webmention_attempts", "expires_at <= ?", "expires_at"],
      "snapshots" => ["webmention_snapshots", "expires_at IS NOT NULL AND expires_at <= ?", "expires_at"],
      "deliveries" => ["webmention_deliveries", "expires_at IS NOT NULL AND expires_at <= ?", "expires_at"],
      "outboxes" => [
        "webmention_outbox",
        "status = 'completed' AND completed_at IS NOT NULL AND completed_at <= datetime(?, '-30 days')",
        "completed_at",
      ],
      "tombstones" => [
        "webmention_relations",
        "verification_status = 'deleted' AND deleted_at IS NOT NULL AND deleted_at <= datetime(?, '-1 year')",
        "deleted_at",
      ],
    }.freeze

    def cleanup_expired_webmentions(kind:, limit:, dry_run:)
      table, condition, expiry_column = WEBMENTION_CLEANUP_QUERIES.fetch(kind)
      with_connection do |database|
        rows = database.execute(
          "SELECT id FROM #{table} WHERE #{condition} ORDER BY id LIMIT ?", [serialize_time(now), limit]
        )
        ids = rows.map { |row| row.fetch(0) }
        unless dry_run || ids.empty?
          database.transaction do
            if kind == "tombstones"
              placeholders = (["?"] * ids.length).join(", ")
              database.execute("DELETE FROM webmention_attempts WHERE relation_id IN (#{placeholders})", ids)
              database.execute("DELETE FROM webmention_snapshots WHERE relation_id IN (#{placeholders})", ids)
            end
            placeholders = (["?"] * ids.length).join(", ")
            database.execute("DELETE FROM #{table} WHERE id IN (#{placeholders})", ids)
          end
        end
        remaining, oldest = database.get_first_row(
          "SELECT COUNT(*), MIN(#{expiry_column}) FROM #{table} WHERE #{condition}", serialize_time(now)
        )
        {
          "kind" => kind, "matched" => ids.length, "deleted" => dry_run ? 0 : ids.length,
          "remaining" => remaining.to_i, "oldest_expired_at" => oldest,
        }
      end
    end

    def approved_webmentions_for_page(page_id)
      list_webmentions(moderation_status: "approved", verification_status: "verified").select do |mention|
        mention.fetch("target_page_id") == page_id && mention.fetch("approved")
      end.map { |mention| public_webmention(mention) }
    end

    def moderate_webmention(id:, decision:)
      raise ArgumentError, "invalid Webmention decision" unless %w[approved rejected pending].include?(decision)

      timestamp = now
      with_connection do |database|
        database.transaction do
          relation = database.get_first_row(
            "SELECT id, target_page_id FROM webmention_relations WHERE id = ? AND verification_status = 'verified'",
            id
          )
          raise KeyError, "Webmention not found" unless relation

          case decision
          when "approved"
            approve_webmention(database, id, timestamp)
          when "rejected"
            reject_webmention(database, id, timestamp)
          when "pending"
            reset_webmention_decision(database, id, timestamp)
          end
          page_row = database.get_first_row(select_sql("id"), relation.fetch(1))
          enqueue_webmention_outbox(database, nil, page_from_row(page_row)) if page_row
        end
      end
      list_webmentions.find { |mention| mention.fetch("id") == id }
    end

    def upsert_inbox_item(source:, kind:, source_id:, occurred_at:, payload:)
      timestamp = now
      with_connection do |database|
        suppressed = database.get_first_value(
          "SELECT 1 FROM consumed_inbox_items WHERE source = ? AND kind = ? AND source_id = ? AND expires_at > ?",
          [source, kind, source_id, serialize_time(timestamp)]
        )
        next nil if suppressed

        id = SecureRandom.uuid.delete("-")
        database.execute(
          <<~SQL,
            INSERT INTO inbox_items (
              id, source, kind, source_id, occurred_at, ingested_at, expires_at,
              payload, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, kind, source_id) DO UPDATE SET
              occurred_at = excluded.occurred_at,
              payload = excluded.payload,
              updated_at = excluded.updated_at
          SQL
          [
            id, source, kind, source_id, serialize_time(occurred_at), serialize_time(timestamp),
            serialize_time(timestamp + INBOX_RETENTION_SECONDS), JSON.generate(payload),
            serialize_time(timestamp), serialize_time(timestamp),
          ]
        )
        find_inbox_item_by_identity(database, source, kind, source_id)
      end
    end

    def start_inbox_sync_run(run_id:, trigger:, started_at:, sources:)
      with_connection do |database|
        database.transaction do
          database.execute(
            "DELETE FROM inbox_sync_run_sources WHERE run_id IN (SELECT id FROM inbox_sync_runs WHERE expires_at <= ?)",
            serialize_time(started_at)
          )
          database.execute("DELETE FROM inbox_sync_runs WHERE expires_at <= ?", serialize_time(started_at))
          placeholders = Array.new(sources.length, "?").join(", ")
          active_run_id = database.get_first_value(
            <<~SQL,
              SELECT runs.id
              FROM inbox_sync_runs runs
              JOIN inbox_sync_run_sources run_sources ON run_sources.run_id = runs.id
              WHERE runs.status IN ('queued', 'running')
                AND runs.id <> ?
                AND run_sources.source IN (#{placeholders})
              ORDER BY runs.started_at
              LIMIT 1
            SQL
            [run_id, *sources]
          )
          next false if active_run_id

          database.execute(
            <<~SQL,
              INSERT INTO inbox_sync_runs (id, trigger, status, started_at, completed_at, expires_at)
              VALUES (?, ?, 'running', ?, NULL, ?)
              ON CONFLICT(id) DO UPDATE SET
                status = 'running',
                started_at = excluded.started_at,
                completed_at = NULL,
                expires_at = excluded.expires_at
            SQL
            [run_id, trigger, serialize_time(started_at), serialize_time(started_at + 86_400)]
          )
          sources.each do |source|
            database.execute(
              <<~SQL,
                INSERT INTO inbox_sync_run_sources (
                  run_id, source, status, fetched_count, created_count, updated_count,
                  deleted_count, error, completed_at
                ) VALUES (?, ?, 'running', 0, 0, 0, 0, NULL, ?)
                ON CONFLICT(run_id, source) DO UPDATE SET
                  status = 'running',
                  error = NULL,
                  completed_at = excluded.completed_at
              SQL
              [run_id, source, serialize_time(started_at)]
            )
          end
          true
        end
      end
    end

    def queue_inbox_sync_run(run_id:, trigger:, queued_at:, sources:)
      with_connection do |database|
        database.transaction do
          timestamp = serialize_time(queued_at)
          database.execute(
            "DELETE FROM inbox_sync_run_sources WHERE run_id IN (SELECT id FROM inbox_sync_runs WHERE expires_at <= ?)",
            timestamp
          )
          database.execute("DELETE FROM inbox_sync_runs WHERE expires_at <= ?", timestamp)
          placeholders = Array.new(sources.length, "?").join(", ")
          active = database.get_first_value(
            <<~SQL,
              SELECT 1
              FROM inbox_sync_runs runs
              JOIN inbox_sync_run_sources run_sources ON run_sources.run_id = runs.id
              WHERE runs.status IN ('queued', 'running')
                AND run_sources.source IN (#{placeholders})
              LIMIT 1
            SQL
            sources
          )
          next false if active

          database.execute(
            <<~SQL,
              INSERT INTO inbox_sync_runs (id, trigger, status, started_at, completed_at, expires_at)
              VALUES (?, ?, 'queued', ?, NULL, ?)
            SQL
            [run_id, trigger, timestamp, serialize_time(queued_at + 86_400)]
          )
          sources.each do |source|
            database.execute(
              <<~SQL,
                INSERT INTO inbox_sync_run_sources (
                  run_id, source, status, fetched_count, created_count, updated_count,
                  deleted_count, error, completed_at
                ) VALUES (?, ?, 'queued', 0, 0, 0, 0, NULL, ?)
              SQL
              [run_id, source, timestamp]
            )
          end
          true
        end
      end
    end

    def inbox_sync_run(run_id:)
      with_connection do |database|
        row = database.get_first_row(
          "SELECT id, trigger, status, started_at, completed_at FROM inbox_sync_runs WHERE id = ?",
          run_id
        )
        next nil if row.nil?

        sources = database.execute(
          <<~SQL,
            SELECT source, status, fetched_count, created_count, updated_count,
                   deleted_count, error, completed_at
            FROM inbox_sync_run_sources
            WHERE run_id = ?
            ORDER BY rowid
          SQL
          run_id
        ).map do |source|
          {
            "source" => source.fetch(0), "status" => source.fetch(1),
            "fetched_count" => source.fetch(2), "created_count" => source.fetch(3),
            "updated_count" => source.fetch(4), "deleted_count" => source.fetch(5),
            "error" => source.fetch(6), "completed_at" => source.fetch(7),
          }
        end
        {
          "id" => row.fetch(0), "trigger" => row.fetch(1), "status" => row.fetch(2),
          "started_at" => row.fetch(3), "completed_at" => row.fetch(4), "sources" => sources,
        }
      end
    end

    def inbox_source_sync_state(source:)
      with_connection do |database|
        row = database.get_first_row(
          <<~SQL,
            SELECT source, last_attempted_at, last_succeeded_at, watermark, last_error, updated_at
            FROM inbox_source_sync_states
            WHERE source = ?
          SQL
          source
        )
        row && {
          "source" => row.fetch(0), "last_attempted_at" => row.fetch(1),
          "last_succeeded_at" => row.fetch(2), "watermark" => row.fetch(3),
          "last_error" => row.fetch(4), "updated_at" => row.fetch(5),
        }
      end
    end

    def apply_inbox_source_snapshot(run_id:, source:, snapshot:, completed_at:)
      with_connection do |database|
        database.transaction do
          counts = { created_count: 0, updated_count: 0, deleted_count: 0 }
          snapshot.items.each do |item|
            suppressed = database.get_first_value(
              "SELECT 1 FROM consumed_inbox_items WHERE source = ? AND kind = ? AND source_id = ? AND expires_at > ?",
              [source, item.kind, item.source_id, serialize_time(completed_at)]
            )
            next if suppressed

            existing = database.get_first_value(
              "SELECT 1 FROM inbox_items WHERE source = ? AND kind = ? AND source_id = ?",
              [source, item.kind, item.source_id]
            )
            database.execute(
              <<~SQL,
                INSERT INTO inbox_items (
                  id, source, kind, source_id, occurred_at, ingested_at, expires_at,
                  payload, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, kind, source_id) DO UPDATE SET
                  occurred_at = excluded.occurred_at,
                  payload = excluded.payload,
                  updated_at = excluded.updated_at
              SQL
              [
                new_id, source, item.kind, item.source_id, serialize_time(item.occurred_at),
                serialize_time(completed_at), serialize_time(completed_at + INBOX_RETENTION_SECONDS),
                JSON.generate(item.payload), serialize_time(completed_at), serialize_time(completed_at),
              ]
            )
            counts[existing ? :updated_count : :created_count] += 1
          end

          if snapshot.complete
            identities = snapshot.items.map { |item| [item.kind, item.source_id] }
            if identities.empty?
              database.execute("DELETE FROM inbox_items WHERE source = ?", source)
            else
              retained = Array.new(identities.length, "(kind = ? AND source_id = ?)").join(" OR ")
              database.execute(
                "DELETE FROM inbox_items WHERE source = ? AND NOT (#{retained})",
                [source, *identities.flatten]
              )
            end
            counts[:deleted_count] = database.changes
          end

          record_inbox_source_success(database, run_id:, source:, snapshot:, counts:, completed_at:)
          counts
        end
      end
    end

    def fail_inbox_source_sync(run_id:, source:, error:, completed_at:)
      with_connection do |database|
        database.transaction do
          database.execute(
            <<~SQL,
              INSERT INTO inbox_sync_run_sources (
                run_id, source, status, fetched_count, created_count, updated_count,
                deleted_count, error, completed_at
              ) VALUES (?, ?, 'failed', 0, 0, 0, 0, ?, ?)
              ON CONFLICT(run_id, source) DO UPDATE SET
                status = 'failed',
                fetched_count = 0,
                created_count = 0,
                updated_count = 0,
                deleted_count = 0,
                error = excluded.error,
                completed_at = excluded.completed_at
            SQL
            [run_id, source, error, serialize_time(completed_at)]
          )
          database.execute(
            <<~SQL,
              INSERT INTO inbox_source_sync_states (
                source, last_attempted_at, last_succeeded_at, watermark, last_error, updated_at
              ) VALUES (?, ?, NULL, NULL, ?, ?)
              ON CONFLICT(source) DO UPDATE SET
                last_attempted_at = excluded.last_attempted_at,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at
            SQL
            [source, serialize_time(completed_at), error, serialize_time(completed_at)]
          )
        end
      end
    end

    def finish_inbox_sync_run(run_id:, status:, completed_at:)
      with_connection do |database|
        database.execute(
          "UPDATE inbox_sync_runs SET status = ?, completed_at = ? WHERE id = ?",
          [status, serialize_time(completed_at), run_id]
        )
      end
    end

    def create_mobile_pairing(code_digest:, expires_at:)
      timestamp = now
      with_connection do |database|
        database.transaction do
          database.execute(
            "UPDATE mobile_pairings SET used_at = ? WHERE used_at IS NULL",
            serialize_time(timestamp)
          )
          database.execute(
            "INSERT INTO mobile_pairings (id, code_digest, attempts, expires_at, used_at, created_at) VALUES (?, ?, 0, ?, NULL, ?)",
            [new_id, code_digest, serialize_time(expires_at), serialize_time(timestamp)]
          )
        end
      end
    end

    def exchange_mobile_pairing(code_digest:, device_name:, token_digest:)
      timestamp = now
      with_connection do |database|
        database.transaction do
          row = database.get_first_row(
            "SELECT id FROM mobile_pairings WHERE code_digest = ? AND used_at IS NULL AND expires_at > ? AND attempts < 5",
            [code_digest, serialize_time(timestamp)]
          )
          if row.nil?
            candidate = database.get_first_row(
              "SELECT id, attempts FROM mobile_pairings WHERE used_at IS NULL AND expires_at > ? ORDER BY created_at DESC LIMIT 1",
              serialize_time(timestamp)
            )
            next nil if candidate.nil?

            attempts = candidate.fetch(1) + 1
            database.execute("UPDATE mobile_pairings SET attempts = ? WHERE id = ?", [attempts, candidate.fetch(0)])
            next(attempts >= 5 ? :too_many_attempts : nil)
          end

          device = {
            "id" => new_id,
            "name" => device_name,
            "created_at" => timestamp.iso8601,
            "last_used_at" => nil,
            "revoked_at" => nil,
          }
          database.execute(
            "INSERT INTO mobile_devices (id, name, token_digest, created_at, last_used_at, revoked_at) VALUES (?, ?, ?, ?, NULL, NULL)",
            [device.fetch("id"), device_name, token_digest, serialize_time(timestamp)]
          )
          database.execute("UPDATE mobile_pairings SET used_at = ? WHERE id = ?", [serialize_time(timestamp), row.fetch(0)])
          device
        end
      end
    end

    def revoke_mobile_device(id)
      with_connection do |database|
        database.execute(
          "UPDATE mobile_devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
          [serialize_time(now), id]
        )
        database.changes.positive?
      end
    end

    def active_mobile_devices
      with_connection do |database|
        database.execute(
          "SELECT id, name, token_digest, created_at, last_used_at, revoked_at FROM mobile_devices WHERE revoked_at IS NULL"
        ).map do |row|
          {
            "id" => row.fetch(0), "name" => row.fetch(1), "token_digest" => row.fetch(2),
            "created_at" => row.fetch(3), "last_used_at" => row.fetch(4), "revoked_at" => row.fetch(5),
          }
        end
      end
    end

    def touch_mobile_device(id)
      with_connection do |database|
        database.execute("UPDATE mobile_devices SET last_used_at = ? WHERE id = ?", [serialize_time(now), id])
      end
    end

    def create_mobile_upload(device_id:, upload_id:, s3_key:, client_upload_id:, content_type:, size:, sha256:,
                             captured_at:, captured_at_source:)
      timestamp = now
      with_connection do |database|
        existing = database.get_first_row(
          "SELECT #{mobile_upload_columns} FROM mobile_uploads WHERE device_id = ? AND client_upload_id = ?",
          [device_id, client_upload_id]
        )
        unless existing.nil?
          upload = mobile_upload_from_row(existing)
          expected = [content_type, size, sha256, serialize_time(captured_at), captured_at_source]
          actual = upload.values_at("content_type", "size", "sha256", "captured_at", "captured_at_source")
          raise ConflictError, "client_upload_id metadata conflict" unless actual == expected

          next [upload, false]
        end

        database.execute(
          <<~SQL,
            INSERT INTO mobile_uploads (
              id, device_id, client_upload_id, s3_key, content_type, size, sha256,
              captured_at, captured_at_source, state, created_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'awaiting_upload', ?, NULL)
          SQL
          [upload_id, device_id, client_upload_id, s3_key, content_type, size, sha256,
           serialize_time(captured_at), captured_at_source, serialize_time(timestamp),]
        )
        [mobile_upload_from_row(database.get_first_row(
          "SELECT #{mobile_upload_columns} FROM mobile_uploads WHERE id = ?",
          upload_id
        )), true,]
      end
    end

    def find_mobile_upload(upload_id:, device_id:)
      with_connection do |database|
        row = database.get_first_row(
          "SELECT #{mobile_upload_columns} FROM mobile_uploads WHERE id = ? AND device_id = ?",
          [upload_id, device_id]
        )
        row && mobile_upload_from_row(row)
      end
    end

    def complete_mobile_upload(upload_id:, device_id:, thumbnail_url:)
      timestamp = now
      with_connection do |database|
        database.transaction do
          row = database.get_first_row(
            "SELECT #{mobile_upload_columns} FROM mobile_uploads WHERE id = ? AND device_id = ?",
            [upload_id, device_id]
          )
          next nil if row.nil?

          upload = mobile_upload_from_row(row)
          existing = find_inbox_item_by_identity(database, "photo", "photo", upload_id)
          next [existing, false] unless existing.nil?

          item_id = new_id
          payload = {
            "inbox_key" => upload.fetch("s3_key"),
            "preview_url" => thumbnail_url,
            "captured_at_source" => upload.fetch("captured_at_source"),
          }
          occurred_at = upload.fetch("captured_at") || serialize_time(timestamp)
          database.execute(
            <<~SQL,
              INSERT INTO inbox_items (
                id, source, kind, source_id, occurred_at, ingested_at, expires_at,
                payload, created_at, updated_at
              ) VALUES (?, 'photo', 'photo', ?, ?, ?, ?, ?, ?, ?)
            SQL
            [item_id, upload_id, occurred_at, serialize_time(timestamp),
             serialize_time(timestamp + INBOX_RETENTION_SECONDS), JSON.generate(payload),
             serialize_time(timestamp), serialize_time(timestamp),]
          )
          database.execute(
            "UPDATE mobile_uploads SET state = 'completed', captured_at = COALESCE(captured_at, ?), completed_at = ? WHERE id = ?",
            [serialize_time(timestamp), serialize_time(timestamp), upload_id]
          )
          [find_inbox_item_by_identity(database, "photo", "photo", upload_id), true]
        end
      end
    end

    def cleanup_mobile_uploads
      cutoff = now - INBOX_RETENTION_SECONDS
      with_connection do |database|
        database.execute(
          "DELETE FROM mobile_uploads WHERE state != 'completed' AND created_at <= ?",
          serialize_time(cutoff)
        )
        database.execute("DELETE FROM mobile_pairings WHERE expires_at <= ?", serialize_time(now))
        database.changes
      end
    end

    def list_inbox_items(source: nil, kind: nil)
      clauses = ["expires_at > ?"]
      values = [serialize_time(now)]
      unless source.nil?
        clauses << "source = ?"
        values << source
      end
      unless kind.nil?
        clauses << "kind = ?"
        values << kind
      end
      with_connection do |database|
        database.execute(
          "SELECT #{inbox_item_columns} FROM inbox_items WHERE #{clauses.join(' AND ')} ORDER BY occurred_at DESC, ingested_at DESC, id DESC",
          values
        ).map { |row| inbox_item_from_row(row) }
      end
    end

    def list_inbox_item_usages
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT usage.item_id, usage.page_id, COALESCE(page.name, page.page_date), usage.used_at
            FROM inbox_item_usages usage
            JOIN pages page ON page.id = usage.page_id
            WHERE usage.expires_at > ?
            ORDER BY usage.used_at, usage.item_id, usage.page_id
          SQL
          serialize_time(now)
        ).map do |row|
          InboxItemUsage.new(
            item_id: row.fetch(0), page_id: row.fetch(1), page_route: row.fetch(2),
            used_at: Time.iso8601(row.fetch(3))
          )
        end
      end
    end

    def find_inbox_item_by_source(source:, kind:, source_id:)
      with_connection { |database| find_inbox_item_by_identity(database, source, kind, source_id) }
    end

    def find_inbox_item(id)
      with_connection do |database|
        row = database.get_first_row(
          "SELECT #{inbox_item_columns} FROM inbox_items WHERE id = ? AND expires_at > ?",
          [id, serialize_time(now)]
        )
        row && inbox_item_from_row(row)
      end
    end

    def prepare_inbox_image_adoption(item_id:, inbox_key:, public_key:)
      timestamp = now
      with_connection do |database|
        database.execute(
          <<~SQL,
            INSERT INTO inbox_image_adoptions (
              item_id, inbox_key, public_key, prepared_at, committed_at, expires_at
            ) VALUES (?, ?, ?, ?, NULL, ?)
            ON CONFLICT(item_id) DO NOTHING
          SQL
          [item_id, inbox_key, public_key, serialize_time(timestamp), serialize_time(timestamp + ADOPTION_RETENTION_SECONDS)]
        )
        inbox_image_adoption_from_row(database.get_first_row(
          "SELECT item_id, inbox_key, public_key, prepared_at, committed_at, expires_at FROM inbox_image_adoptions WHERE item_id = ?",
          item_id
        ))
      end
    end

    def list_pending_inbox_image_finalizations(limit: 100)
      with_connection do |database|
        database.execute(
          <<~SQL,
            SELECT item_id, inbox_key, public_key, prepared_at, committed_at, expires_at
            FROM inbox_image_adoptions
            WHERE committed_at IS NOT NULL AND expires_at > ?
            ORDER BY committed_at, item_id
            LIMIT ?
          SQL
          [serialize_time(now), limit]
        ).map { |row| inbox_image_adoption_from_row(row) }
      end
    end

    def complete_inbox_image_adoption(item_id:)
      with_connection { |database| database.execute("DELETE FROM inbox_image_adoptions WHERE item_id = ?", item_id) }
    end

    def rename(page_id, new_name, body:, expected_updated_at: nil)
      pages = list_pages
      current = pages.find { |page| page.id == page_id }
      raise ConflictError, "ページが見つかりません" if current.nil?
      raise ConflictError, "名前付き記事だけを変更できます" unless current.page_type == "named"
      if !expected_updated_at.nil? && expected_updated_at != current.updated_at
        raise ConflictError, "ページが別の編集で更新されています"
      end

      normalized_name = WeblogAuthoring.validate_page_name(new_name)
      return current if normalized_name == current.name && body == current.body
      if pages.any? { |page| page.id != current.id && page.route == normalized_name }
        raise ConflictError, "ページが既に存在します: #{normalized_name}"
      end

      changed_at = now
      renamed_body = WeblogAuthoring.replace_wiki_links(body, old_name: current.name.to_s, new_name: normalized_name)
      renamed = PageDocument.new(
        **current.to_h,
        name: normalized_name,
        path: page_path("named", name: normalized_name, page_date: nil),
        body: renamed_body,
        updated_at: changed_at,
        links: WeblogAuthoring.extract_wiki_links(renamed_body)
      )

      with_connection do |database|
        database.transaction do
          database.execute(
            <<~SQL,
              UPDATE pages
              SET name = ?, path = ?, updated_at = ?, body_hash = ?, is_empty = ?, body = ?
              WHERE id = ?
            SQL
            [
              renamed.name,
              renamed.path.to_s,
              serialize_time(renamed.updated_at),
              Digest::SHA256.hexdigest(renamed.body),
              renamed.empty? ? 1 : 0,
              renamed.body,
              renamed.id,
            ]
          )
          replace_links(database, renamed)

          pages.each do |source|
            next if source.id == current.id

            rewritten_body = WeblogAuthoring.replace_wiki_links(
              source.body,
              old_name: current.name.to_s,
              new_name: normalized_name
            )
            next if rewritten_body == source.body

            rewritten = PageDocument.new(
              **source.to_h,
              body: rewritten_body,
              updated_at: changed_at,
              links: WeblogAuthoring.extract_wiki_links(rewritten_body)
            )
            update_page(database, rewritten)
            replace_links(database, rewritten)
          end
        end
      rescue SQLite3::ConstraintException => error
        raise ConflictError, "ページ名の変更に失敗しました: #{error.message}"
      end

      find(current.id)
    end

    private

    def find_or_create_webmention_relation(database, job, timestamp)
      row = database.get_first_row(
        "SELECT id, moderation_status, verification_status FROM webmention_relations WHERE source_url = ? AND target_url = ?",
        [job.fetch("source"), job.fetch("target")]
      )
      if row
        return { "id" => row.fetch(0), "moderation_status" => row.fetch(1), "verification_status" => row.fetch(2) }
      end

      id = new_id
      database.execute(
        <<~SQL,
          INSERT INTO webmention_relations (
            id, source_url, target_url, target_page_id, verification_status, moderation_status,
            first_verified_at, last_notified_at, last_verified_at, deleted_at, deletion_reason,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, 'pending', 'pending', NULL, ?, NULL, NULL, NULL, ?, ?)
        SQL
        [
          id, job.fetch("source"), job.fetch("target"), job.fetch("target_page_id"),
          job.fetch("received_at"), serialize_time(timestamp), serialize_time(timestamp),
        ]
      )
      { "id" => id, "moderation_status" => "pending", "verification_status" => "pending" }
    end

    def upsert_webmention_snapshot(database, relation_id:, source_url:, title:, site_name:, content_hash:, timestamp:)
      current_hash = database.get_first_value(
        <<~SQL,
          SELECT content_hash FROM webmention_snapshots
          WHERE relation_id = ? AND is_current = 1
          ORDER BY CASE snapshot_kind WHEN 'candidate' THEN 0 ELSE 1 END LIMIT 1
        SQL
        relation_id
      )
      return if current_hash == content_hash

      database.execute(
        <<~SQL,
          UPDATE webmention_snapshots SET is_current = 0, expires_at = ?
          WHERE relation_id = ? AND snapshot_kind = 'candidate' AND is_current = 1
        SQL
        [serialize_time(timestamp + (30 * 24 * 60 * 60)), relation_id]
      )
      database.execute(
        <<~SQL,
          INSERT INTO webmention_snapshots (
            id, relation_id, snapshot_kind, source_url, title, site_name,
            content_hash, is_current, created_at, expires_at
          ) VALUES (?, ?, 'candidate', ?, ?, ?, ?, 1, ?, NULL)
        SQL
        [new_id, relation_id, source_url, title, site_name, content_hash, serialize_time(timestamp)]
      )
    end

    def record_webmention_attempt(database, job:, relation_id:, result:, timestamp:, response: nil, content_hash: nil)
      database.execute(
        <<~SQL,
          INSERT INTO webmention_attempts (
            id, job_id, relation_id, source_url, target_url, target_page_id, result, http_status,
            redirect_count, fetched_bytes, duration_ms, content_hash, attempted_at, expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          new_id, job.fetch("job_id"), relation_id, job.fetch("source"), job.fetch("target"),
          job["target_page_id"], result, response&.status, response&.redirect_count || 0, response&.body&.bytesize || 0,
          response&.duration_ms || 0, content_hash, serialize_time(timestamp),
          serialize_time(timestamp + (30 * 24 * 60 * 60)),
        ]
      )
    end

    def approve_webmention(database, relation_id, timestamp)
      candidate_id = database.get_first_value(
        "SELECT id FROM webmention_snapshots WHERE relation_id = ? AND snapshot_kind = 'candidate' AND is_current = 1",
        relation_id
      )
      raise KeyError, "Webmention candidate not found" unless candidate_id

      database.execute(
        <<~SQL,
          UPDATE webmention_snapshots SET is_current = 0, expires_at = ?
          WHERE relation_id = ? AND snapshot_kind = 'approved' AND is_current = 1
        SQL
        [serialize_time(timestamp + (30 * 24 * 60 * 60)), relation_id]
      )
      database.execute(
        "UPDATE webmention_snapshots SET snapshot_kind = 'approved', created_at = ?, expires_at = NULL WHERE id = ?",
        [serialize_time(timestamp), candidate_id]
      )
      database.execute(
        "UPDATE webmention_relations SET moderation_status = 'approved', updated_at = ? WHERE id = ?",
        [serialize_time(timestamp), relation_id]
      )
    end

    def reject_webmention(database, relation_id, timestamp)
      approved = database.get_first_value(
        "SELECT 1 FROM webmention_snapshots WHERE relation_id = ? AND snapshot_kind = 'approved' AND is_current = 1",
        relation_id
      )
      database.execute(
        <<~SQL,
          UPDATE webmention_snapshots SET is_current = 0, expires_at = ?
          WHERE relation_id = ? AND snapshot_kind = 'candidate' AND is_current = 1
        SQL
        [serialize_time(timestamp + (90 * 24 * 60 * 60)), relation_id]
      )
      status = approved ? "approved" : "rejected"
      database.execute(
        "UPDATE webmention_relations SET moderation_status = ?, updated_at = ? WHERE id = ?",
        [status, serialize_time(timestamp), relation_id]
      )
    end

    def reset_webmention_decision(database, relation_id, timestamp)
      approved_id = database.get_first_value(
        "SELECT id FROM webmention_snapshots WHERE relation_id = ? AND snapshot_kind = 'approved' AND is_current = 1",
        relation_id
      )
      if approved_id
        database.execute(
          "UPDATE webmention_snapshots SET snapshot_kind = 'candidate', created_at = ?, expires_at = NULL WHERE id = ?",
          [serialize_time(timestamp), approved_id]
        )
      else
        candidate_id = database.get_first_value(
          <<~SQL,
            SELECT id FROM webmention_snapshots
            WHERE relation_id = ? AND snapshot_kind = 'candidate'
            ORDER BY created_at DESC, id DESC LIMIT 1
          SQL
          relation_id
        )
        database.execute(
          "UPDATE webmention_snapshots SET is_current = 1, created_at = ?, expires_at = NULL WHERE id = ?",
          [serialize_time(timestamp), candidate_id]
        ) if candidate_id
      end
      database.execute(
        "UPDATE webmention_relations SET moderation_status = 'pending', updated_at = ? WHERE id = ?",
        [serialize_time(timestamp), relation_id]
      )
    end

    def webmention_from_row(row)
      {
        "id" => row.fetch(0), "source_url" => row.fetch(1), "target_url" => row.fetch(2),
        "target_page_id" => row.fetch(3), "verification_status" => row.fetch(4),
        "moderation_status" => row.fetch(5), "first_verified_at" => row.fetch(6),
        "last_notified_at" => row.fetch(7), "last_verified_at" => row.fetch(8),
        "candidate" => webmention_snapshot(row.fetch(1), row[9], row[10], row[11]),
        "approved" => webmention_snapshot(row.fetch(1), row[12], row[13], row[14]),
      }
    end

    def webmention_snapshot(source_url, title, site_name, content_hash)
      return nil unless content_hash

      { "source_url" => source_url, "title" => title, "site_name" => site_name, "content_hash" => content_hash }
    end

    def public_webmention(mention)
      snapshot = mention.fetch("approved")
      {
        "id" => mention.fetch("id"), "source_url" => snapshot.fetch("source_url"),
        "title" => snapshot["title"], "site_name" => snapshot["site_name"],
        "first_verified_at" => mention.fetch("first_verified_at"),
      }
    end

    def webmention_failure_from_row(row)
      {
        "id" => row.fetch(0), "job_id" => row.fetch(1), "source_url" => row.fetch(2),
        "target_url" => row.fetch(3), "target_page_id" => row[4], "result" => row.fetch(5),
        "http_status" => row[6], "redirect_count" => row.fetch(7), "fetched_bytes" => row.fetch(8),
        "duration_ms" => row.fetch(9), "attempted_at" => row.fetch(10),
      }
    end

    def enqueue_webmention_outbox(database, _previous, current)
      current_source = webmention_source_url(current.route)
      previous_source = database.get_first_value(
        "SELECT source_url FROM webmention_page_publications WHERE page_id = ?", current.id
      )
      previous_targets = database.execute(
        "SELECT target_url FROM webmention_page_targets WHERE page_id = ? AND active = 1 ORDER BY target_url",
        current.id
      ).flatten
      current_targets = if current.status == "published" && !current.empty?
                          @webmention_targets.extract(current.body, source_url: current_source)
                        else
                          []
                        end
      timestamp = serialize_time(now)
      payload = {
        "revision" => new_id,
        "desired_updated_at" => current.updated_at.iso8601(9),
        "source_url" => current_source,
        "previous_source_url" => previous_source,
        "previous_targets" => previous_targets,
        "current_targets" => current_targets,
      }
      event_type = current_targets.empty? && previous_source ? "page_unpublished" : "page_saved"
      outbox_id = Digest::SHA256.hexdigest("publication-refresh\0#{current.id}")
      database.execute(
        <<~SQL,
          INSERT INTO webmention_outbox (
            id, event_type, page_id, payload, status, attempt_count, created_at, notified_at, completed_at
          ) VALUES (?, ?, ?, ?, 'pending', 0, ?, NULL, NULL)
          ON CONFLICT(id) DO UPDATE SET
            event_type = excluded.event_type,
            payload = excluded.payload,
            status = 'pending',
            attempt_count = 0,
            created_at = excluded.created_at,
            notified_at = NULL,
            completed_at = NULL
        SQL
        [outbox_id, event_type, current.id, JSON.generate(payload), timestamp]
      )
    end

    def webmention_source_url(route)
      base = @site_url.end_with?("/") ? @site_url : "#{@site_url}/"
      URI.join(base, URI::DEFAULT_PARSER.escape(route)).to_s
    end

    def webmention_outbox_from_row(row)
      {
        "id" => row.fetch(0), "event_type" => row.fetch(1), "page_id" => row.fetch(2),
        "payload" => JSON.parse(row.fetch(3)), "status" => row.fetch(4),
        "attempt_count" => row.fetch(5), "created_at" => row.fetch(6),
        "notified_at" => row[7], "completed_at" => row[8],
      }
    end

    def create_schema(database)
      version = database.get_first_value("PRAGMA user_version").to_i
      return if version == SCHEMA_VERSION && table_exists?(database, "pages")
      if version == 1 && table_exists?(database, "pages")
        migrate_date_pages_to_title_routes(database)
        create_inbox_schema(database)
        create_mobile_upload_schema(database)
        create_inbox_sync_schema(database)
        create_scrapbox_line_metadata_schema(database)
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 2 && table_exists?(database, "pages")
        create_inbox_schema(database)
        create_mobile_upload_schema(database)
        create_inbox_sync_schema(database)
        create_scrapbox_line_metadata_schema(database)
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 3 && table_exists?(database, "pages")
        create_mobile_upload_schema(database)
        create_inbox_sync_schema(database)
        create_scrapbox_line_metadata_schema(database)
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 4 && table_exists?(database, "pages")
        create_inbox_schema(database)
        create_inbox_sync_schema(database)
        create_scrapbox_line_metadata_schema(database)
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 5 && table_exists?(database, "pages")
        create_inbox_sync_schema(database)
        create_scrapbox_line_metadata_schema(database)
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 6 && table_exists?(database, "pages")
        create_scrapbox_line_metadata_schema(database)
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 7 && table_exists?(database, "pages")
        create_cover_image_schema(database)
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 8 && table_exists?(database, "pages")
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 9 && table_exists?(database, "pages")
        create_webmention_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      raise "unsupported development database schema: #{version}" unless version.zero?

      database.execute_batch(
        <<~SQL
          PRAGMA user_version = #{SCHEMA_VERSION};
          CREATE TABLE pages (
            id TEXT PRIMARY KEY,
            page_type TEXT NOT NULL,
            name TEXT,
            page_date TEXT,
            title TEXT,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            published_at TEXT,
            path TEXT NOT NULL,
            body_hash TEXT NOT NULL,
            is_empty INTEGER NOT NULL,
            body TEXT NOT NULL,
            cover_mode TEXT NOT NULL DEFAULT 'auto',
            cover_image_url TEXT
          );
          CREATE UNIQUE INDEX pages_named_route ON pages(name)
            WHERE page_type = 'named';
          CREATE TABLE links (
            source_id TEXT NOT NULL,
            target_id TEXT,
            target_name TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (source_id, position)
          );
        SQL
      )
      create_inbox_schema(database)
      create_mobile_upload_schema(database)
      create_inbox_sync_schema(database)
      create_scrapbox_line_metadata_schema(database)
      create_webmention_schema(database)
    end

    def create_cover_image_schema(database)
      columns = database.execute("PRAGMA table_info(pages)").map { |row| row[1] }
      unless columns.include?("cover_mode")
        database.execute("ALTER TABLE pages ADD COLUMN cover_mode TEXT NOT NULL DEFAULT 'auto'")
      end
      database.execute("ALTER TABLE pages ADD COLUMN cover_image_url TEXT") unless columns.include?("cover_image_url")
    end

    def table_exists?(database, table)
      database.get_first_value(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        table
      ) == 1
    end

    def create_inbox_schema(database)
      database.execute_batch(
        <<~SQL
          CREATE TABLE IF NOT EXISTS inbox_items (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            ingested_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(source, kind, source_id)
          );
          CREATE TABLE IF NOT EXISTS consumed_inbox_items (
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            consumed_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            PRIMARY KEY(source, kind, source_id)
          );
          CREATE TABLE IF NOT EXISTS inbox_item_usages (
            item_id TEXT NOT NULL,
            page_id TEXT NOT NULL,
            used_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            PRIMARY KEY(item_id, page_id)
          );
          CREATE TABLE IF NOT EXISTS inbox_image_adoptions (
            item_id TEXT PRIMARY KEY,
            inbox_key TEXT NOT NULL,
            public_key TEXT NOT NULL,
            prepared_at TEXT NOT NULL,
            committed_at TEXT,
            expires_at TEXT NOT NULL
          );
        SQL
      )
    end

    def create_mobile_upload_schema(database)
      database.execute_batch(
        <<~SQL
          CREATE TABLE IF NOT EXISTS mobile_pairings (
            id TEXT PRIMARY KEY,
            code_digest TEXT NOT NULL UNIQUE,
            attempts INTEGER NOT NULL,
            expires_at TEXT NOT NULL,
            used_at TEXT,
            created_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS mobile_devices (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            token_digest TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            last_used_at TEXT,
            revoked_at TEXT
          );
          CREATE TABLE IF NOT EXISTS mobile_uploads (
            id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            client_upload_id TEXT NOT NULL,
            s3_key TEXT NOT NULL,
            content_type TEXT NOT NULL,
            size INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            captured_at TEXT,
            captured_at_source TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            completed_at TEXT,
            UNIQUE(device_id, client_upload_id)
          );
        SQL
      )
    end

    def create_inbox_sync_schema(database)
      database.execute_batch(
        <<~SQL
          CREATE TABLE IF NOT EXISTS inbox_source_sync_states (
            source TEXT PRIMARY KEY,
            last_attempted_at TEXT NOT NULL,
            last_succeeded_at TEXT,
            watermark TEXT,
            last_error TEXT,
            updated_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS inbox_sync_runs (
            id TEXT PRIMARY KEY,
            trigger TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at TEXT NOT NULL,
            completed_at TEXT,
            expires_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS inbox_sync_run_sources (
            run_id TEXT NOT NULL,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            fetched_count INTEGER NOT NULL,
            created_count INTEGER NOT NULL,
            updated_count INTEGER NOT NULL,
            deleted_count INTEGER NOT NULL,
            error TEXT,
            completed_at TEXT NOT NULL,
            PRIMARY KEY(run_id, source)
          );
        SQL
      )
    end

    def create_scrapbox_line_metadata_schema(database)
      database.execute_batch(
        <<~SQL
          CREATE TABLE IF NOT EXISTS scrapbox_line_metadata (
            page_id TEXT NOT NULL,
            body_hash TEXT NOT NULL,
            line_index INTEGER NOT NULL,
            created_at TEXT,
            updated_at TEXT,
            user_id TEXT,
            PRIMARY KEY (page_id, line_index)
          );
        SQL
      )
    end

    def create_webmention_schema(database)
      database.execute_batch(
        <<~SQL
          CREATE TABLE IF NOT EXISTS webmention_relations (
            id TEXT PRIMARY KEY,
            source_url TEXT NOT NULL,
            target_url TEXT NOT NULL,
            target_page_id TEXT NOT NULL,
            verification_status TEXT NOT NULL,
            moderation_status TEXT NOT NULL,
            first_verified_at TEXT,
            last_notified_at TEXT NOT NULL,
            last_verified_at TEXT,
            deleted_at TEXT,
            deletion_reason TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(source_url, target_url)
          );
          CREATE TABLE IF NOT EXISTS webmention_snapshots (
            id TEXT PRIMARY KEY,
            relation_id TEXT NOT NULL,
            snapshot_kind TEXT NOT NULL,
            source_url TEXT NOT NULL,
            title TEXT,
            site_name TEXT,
            content_hash TEXT NOT NULL,
            is_current INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT
          );
          CREATE TABLE IF NOT EXISTS webmention_attempts (
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
            attempted_at TEXT NOT NULL,
            expires_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS webmention_page_targets (
            page_id TEXT NOT NULL,
            target_url TEXT NOT NULL,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            active INTEGER NOT NULL,
            PRIMARY KEY(page_id, target_url)
          );
          CREATE TABLE IF NOT EXISTS webmention_page_publications (
            page_id TEXT PRIMARY KEY,
            source_url TEXT NOT NULL,
            published_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS webmention_outbox (
            id TEXT PRIMARY KEY,
            event_type TEXT NOT NULL,
            page_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            status TEXT NOT NULL,
            attempt_count INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            notified_at TEXT,
            completed_at TEXT
          );
          CREATE TABLE IF NOT EXISTS webmention_deliveries (
            id TEXT PRIMARY KEY,
            page_id TEXT NOT NULL,
            source_url TEXT NOT NULL,
            target_url TEXT NOT NULL,
            status TEXT NOT NULL,
            attempt_count INTEGER NOT NULL,
            last_http_status INTEGER,
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT,
            expires_at TEXT
          );
        SQL
      )
    end

    def record_inbox_source_success(database, run_id:, source:, snapshot:, counts:, completed_at:)
      database.execute(
        <<~SQL,
          INSERT INTO inbox_sync_run_sources (
            run_id, source, status, fetched_count, created_count, updated_count,
            deleted_count, error, completed_at
          ) VALUES (?, ?, 'succeeded', ?, ?, ?, ?, NULL, ?)
          ON CONFLICT(run_id, source) DO UPDATE SET
            status = 'succeeded',
            fetched_count = excluded.fetched_count,
            created_count = excluded.created_count,
            updated_count = excluded.updated_count,
            deleted_count = excluded.deleted_count,
            error = NULL,
            completed_at = excluded.completed_at
        SQL
        [
          run_id, source, snapshot.items.length, counts.fetch(:created_count),
          counts.fetch(:updated_count), counts.fetch(:deleted_count), serialize_time(completed_at),
        ]
      )
      database.execute(
        <<~SQL,
          INSERT INTO inbox_source_sync_states (
            source, last_attempted_at, last_succeeded_at, watermark, last_error, updated_at
          ) VALUES (?, ?, ?, ?, NULL, ?)
          ON CONFLICT(source) DO UPDATE SET
            last_attempted_at = excluded.last_attempted_at,
            last_succeeded_at = excluded.last_succeeded_at,
            watermark = excluded.watermark,
            last_error = NULL,
            updated_at = excluded.updated_at
        SQL
        [
          source, serialize_time(completed_at), serialize_time(completed_at),
          snapshot.watermark, serialize_time(completed_at),
        ]
      )
    end

    def mobile_upload_from_row(row)
      {
        "id" => row.fetch(0), "device_id" => row.fetch(1), "client_upload_id" => row.fetch(2),
        "s3_key" => row.fetch(3), "content_type" => row.fetch(4), "size" => row.fetch(5),
        "sha256" => row.fetch(6), "captured_at" => row.fetch(7), "captured_at_source" => row.fetch(8),
        "state" => row.fetch(9), "created_at" => row.fetch(10), "completed_at" => row.fetch(11),
      }
    end

    def mobile_upload_columns
      "id, device_id, client_upload_id, s3_key, content_type, size, sha256, captured_at, captured_at_source, state, created_at, completed_at"
    end

    def record_inbox_item_usage_with_connection(database, id, page_id)
      row = database.get_first_row(
        "SELECT #{inbox_item_columns} FROM inbox_items WHERE id = ? AND expires_at > ?",
        [id, serialize_time(now)]
      )
      raise ConflictError, "inbox_item_expired" if row.nil?

      if row.fetch(1) == "photo" && row.fetch(2) == "photo"
        adoption = database.get_first_value(
          "SELECT 1 FROM inbox_image_adoptions WHERE item_id = ? AND expires_at > ?",
          [id, serialize_time(now)]
        )
        raise ConflictError, "inbox_item_expired" if adoption.nil?
      end

      database.execute(
        <<~SQL,
          INSERT INTO inbox_item_usages (item_id, page_id, used_at, expires_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(item_id, page_id) DO UPDATE SET used_at = excluded.used_at
        SQL
        [id, page_id, serialize_time(now), row.fetch(6)]
      )
      database.execute("UPDATE inbox_image_adoptions SET committed_at = ? WHERE item_id = ?", [serialize_time(now), id])
    end

    def consume_inbox_item_with_connection(database, id, required:)
      row = database.get_first_row(
        "SELECT #{inbox_item_columns} FROM inbox_items WHERE id = ? AND expires_at > ?",
        [id, serialize_time(now)]
      )
      if row.nil?
        raise ConflictError, "inbox_item_expired" if required

        return false
      end

      if row.fetch(1) == "photo" && row.fetch(2) == "photo"
        adoption = database.get_first_value(
          "SELECT 1 FROM inbox_image_adoptions WHERE item_id = ? AND expires_at > ?",
          [id, serialize_time(now)]
        )
        raise ConflictError, "inbox_item_expired" if adoption.nil?
      end

      database.execute(
        <<~SQL,
          INSERT INTO consumed_inbox_items (source, kind, source_id, consumed_at, expires_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(source, kind, source_id) DO UPDATE SET
            consumed_at = excluded.consumed_at,
            expires_at = excluded.expires_at
        SQL
        [row.fetch(1), row.fetch(2), row.fetch(3), serialize_time(now), row.fetch(6)]
      )
      database.execute("UPDATE inbox_image_adoptions SET committed_at = ? WHERE item_id = ?", [serialize_time(now), id])
      database.execute("DELETE FROM inbox_items WHERE id = ?", id)
      true
    end

    def find_inbox_item_by_identity(database, source, kind, source_id)
      row = database.get_first_row(
        "SELECT #{inbox_item_columns} FROM inbox_items WHERE source = ? AND kind = ? AND source_id = ?",
        [source, kind, source_id]
      )
      row && inbox_item_from_row(row)
    end

    def inbox_item_from_row(row)
      id, source, kind, source_id, occurred_at, ingested_at, expires_at, payload, created_at, updated_at = row
      InboxItem.new(
        id:, source:, kind:, source_id:,
        occurred_at: Time.iso8601(occurred_at), ingested_at: Time.iso8601(ingested_at),
        expires_at: Time.iso8601(expires_at), payload: JSON.parse(payload),
        created_at: Time.iso8601(created_at), updated_at: Time.iso8601(updated_at)
      )
    end

    def inbox_image_adoption_from_row(row)
      item_id, inbox_key, public_key, prepared_at, committed_at, expires_at = row
      InboxImageAdoption.new(
        item_id:, inbox_key:, public_key:,
        prepared_at: Time.iso8601(prepared_at),
        committed_at: committed_at && Time.iso8601(committed_at),
        expires_at: Time.iso8601(expires_at)
      )
    end

    def inbox_item_columns
      "id, source, kind, source_id, occurred_at, ingested_at, expires_at, payload, created_at, updated_at"
    end

    def migrate_date_pages_to_title_routes(database)
      date_pages = database.execute("SELECT id, title FROM pages WHERE page_type = 'date'")
      names = database.execute("SELECT name FROM pages WHERE page_type = 'named'").each_with_object({}) do |(name), result|
        result[name] = true
      end

      migrations = date_pages.map do |id, title|
        name = WeblogAuthoring.validate_page_name(title.to_s)
        raise ConflictError, "ページが既に存在します: #{name}" if names.key?(name)

        names[name] = true
        [id, name, page_path("named", name:, page_date: nil).to_s]
      end

      database.transaction do
        database.execute("DROP INDEX IF EXISTS pages_date_route")
        migrations.each do |id, name, path|
          database.execute(
            "UPDATE pages SET page_type = 'named', name = ?, page_date = NULL, title = NULL, path = ? WHERE id = ?",
            [name, path, id]
          )
        end
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
      end
    end

    def new_document(request)
      timestamp = now
      page_type = request.page_type
      cover_mode, cover_image_url = CoverImage.validate(request.cover_mode, request.cover_image_url)

      case page_type
      when "date"
        name = WeblogAuthoring.validate_page_name(request.title.to_s)

        PageDocument.new(
          id: new_id,
          page_type: "named",
          name:,
          page_date: nil,
          title: nil,
          status: "published",
          created_at: timestamp,
          updated_at: timestamp,
          published_at: timestamp,
          path: page_path("named", name:, page_date: nil),
          body: request.body.to_s,
          links: WeblogAuthoring.extract_wiki_links(request.body.to_s),
          cover_mode:,
          cover_image_url:
        )
      when "named"
        name = WeblogAuthoring.validate_page_name(request.name || request.title.to_s)

        PageDocument.new(
          id: new_id,
          page_type:,
          name:,
          page_date: nil,
          title: nil,
          status: "published",
          created_at: timestamp,
          updated_at: timestamp,
          published_at: timestamp,
          path: page_path(page_type, name:, page_date: nil),
          body: request.body.to_s,
          links: WeblogAuthoring.extract_wiki_links(request.body.to_s),
          cover_mode:,
          cover_image_url:
        )
      else
        raise ArgumentError, "unknown page type: #{page_type}"
      end
    end

    def updated_document(current, request)
      validate_expected_update(current, request)
      page_type = current.page_type
      title = page_type == "date" ? request.title : current.title
      body = request.body.to_s
      cover_mode, cover_image_url = if request.cover_mode.nil?
                                      [current.cover_mode, current.cover_image_url]
                                    else
                                      CoverImage.validate(request.cover_mode, request.cover_image_url)
                                    end
      PageDocument.new(
        **current.to_h,
        title:,
        body:,
        updated_at: now,
        links: WeblogAuthoring.extract_wiki_links(body),
        cover_mode:,
        cover_image_url:
      )
    end

    def ensure_unique_route!(database, document, current)
      column = document.page_type == "date" ? "page_date" : "name"
      value = document.page_type == "date" ? document.page_date.iso8601 : document.name
      row = database.get_first_row(
        "SELECT id FROM pages WHERE page_type = ? AND #{column} = ? LIMIT 1",
        [document.page_type, value]
      )
      return if row.nil? || row[0] == current&.id

      raise ConflictError, "ページが既に存在します: #{document.route}"
    end

    def insert_page(database, document)
      database.execute(
        <<~SQL,
          INSERT INTO pages (
            id, page_type, name, page_date, title, status, created_at,
            updated_at, published_at, path, body_hash, is_empty, body, cover_mode, cover_image_url
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        page_values(document)
      )
    end

    def update_page(database, document)
      database.execute(
        <<~SQL,
          UPDATE pages
          SET title = ?, status = ?, updated_at = ?, published_at = ?,
              body_hash = ?, is_empty = ?, body = ?, cover_mode = ?, cover_image_url = ?
          WHERE id = ?
        SQL
        [
          document.title,
          document.status,
          serialize_time(document.updated_at),
          serialize_time(document.published_at),
          Digest::SHA256.hexdigest(document.body),
          document.empty? ? 1 : 0,
          document.body,
          document.cover_mode,
          document.cover_image_url,
          document.id,
        ]
      )
    end

    def replace_links(database, document)
      database.execute("DELETE FROM links WHERE source_id = ?", document.id)
      document.links.each_with_index do |link, position|
        target_id = database.get_first_value(
          "SELECT id FROM pages WHERE page_type = 'named' AND name = ?",
          link.name
        )
        database.execute(
          "INSERT INTO links (source_id, target_id, target_name, position) VALUES (?, ?, ?, ?)",
          [document.id, target_id, link.name, position]
        )
      end
    end

    def replace_line_metadata_after_save(database, document, current, current_metadata)
      previous_lines = current&.body.to_s.split("\n", -1)
      metadata_by_line = Hash.new { |lines, body| lines[body] = [] }
      previous_lines.each_with_index do |line, index|
        metadata = current_metadata[index]
        metadata ||= {
          created_at: current.updated_at,
          updated_at: current.updated_at,
          user_id: nil,
        } if current && current_metadata.empty?
        metadata_by_line[line] << metadata unless metadata.nil?
      end

      timestamp = document.updated_at
      lines = document.body.split("\n", -1).map do |line|
        previous = metadata_by_line[line].shift
        {
          created_at: previous&.fetch(:created_at, nil) || timestamp,
          updated_at: previous&.fetch(:updated_at, nil) || timestamp,
          user_id: previous&.fetch(:user_id, nil),
        }
      end

      database.execute("DELETE FROM scrapbox_line_metadata WHERE page_id = ?", document.id)
      lines.each_with_index do |line, line_index|
        database.execute(
          <<~SQL,
            INSERT INTO scrapbox_line_metadata (
              page_id, body_hash, line_index, created_at, updated_at, user_id
            ) VALUES (?, ?, ?, ?, ?, ?)
          SQL
          [
            document.id,
            Digest::SHA256.hexdigest(document.body),
            line_index,
            serialize_time(line.fetch(:created_at)),
            serialize_time(line.fetch(:updated_at)),
            line.fetch(:user_id),
          ]
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
        serialize_time(document.created_at),
        serialize_time(document.updated_at),
        serialize_time(document.published_at),
        document.path.to_s,
        Digest::SHA256.hexdigest(document.body),
        document.empty? ? 1 : 0,
        document.body,
        document.cover_mode,
        document.cover_image_url,
      ]
    end

    def page_from_row(row)
      id, page_type, name, page_date, title, status, created_at, updated_at, published_at, path, body,
        cover_mode, cover_image_url = row
      PageDocument.new(
        id:,
        page_type:,
        name:,
        page_date: page_date && Date.iso8601(page_date),
        title:,
        status:,
        created_at: Time.iso8601(created_at),
        updated_at: Time.iso8601(updated_at),
        published_at: published_at && Time.iso8601(published_at),
        path: Pathname(path),
        body:,
        links: WeblogAuthoring.extract_wiki_links(body),
        cover_mode:,
        cover_image_url:
      )
    end

    def select_sql(condition)
      <<~SQL
        SELECT id, page_type, name, page_date, title, status,
               created_at, updated_at, published_at, path, body, cover_mode, cover_image_url
        FROM pages
        WHERE #{condition} = ?
        LIMIT 1
      SQL
    end

    def page_path(page_type, name:, page_date:)
      WeblogAuthoring.page_path(@content_dir, page_type, name:, page_date:)
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

    def serialize_time(value)
      value&.getlocal(TOKYO_OFFSET)&.iso8601(9)
    end

    def new_id
      SecureRandom.uuid.delete("-")
    end

    def with_connection
      @path.dirname.mkpath
      database = SQLite3::Database.new(@path.to_s)
      database.busy_timeout = 1_000
      database.results_as_hash = false
      create_schema(database)
      yield database
    ensure
      database&.close
    end
  end
end
