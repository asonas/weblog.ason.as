# frozen_string_literal: true

require "date"
require "digest"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"

module WeblogAuthoring
  class AuthoringDatabase
    SCHEMA_VERSION = 1
    REQUIRED_TABLES = %w[links pages problems].freeze

    attr_reader :path

    def initialize(path)
      @path = Pathname(path)
      @pages = {}
    end

    def connect
      path.dirname.mkpath
      SQLite3::Database.new(path.to_s)
    end

    def rebuild(snapshot)
      @pages = snapshot.pages.each_with_object({}) { |page, pages| pages[page.id] = page }
      rotate_corrupt_database! if path.exist? && (!integrity_ok? || !schema_compatible?)

      temporary_path = Pathname("#{path}.tmp-#{SecureRandom.hex(8)}")

      begin
        build_database(temporary_path, snapshot)
        File.rename(temporary_path, path)
      ensure
        temporary_path.unlink if temporary_path.exist?
      end
    end

    def backlinks(target_id, public_only: false)
      statement = <<~SQL
        SELECT DISTINCT pages.id
        FROM links
        JOIN pages ON pages.id = links.source_id
        WHERE links.target_id = ?
      SQL
      parameters = [target_id]
      if public_only
        statement += " AND pages.status = ?"
        parameters << "published"
      end
      statement += " ORDER BY pages.path"

      with_connection do |database|
        database.execute(statement, parameters).map { |row| document_for(row[0]) }
      end
    end

    def search(query, status = nil)
      clauses = []
      parameters = []

      unless query.to_s.empty?
        pattern = "%#{query}%"
        clauses << "(name LIKE ? OR title LIKE ? OR page_date LIKE ?)"
        parameters.concat([pattern, pattern, pattern])
      end

      unless status.nil?
        clauses << "status = ?"
        parameters << status
      end

      statement = "SELECT id FROM pages"
      statement += " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
      statement += " ORDER BY path"

      with_connection do |database|
        database.execute(statement, parameters).map { |row| document_for(row[0]) }
      end
    end

    def integrity_ok?
      return false unless path.exist?

      with_connection do |database|
        database.get_first_value("PRAGMA integrity_check") == "ok"
      end
    rescue SQLite3::Exception
      false
    end

    private

    def build_database(database_path, snapshot)
      database_path.dirname.mkpath
      SQLite3::Database.new(database_path.to_s) do |database|
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
              is_empty INTEGER NOT NULL
            );
            CREATE TABLE links (
              source_id TEXT NOT NULL,
              target_id TEXT,
              target_name TEXT NOT NULL,
              position INTEGER NOT NULL,
              PRIMARY KEY (source_id, position)
            );
            CREATE TABLE problems (
              path TEXT PRIMARY KEY,
              detail TEXT NOT NULL
            );
          SQL
        )

        by_name = snapshot.pages.each_with_object({}) do |page, routes|
          routes[page.name] = page.id unless page.name.nil?
        end

        snapshot.pages.each do |page|
          database.execute(
            "INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
              page.id,
              page.page_type,
              page.name,
              page.page_date&.iso8601,
              page.title,
              page.status,
              page.created_at.iso8601,
              page.updated_at.iso8601,
              page.published_at&.iso8601,
              page.path.to_s,
              Digest::SHA256.hexdigest(page.body),
              page.empty? ? 1 : 0
            ]
          )
        end

        snapshot.pages.each do |page|
          page.links.each_with_index do |link, index|
            database.execute(
              "INSERT INTO links VALUES (?, ?, ?, ?)",
              [page.id, by_name[link.name], link.name, index]
            )
          end
        end

        snapshot.problems.each do |problem|
          database.execute(
            "INSERT INTO problems VALUES (?, ?)",
            [problem.path.to_s, problem.detail]
          )
        end
      end
    end

    def document_for(page_id)
      cached = @pages[page_id]
      return cached unless cached.nil?

      row = with_connection do |database|
        database.get_first_row(
          <<~SQL,
            SELECT id, page_type, name, page_date, title, status, created_at,
                   updated_at, published_at, path
            FROM pages
            WHERE id = ?
          SQL
          page_id
        )
      end
      raise KeyError, page_id if row.nil?

      PageDocument.new(
        id: row[0],
        page_type: row[1],
        name: row[2],
        page_date: row[3] && Date.iso8601(row[3]),
        title: row[4],
        status: row[5],
        created_at: Time.iso8601(row[6]),
        updated_at: Time.iso8601(row[7]),
        published_at: row[8] && Time.iso8601(row[8]),
        path: Pathname(row[9]),
        body: "",
        links: []
      )
    end

    def schema_compatible?
      return true unless path.exist?

      with_connection do |database|
        version = database.get_first_value("PRAGMA user_version").to_i
        return false unless [0, SCHEMA_VERSION].include?(version)

        tables = database.execute(
          "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).flatten
        tables.empty? || (REQUIRED_TABLES - tables).empty?
      end
    rescue SQLite3::Exception
      false
    end

    def rotate_corrupt_database!
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      destination = Pathname("#{path}.corrupt-#{timestamp}-#{SecureRandom.hex(4)}")
      File.rename(path, destination)
    end

    def with_connection
      database = connect
      yield database
    ensure
      database&.close
    end
  end
end
