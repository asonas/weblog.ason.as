# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "uri"
require_relative "cover_image"
require_relative "draft_publication"
require_relative "markdown_parser"
require_relative "names"

module WeblogAuthoring
  # Imports articles that are already published on another site. Each article
  # keeps its historical timestamps, is served at /<slug>, and shows a separate
  # display title instead of the slug.
  class ExternalArticleImport
    FIELDS = %w[slug display_title body created_at updated_at published_at cover_mode cover_image_url].freeze
    REQUIRED_FIELDS = %w[slug display_title body created_at updated_at published_at].freeze
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
    SOURCE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
    # The first path segment must not shadow a system route or a static file.
    RESERVED_SEGMENTS = %w[draft-editor draft-offline.js published editor authoring oauth assets search index.html feed.xml sitemap.xml 404.html].freeze
    URL_NAMESPACE = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
    METADATA_LIMIT = 4096

    # RFC 4122 version 5. Ids are pure functions of the manifest so a rerun finds its earlier work.
    def self.uuid_v5(name, namespace: URL_NAMESPACE)
      bytes = Digest::SHA1.digest([namespace.delete("-")].pack("H*") + name.b).bytes.first(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x50
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.pack("C*").unpack1("H*")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def initialize(store:, cutover: true)
      @store = store
      @cutover = cutover
    end

    def prepare(manifest)
      raise DraftStore::Error, "Unsupported import format" unless manifest.is_a?(Hash) && manifest["format"] == 1
      raise DraftStore::Error, "Import requires an article array" unless manifest["articles"].is_a?(Array) && !manifest["articles"].empty?
      source = manifest["source"]
      raise DraftStore::Error, "Import requires a source name" unless source.is_a?(String) && SOURCE_NAME.match?(source)
      origin = site_origin(manifest["site_url"])
      problems = []
      articles = manifest.fetch("articles").each_with_index.filter_map do |article, index|
        validate(article, index, source, origin, problems)
      end
      articles.map { |article| article.fetch("route") }.tally.each { |slug, count| problems << "#{slug}: slug appears #{count} times" if count > 1 }
      raise DraftStore::Error, problems.join("\n") unless problems.empty?
      { "source" => source, "origin" => origin, "articles" => articles.sort_by { |article| article.fetch("route") } }
    end

    # Read-only: what an import would do with each article.
    def plan(manifest)
      prepare(manifest).fetch("articles").map do |article|
        { "slug" => article.fetch("route"), "id" => article.fetch("id") }.merge(@store.external_article_status(article))
      end
    end

    def import(manifest)
      articles = prepare(manifest).fetch("articles")
      states = articles.map { |article| @store.external_article_status(article) }
      conflicts = articles.zip(states).select { |_article, state| state.fetch("status") == "conflict" }
      unless conflicts.empty?
        raise DraftStore::Error.new(conflicts.map { |article, state| "#{article.fetch('route')}: #{state.fetch('reason')}" }.join("\n"), 409)
      end
      results = articles.zip(states).map do |article, state|
        status = state.fetch("status")
        version = @store.import_external_article(article, seed(article.fetch("body")), cutover: @cutover) if status == "new"
        { "slug" => article.fetch("route"), "id" => article.fetch("id"), "version_id" => version || article.fetch("version_id"), "status" => status == "new" ? "imported" : status }
      end
      publication = DraftPublication.local(store: @store)
      articles.each { |article| verify(article, publication) }
      results
    end

    private

    def site_origin(site_url)
      site = URI.parse(site_url.to_s)
      raise DraftStore::Error, "Import requires a site origin" unless %w[http https].include?(site.scheme) && site.host && ["", "/"].include?(site.path) && !site.query && !site.fragment && !site.userinfo
      site.to_s.delete_suffix("/")
    rescue URI::InvalidURIError
      raise DraftStore::Error, "Import requires a site origin"
    end

    def validate(article, index, source, origin, problems)
      unless article.is_a?(Hash)
        problems << "articles[#{index}]: not an object"
        return nil
      end
      slug = article["slug"].is_a?(String) ? article["slug"] : nil
      label = slug || "articles[#{index}]"
      before = problems.length
      (article.keys - FIELDS).each { |key| problems << "#{label}: unknown field #{key}" }
      (REQUIRED_FIELDS - article.keys).each { |key| problems << "#{label}: #{key} is required" }
      return nil if problems.length > before

      title = display_title(article["display_title"], label, problems)
      body = body_text(article["body"], label, problems)
      times = timestamps(article, label, problems)
      cover_mode, cover_image_url = cover(article, label, problems)
      problems.concat(slug_problems(slug).map { |problem| "#{label}: #{problem}" })
      return nil unless problems.length == before && title && body && times && slug

      route = slug
      metadata = { "title" => route, "page_type" => "named", "page_date" => "", "cover_mode" => cover_mode, "cover_image_url" => cover_image_url, "display_title" => title }
      # Same formula as DraftPublication#verified_result; display_title is not publication content.
      content_hash = Digest::SHA256.hexdigest(JSON.generate([body, route, "named", cover_mode, cover_image_url]))
      id = self.class.uuid_v5("#{source}:#{route}")
      { "id" => id, "version_id" => self.class.uuid_v5("#{id}:import-v1"), "route" => route, "body" => body, "metadata" => metadata,
        "created_at" => times.fetch(:created), "updated_at" => times.fetch(:updated), "published_at" => times.fetch(:published),
        "atom_id" => "#{origin}/#{WeblogAuthoring.encoded_page_name(route)}", "content_hash" => content_hash, }
    end

    def slug_problems(slug)
      return ["slug must be a string"] unless slug
      begin
        return ["slug would change when normalized"] unless WeblogAuthoring.validate_page_name(slug) == slug
      rescue ArgumentError => error
        return [error.message]
      end
      problems = []
      problems << "slug is longer than #{METADATA_LIMIT} bytes" if slug.bytesize > METADATA_LIMIT
      problems << "slug is reserved" if slug == "llms.txt" || RESERVED_SEGMENTS.include?(slug.split("/").first)
      problems << "slug must not be a date route" if WeblogAuthoring::DATE_NAME.match?(slug)
      problems
    end

    def display_title(value, label, problems)
      unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && value.bytesize <= METADATA_LIMIT && !value.match?(/[\r\n]/)
        problems << "#{label}: display_title must be a single non-empty line of at most #{METADATA_LIMIT} bytes"
        return nil
      end
      value.strip
    end

    def body_text(value, label, problems)
      unless value.is_a?(String) && value.valid_encoding?
        problems << "#{label}: body must be valid UTF-8 text"
        return nil
      end
      # Working content is hashed with normalized line endings, so store the same text.
      body = value.gsub("\r\n", "\n")
      if body.bytesize > DraftStore::BODY_LIMIT
        problems << "#{label}: body exceeds #{DraftStore::BODY_LIMIT} bytes"
        return nil
      end
      offenders = image_targets(body).reject { |target| CoverImage.local?(target) }
      problems << "#{label}: image targets must start with /assets/: #{offenders.uniq.join(', ')}" unless offenders.empty?
      offenders.empty? ? body : nil
    end

    def image_targets(body)
      targets = []
      walk = lambda do |node|
        targets << node.attr["src"].to_s.gsub(/\\([[:punct:]])/, '\1') if node.type == :img
        node.children.each(&walk)
      end
      walk.call(Kramdown::Document.new(body, input: "WeblogGFM").root)
      targets
    end

    def timestamps(article, label, problems)
      times = %w[created_at updated_at published_at].to_h do |field|
        value = article[field]
        unless value.is_a?(String) && TIMESTAMP.match?(value)
          problems << "#{label}: #{field} must be an ISO 8601 timestamp with an explicit offset"
          next [field, nil]
        end
        [field, Time.iso8601(value).utc]
      rescue ArgumentError
        problems << "#{label}: #{field} is not a valid timestamp"
        [field, nil]
      end
      return nil if times.values.any?(&:nil?)
      problems << "#{label}: updated_at must not be earlier than published_at" if times.fetch("updated_at") < times.fetch("published_at")
      # Same format as Time.now.utc.iso8601(6) used for working timestamps.
      { created: times.fetch("created_at").iso8601(6), updated: times.fetch("updated_at").iso8601(6), published: times.fetch("published_at").iso8601(6) }
    end

    def cover(article, label, problems)
      CoverImage.validate(article["cover_mode"], article["cover_image_url"])
    rescue ArgumentError => error
      problems << "#{label}: #{error.message}"
      [nil, nil]
    end

    def seed(body)
      output, error, status = Open3.capture3("node", File.join(File.expand_path("../..", __dir__), "scripts/seed-draft.mjs"), stdin_data: JSON.generate(body))
      raise DraftStore::Error.new("Import seed failed: #{error[0, 200]}", 503) unless status.success?
      JSON.parse(output)
    end

    def verify(article, publication)
      id = article.fetch("id")
      snapshot = @store.published_snapshot(id)
      document = @store.read(id, {})
      fields = %w[route body content_hash updated_at published_at atom_id]
      mismatches = []
      mismatches << "published version" unless snapshot && snapshot.fetch("id") == article.fetch("version_id")
      if snapshot
        mismatches.concat(fields.reject { |field| snapshot[field] == article[field] })
        mismatches << "article_created_at" unless snapshot["article_created_at"] == article["created_at"]
        mismatches << "metadata" unless snapshot["metadata"] == article["metadata"]
      end
      mismatches << "working timestamps" unless document.values_at("created_at", "updated_at") == article.values_at("created_at", "updated_at")
      mismatches << "working content hash" unless publication.working_content_hash(id).fetch("content_hash") == article.fetch("content_hash")
      return if mismatches.empty?
      raise DraftStore::Error.new("Import verification failed for #{article.fetch('route')} (#{mismatches.join(', ')}); preserve source and destination", 409)
    end
  end
end
