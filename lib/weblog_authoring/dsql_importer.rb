# frozen_string_literal: true

require "openssl"
require "json"
require "pathname"
require "sqlite3"

ENV["PGSSLROOTCERT"] ||= OpenSSL::X509::DEFAULT_CERT_FILE

require "aurora_dsql_pg"

module WeblogAuthoring
  class DsqlImporter
    SCHEMA = "weblog_authoring"
    BATCH_SIZE = 25

    def initialize(host:, database_path:, export_path: nil, connector: AuroraDsql::Pg)
      @host = host
      @database_path = Pathname(database_path)
      @export_path = export_path && Pathname(export_path)
      @connector = connector
    end

    def counts
      with_source do |source|
        pages, excluded_pages = source_pages(source)
        page_ids = pages.to_h { |page| [page.fetch("id"), true] }
        links = source.execute("SELECT * FROM links").count { |link| page_ids[link.fetch("source_id")] }
        { pages: pages.length, links:, excluded_pages: excluded_pages.length }
      end
    end

    def run(prune_excluded: false)
      source = open_source
      connection = @connector.connect(host: @host)
      pages, excluded_pages = source_pages(source)
      page_ids = pages.to_h { |page| [page.fetch("id"), true] }
      links = source.execute("SELECT * FROM links ORDER BY source_id, position")
        .select { |link| page_ids[link.fetch("source_id")] }
      links_by_source = links.group_by { |link| link.fetch("source_id") }

      pages.each_slice(BATCH_SIZE) do |batch|
        connection.transaction { batch.each { |page| import_page(connection, page) } }
      end
      pages.map { |page| page.fetch("id") }.each_slice(BATCH_SIZE) do |batch|
        connection.transaction do
          batch.each { |source_id| import_links(connection, source_id, links_by_source.fetch(source_id, [])) }
        end
      end

      prune_pages(connection, excluded_pages) if prune_excluded

      { pages: pages.length, links: links.length, excluded_pages: excluded_pages.length }
    ensure
      source&.close
      connection&.close
    end

    private

    def with_source
      source = open_source
      yield source
    ensure
      source&.close
    end

    def open_source
      raise ArgumentError, "SQLite database does not exist: #{@database_path}" unless @database_path.file?

      database = SQLite3::Database.new(@database_path.to_s, readonly: true)
      database.results_as_hash = true
      integrity = database.get_first_value("PRAGMA quick_check")
      raise ArgumentError, "SQLite integrity check failed: #{integrity}" unless integrity == "ok"

      database
    end

    def source_pages(source)
      pages = source.execute("SELECT * FROM pages ORDER BY created_at, id")
      return [pages, []] unless @export_path
      raise ArgumentError, "Scrapbox export does not exist: #{@export_path}" unless @export_path.file?

      exported_names = JSON.parse(@export_path.read(encoding: "UTF-8")).fetch("pages")
        .to_h { |page| [page.fetch("title"), true] }
      pages.partition { |page| exported_names[page.fetch("name")] }
    end

    def prune_pages(connection, pages)
      pages.each_slice(BATCH_SIZE) do |batch|
        connection.transaction do
          batch.each do |page|
            id = page.fetch("id")
            connection.exec_params("UPDATE #{SCHEMA}.links SET target_id = NULL WHERE target_id = $1", [id])
            connection.exec_params("DELETE FROM #{SCHEMA}.links WHERE source_id = $1", [id])
            connection.exec_params("DELETE FROM #{SCHEMA}.pages WHERE id = $1", [id])
          end
        end
      end
    end

    def import_page(connection, page)
      exists = connection.exec_params(
        "SELECT 1 FROM #{SCHEMA}.pages WHERE id = $1 LIMIT 1",
        [page.fetch("id")]
      ).ntuples.positive?
      values = page_values(page)
      if exists
        connection.exec_params(<<~SQL, values.drop(1) + [values.first])
          UPDATE #{SCHEMA}.pages
          SET page_type = $1, name = $2, page_date = $3, title = $4,
              status = $5, created_at = $6, updated_at = $7, published_at = $8,
              path = $9, body_hash = $10, is_empty = $11, body = $12,
              cover_mode = $13, cover_image_url = $14
          WHERE id = $15
        SQL
      else
        connection.exec_params(<<~SQL, values)
          INSERT INTO #{SCHEMA}.pages (
            id, page_type, name, page_date, title, status, created_at,
            updated_at, published_at, path, body_hash, is_empty, body, cover_mode, cover_image_url
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
        SQL
      end
    end

    def import_links(connection, source_id, links)
      connection.exec_params("DELETE FROM #{SCHEMA}.links WHERE source_id = $1", [source_id])
      links.each do |link|
        connection.exec_params(<<~SQL, [source_id, link["target_id"], link.fetch("target_name"), link.fetch("position")])
          INSERT INTO #{SCHEMA}.links (source_id, target_id, target_name, position)
          VALUES ($1, $2, $3, $4)
        SQL
      end
    end

    def page_values(page)
      %w[
        id page_type name page_date title status created_at updated_at published_at
        path body_hash is_empty body cover_mode cover_image_url
      ].map do |key|
        next page.fetch(key).to_i == 1 if key == "is_empty"
        next page[key] || "auto" if key == "cover_mode"

        page[key]
      end
    end
  end
end
