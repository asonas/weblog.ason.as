# frozen_string_literal: true

require "uri"
require_relative "draft_publication"

module WeblogAuthoring
  class DraftMigration
    def self.export_sqlite(path, site_url:)
      require "sqlite3"
      database = SQLite3::Database.new(path.to_s, readonly: true)
      database.results_as_hash = true
      export_rows(database.execute("SELECT id, page_type, name, page_date, title, status, body, cover_mode, cover_image_url, created_at, updated_at, published_at FROM pages ORDER BY id"), site_url:)
    ensure
      database&.close
    end

    def self.export_rows(rows, site_url:)
      articles = rows.map do |row|
        raise DraftStore::Error, "Unpublished legacy article requires an explicit migration decision" unless row.fetch("status") == "published"
        named = row.fetch("page_type") == "named"
        { "id" => row.fetch("id"), "page_type" => row.fetch("page_type"), "route" => named ? row.fetch("name") : row.fetch("page_date"),
          "title" => named ? row.fetch("name") : row["title"].to_s, "body" => row.fetch("body"),
          "cover_mode" => row.fetch("cover_mode"), "cover_image_url" => row["cover_image_url"],
          "created_at" => row.fetch("created_at"), "updated_at" => row.fetch("updated_at"),
          "published_at" => row["published_at"] || row.fetch("created_at"), }
      end
      manifest = { "format" => 1, "site_url" => site_url, "articles" => articles }
      new(store: nil).prepare(manifest)
      manifest
    end

    def initialize(store:)
      @store = store
    end

    def import(manifest)
      plan = prepare(manifest)
      fingerprint = plan.fetch("fingerprint")
      articles = plan.fetch("articles")
      @store.begin_migration(fingerprint)
      root = File.expand_path("../..", __dir__)
      articles.each do |source|
        output, error, status = Open3.capture3("node", File.join(root, "scripts/seed-draft.mjs"), stdin_data: JSON.generate(source.fetch("body")))
        raise DraftStore::Error.new("Migration seed failed: #{error[0, 200]}", 503) unless status.success?
        @store.import_legacy_article(fingerprint, source, JSON.parse(output))
      end
      publication = DraftPublication.local(store: @store)
      articles.each do |source|
        id = source.fetch("id")
        expected = source.except("id", "created_at").merge("article_id" => id, "article_created_at" => source.fetch("created_at"))
        snapshot = @store.published_snapshot(id)
        document = @store.read(id, {})
        same_metadata = document.fetch("metadata").transform_values { |field| field.fetch("value") } == source.fetch("metadata")
        same_times = document.values_at("created_at", "updated_at") == source.values_at("created_at", "updated_at")
        unless snapshot && snapshot.slice(*expected.keys) == expected && same_metadata && same_times && publication.working_content_hash(id).fetch("content_hash") == source.fetch("content_hash")
          raise DraftStore::Error.new("Migration verification failed; preserve source and destination", 409)
        end
      end
      @store.complete_migration(fingerprint)
      { "articles" => articles.length, "fingerprint" => fingerprint }
    end

    def prepare(manifest)
      raise DraftStore::Error, "Unsupported migration format" unless manifest.is_a?(Hash) && manifest["format"] == 1
      raise DraftStore::Error, "Migration requires an article array" unless manifest["articles"].is_a?(Array)
      raise DraftStore::Error, "Migration requires a site origin" unless manifest["site_url"].is_a?(String)
      site = URI.parse(manifest.fetch("site_url"))
      raise DraftStore::Error, "Migration requires a site origin" unless %w[http https].include?(site.scheme) && site.host && ["", "/"].include?(site.path) && !site.query && !site.fragment && !site.userinfo
      origin = site.to_s.delete_suffix("/")
      articles = manifest.fetch("articles").map { |source| validate(source, origin) }.sort_by { |source| source.fetch("id") }
      %w[id route].each do |key|
        raise DraftStore::Error, "Duplicate migration #{key}" unless articles.map { |source| source.fetch(key) }.uniq.length == articles.length
      end
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([origin, articles]))
      { "articles" => articles, "fingerprint" => fingerprint }
    rescue KeyError, URI::InvalidURIError, ArgumentError => error
      raise DraftStore::Error, error.message
    end

    private

    def validate(source, origin)
      raise DraftStore::Error, "Invalid migration record" unless source.is_a?(Hash)
      id, type, route, title, body = source.values_at("id", "page_type", "route", "title", "body")
      raise DraftStore::Error, "Invalid migration ID" unless id.is_a?(String) && /\A(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/.match?(id)
      raise DraftStore::Error, "Invalid migration article type" unless %w[named date].include?(type)
      raise DraftStore::Error, "Invalid migration title" unless title.is_a?(String) && title.bytesize <= 4096
      raise DraftStore::Error, "Invalid migration body" unless body.is_a?(String) && body.valid_encoding? && body.bytesize <= DraftStore::BODY_LIMIT
      raise DraftStore::Error, "Migration route would change" unless WeblogAuthoring.validate_page_name(route) == route
      raise DraftStore::Error, "Migration route is reserved" if %w[draft-editor draft-offline.js published].include?(route.split("/").first)
      if type == "date"
        raise DraftStore::Error, "Invalid diary route" unless WeblogAuthoring::DATE_NAME.match?(route)
        Date.iso8601(route)
      else
        raise DraftStore::Error, "Named article title must match route" unless title == route
      end
      created, updated, published = source.values_at("created_at", "updated_at", "published_at")
      [created, updated, published].each do |time|
        raise DraftStore::Error, "Migration timestamp is required" unless time.is_a?(String)
        Time.iso8601(time)
      end
      mode, cover = CoverImage.validate(source.fetch("cover_mode"), source["cover_image_url"])
      metadata = { "title" => title, "page_type" => type, "page_date" => type == "date" ? route : "", "cover_mode" => mode, "cover_image_url" => cover }
      content = [body.gsub("\r\n", "\n"), title.strip, type, mode, cover]
      content << route if type == "date"
      { "id" => id, "route" => route, "body" => body, "metadata" => metadata,
        "created_at" => created, "updated_at" => updated, "published_at" => published,
        "atom_id" => "#{origin}/#{WeblogAuthoring.encoded_route(route)}", "content_hash" => Digest::SHA256.hexdigest(JSON.generate(content)), }
    end
  end
end
