# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "pathname"
require "uri"
require "fileutils"

module WeblogMigration
  module UrlMetadata
    SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze
    SAFE_FILENAME = SAFE_ID
    HTML_CONTENT_TYPES = %w[text/html application/xhtml+xml].freeze
    TEXT_LIMITS = { "title" => 300, "description" => 2_000 }.freeze

    module_function

    def fetch_url_metadata(manifest_path, output_path, assets_dir, report_path, timeout: 20.0, max_bytes: 5 * 1024 * 1024)
      raise ArgumentError, "timeout must be greater than zero" unless timeout.positive?
      raise ArgumentError, "max_bytes must be greater than zero" unless max_bytes.positive?

      entries = load_url_manifest(manifest_path)
      assets_dir = Pathname(assets_dir)
      FileUtils.mkdir_p(assets_dir)
      results = entries.map { |entry| fetch_url_entry(entry, assets_dir, timeout, max_bytes) }
      output_path = Pathname(output_path)
      FileUtils.mkdir_p(output_path.dirname)
      output_path.write(JSON.pretty_generate("assets" => results, "version" => 1) + "\n", encoding: "UTF-8")
      report = {
        "assets" => results.length,
        "fallback" => results.count { |result| result["status"] == "fallback" },
        "manifest_path" => manifest_path.to_s,
        "metadata_path" => output_path.to_s,
        "ready" => results.count { |result| result["status"] == "ready" },
        "results" => results,
        "run_at" => TimeFormat.iso8601(Time.now)
      }
      report_path = Pathname(report_path)
      FileUtils.mkdir_p(report_path.dirname)
      report_path.write(JSON.pretty_generate(report) + "\n", encoding: "UTF-8")
      report
    end

    def load_url_metadata(path)
      return {} if path.nil?

      path = Pathname(path)
      payload = JSON.parse(path.read(encoding: "UTF-8"))
      raw_assets = payload.is_a?(Hash) ? payload["assets"] : nil
      raise ArgumentError, "URL metadata is missing assets: #{path}" unless raw_assets.is_a?(Array)
      metadata = {}
      raw_assets.each do |raw_asset|
        raise ArgumentError, "URL metadata entry must be an object: #{path}" unless raw_asset.is_a?(Hash)
        asset_id = raw_asset["id"]
        url = raw_asset["url"]
        raise ArgumentError, "URL metadata has an unsafe asset ID: #{asset_id.inspect}" unless asset_id.is_a?(String) && asset_id.match?(SAFE_ID)
        raise ArgumentError, "URL metadata entry is missing URL: #{asset_id.inspect}" unless url.is_a?(String)
        raise ArgumentError, "URL metadata contains duplicate asset ID: #{asset_id.inspect}" if metadata.key?(asset_id)
        image = raw_asset["image"]
        if image
          local_path = image.is_a?(Hash) ? image["local_path"] : nil
          unless image.is_a?(Hash) && local_path.is_a?(String) && local_path.match?(SAFE_FILENAME)
            raise ArgumentError, "URL metadata image has an unsafe local path: #{asset_id.inspect}"
          end
        end
        metadata[asset_id] = raw_asset
      end
      metadata
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise ArgumentError, "could not read URL metadata: #{path}: #{error.message}"
    end

    def load_url_manifest(path)
      valid_entries = Assets.load_manifest(path)
      payload = JSON.parse(Pathname(path).read(encoding: "UTF-8"))
      raw_assets = payload.is_a?(Hash) ? payload["assets"] : nil
      raise ArgumentError, "asset manifest is missing assets: #{path}" unless raw_assets.is_a?(Array)
      raw_by_id = raw_assets.to_h { |raw_asset| [raw_asset.fetch("id"), raw_asset] }
      valid_entries.filter_map do |entry|
        next unless entry["kind"] == "url"
        raw_asset = raw_by_id.fetch(entry.fetch("id"))
        source_post_ids = raw_asset.fetch("source_post_ids", [])
        unless source_post_ids.is_a?(Array) && source_post_ids.all? { |post_id| post_id.is_a?(String) }
          raise ArgumentError, "asset manifest source_post_ids must be strings: #{entry["id"].inspect}"
        end
        { "id" => entry.fetch("id"), "url" => entry.fetch("url"), "kind" => "url", "source_post_ids" => source_post_ids.dup }
      end
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise ArgumentError, "could not read asset manifest: #{path}: #{error.message}"
    end

    def fetch_url_entry(entry, assets_dir, timeout, max_bytes)
      url = entry.fetch("url")
      result = {
        "description" => nil,
        "domain" => domain(url),
        "id" => entry.fetch("id"),
        "image" => nil,
        "image_url" => nil,
        "kind" => "url",
        "source_post_ids" => entry.fetch("source_post_ids").dup,
        "status" => "fallback",
        "title" => nil,
        "url" => url
      }

      begin
        response = HTTP.get(url, timeout:, max_bytes:)
        if response.status >= 400
          return failure_result(result, "HTTP #{response.status}: #{response.message}", http_status: response.status)
        end
        unless HTML_CONTENT_TYPES.include?(response.content_type)
          raise Assets::AssetFetchError, "expected text/html content, got #{response.content_type}"
        end
        parser = PageMetadataParser.new(response.body)
        result["http_status"] = response.status
        result["title"] = parser.og_title || parser.document_title
        result["description"] = parser.og_description
        unless parser.og_image.nil?
          image_url = URI.join(response.url, parser.og_image).to_s
          image_uri = URI.parse(image_url)
          unless %w[http https].include?(image_uri.scheme) && image_uri.host
            return failure_result(result, "og:image URL is not an HTTP(S) URL", keep_metadata: true)
          end
          result["image_url"] = image_url
          result["image"] = fetch_image(image_url, assets_dir, entry.fetch("id"), timeout, max_bytes)
          result["status"] = "ready"
        end
        result
      rescue HTTP::FetchError, Assets::AssetFetchError, URI::InvalidURIError, ArgumentError => error
        failure_result(result, error.message, keep_metadata: result["title"] || result["description"])
      end
    end

    def failure_result(result, error, http_status: nil, keep_metadata: false)
      result = result.dup
      result["status"] = "fallback"
      result["error"] = error
      result["http_status"] = http_status unless http_status.nil?
      unless keep_metadata
        result["title"] = nil
        result["description"] = nil
      end
      result
    end

    def fetch_image(url, assets_dir, asset_id, timeout, max_bytes)
      response = HTTP.get(url, timeout:, max_bytes:)
      if response.status >= 400
        raise Assets::AssetFetchError, "HTTP #{response.status}: #{response.message}"
      end
      unless response.content_type.start_with?("image/")
        raise Assets::AssetFetchError, "expected image content, got #{response.content_type}"
      end
      data = response.body
      local_path = "#{asset_id}#{Assets.file_suffix(url, response.content_type)}"
      assets_dir.join(local_path).binwrite(data)
      {
        "http_status" => response.status,
        "local_path" => local_path,
        "mime_type" => response.content_type,
        "sha256" => Digest::SHA256.hexdigest(data),
        "size" => data.bytesize,
        "url" => url
      }
    end

    def domain(url)
      URI.parse(url).host || URI.parse(url).to_s
    rescue URI::InvalidURIError
      url
    end

    def clean_text(value, limit)
      normalized = CGI.unescapeHTML(value.to_s).split.join(" ")
      normalized.empty? ? nil : normalized[0, limit]
    end

    class PageMetadataParser
      attr_reader :og_title, :og_description, :og_image

      def initialize(html)
        @og_title = nil
        @og_description = nil
        @og_image = nil
        @title_parts = []
        @in_title = false
        html.scan(/<meta\b[^>]*>/im) do |tag|
          attributes = parse_attributes(tag)
          property = (attributes["property"] || attributes["name"] || "").downcase
          content = attributes["content"]
          next if content.nil? || content.empty?
          case property
          when "og:title"
            @og_title ||= UrlMetadata.clean_text(content, TEXT_LIMITS.fetch("title"))
          when "og:description"
            @og_description ||= UrlMetadata.clean_text(content, TEXT_LIMITS.fetch("description"))
          when "og:image", "og:image:url"
            value = CGI.unescapeHTML(content).strip
            @og_image ||= value unless value.empty?
          end
        end
        html.scan(/<title\b[^>]*>(.*?)<\/title>/im) { |match| @title_parts << match.first }
      end

      def document_title
        UrlMetadata.clean_text(@title_parts.join, TEXT_LIMITS.fetch("title"))
      end

      private

      def parse_attributes(tag)
        tag.scan(/([:\w-]+)\s*=\s*(["'])(.*?)\2/m).to_h { |name, _quote, value| [name.downcase, value] }
      end
    end
  end
end
