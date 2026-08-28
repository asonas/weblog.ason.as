# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"

require_relative "links"
require_relative "models"
require_relative "names"

module WeblogAuthoring
  class DevelopmentDatabase
    SCHEMA_VERSION = 5
    INBOX_RETENTION_SECONDS = 7 * 24 * 60 * 60
    ADOPTION_RETENTION_SECONDS = 14 * 24 * 60 * 60
    TOKYO_OFFSET = "+09:00"

    attr_reader :path

    def initialize(path, content_dir:, clock: -> { Time.now.getlocal(TOKYO_OFFSET) })
      @path = Pathname(path)
      @content_dir = Pathname(content_dir)
      @clock = clock
    end

    def setup!
      with_connection { |database| create_schema(database) }
    end

    def list_pages(limit: nil)
      with_connection do |database|
        sql = <<~SQL
            SELECT id, page_type, name, page_date, title, status,
                   created_at, updated_at, published_at, path, body
            FROM pages
            ORDER BY created_at DESC, updated_at DESC
        SQL
        sql += "LIMIT ?\n" if limit
        database.execute(sql, *Array(limit)).map { |row| page_from_row(row) }
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
                   created_at, updated_at, published_at, path, body
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

    def save(request)
      current = request.page_id && find(request.page_id)
      document = current.nil? ? new_document(request) : updated_document(current, request)

      with_connection do |database|
        database.transaction do
          ensure_unique_route!(database, document, current)
          if current.nil?
            insert_page(database, document)
          else
            update_page(database, document)
          end
          replace_links(database, document)
          request.consumed_inbox_item_ids.each do |item_id|
            record_inbox_item_usage_with_connection(database, item_id, document.id)
          end
        end
      rescue SQLite3::ConstraintException => error
        raise ConflictError, "ページの保存に失敗しました: #{error.message}"
      end

      find(document.id)
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
            serialize_time(timestamp), serialize_time(timestamp)
          ]
        )
        find_inbox_item_by_identity(database, source, kind, source_id)
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
           serialize_time(captured_at), captured_at_source, serialize_time(timestamp)]
        )
        [mobile_upload_from_row(database.get_first_row(
          "SELECT #{mobile_upload_columns} FROM mobile_uploads WHERE id = ?",
          upload_id
        )), true]
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

    def complete_mobile_upload(upload_id:, device_id:)
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
            "preview_url" => "/#{upload.fetch("s3_key")}",
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
             serialize_time(timestamp), serialize_time(timestamp)]
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
              renamed.id
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

    def create_schema(database)
      version = database.get_first_value("PRAGMA user_version").to_i
      return if version == SCHEMA_VERSION && table_exists?(database, "pages")
      if version == 1 && table_exists?(database, "pages")
        migrate_date_pages_to_title_routes(database)
        create_inbox_schema(database)
        create_mobile_upload_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 2 && table_exists?(database, "pages")
        create_inbox_schema(database)
        create_mobile_upload_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 3 && table_exists?(database, "pages")
        create_mobile_upload_schema(database)
        database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        return
      end
      if version == 4 && table_exists?(database, "pages")
        create_inbox_schema(database)
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
            body TEXT NOT NULL
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
          links: WeblogAuthoring.extract_wiki_links(request.body.to_s)
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
          links: WeblogAuthoring.extract_wiki_links(request.body.to_s)
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
      PageDocument.new(
        **current.to_h,
        title:,
        body:,
        updated_at: now,
        links: WeblogAuthoring.extract_wiki_links(body)
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
            updated_at, published_at, path, body_hash, is_empty, body
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        page_values(document)
      )
    end

    def update_page(database, document)
      database.execute(
        <<~SQL,
          UPDATE pages
          SET title = ?, status = ?, updated_at = ?, published_at = ?,
              body_hash = ?, is_empty = ?, body = ?
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
          document.id
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
        document.body
      ]
    end

    def page_from_row(row)
      id, page_type, name, page_date, title, status, created_at, updated_at, published_at, path, body = row
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
        links: WeblogAuthoring.extract_wiki_links(body)
      )
    end

    def select_sql(condition)
      <<~SQL
        SELECT id, page_type, name, page_date, title, status,
               created_at, updated_at, published_at, path, body
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
