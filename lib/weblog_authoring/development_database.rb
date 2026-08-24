# frozen_string_literal: true

require "date"
require "digest"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"

require_relative "links"
require_relative "models"
require_relative "names"

module WeblogAuthoring
  class DevelopmentDatabase
    SCHEMA_VERSION = 2
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
        end
      rescue SQLite3::ConstraintException => error
        raise ConflictError, "ページの保存に失敗しました: #{error.message}"
      end

      find(document.id)
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
    end

    def table_exists?(database, table)
      database.get_first_value(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        table
      ) == 1
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
