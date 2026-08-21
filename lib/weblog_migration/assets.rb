# frozen_string_literal: true

require "digest"
require "cgi"
require "json"
require "pathname"
require "uri"
require "fileutils"

module WeblogMigration
  module Assets
    SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze
    EXPECTED_MIME_PREFIX = { "image" => "image/", "audio" => "audio/", "video" => "video/" }.freeze
    GYAZO_PAGE_HOSTS = %w[gyazo.com www.gyazo.com].freeze
    AssetFetchError = Class.new(StandardError)

    module_function

    def fetch_assets(manifest_path, output_dir, report_path, timeout: 20.0, max_bytes: 50 * 1024 * 1024)
      raise ArgumentError, "timeout must be greater than zero" unless timeout.positive?
      raise ArgumentError, "max_bytes must be greater than zero" unless max_bytes.positive?

      entries = load_manifest(manifest_path)
      output_dir = Pathname(output_dir)
      FileUtils.mkdir_p(output_dir)
      results = entries.map { |entry| fetch_entry(entry, output_dir, timeout, max_bytes) }
      report = {
        "manifest_path" => manifest_path.to_s,
        "run_at" => TimeFormat.iso8601(Time.now),
        "downloaded" => results.count { |result| result["status"] == "downloaded" },
        "failed" => results.count { |result| result["status"] == "failed" },
        "results" => results
      }
      report_path = Pathname(report_path)
      FileUtils.mkdir_p(report_path.dirname)
      report_path.write(JSON.pretty_generate(report) + "\n", encoding: "UTF-8")
      report
    end

    def load_manifest(path)
      payload = JSON.parse(Pathname(path).read(encoding: "UTF-8"))
      raw_assets = payload.is_a?(Hash) ? payload["assets"] : nil
      raise ArgumentError, "asset manifest is missing assets: #{path}" unless raw_assets.is_a?(Array)

      raw_assets.map do |raw_asset|
        raise ArgumentError, "asset manifest entry must be an object: #{path}" unless raw_asset.is_a?(Hash)
        id, url, kind = raw_asset.values_at("id", "url", "kind")
        unless [id, url, kind].all? { |value| value.is_a?(String) }
          raise ArgumentError, "asset manifest entry is missing id, url, or kind: #{path}"
        end
        raise ArgumentError, "asset ID is not a safe filename: #{id.inspect}" unless id.match?(SAFE_ID)
        raise ArgumentError, "unsupported asset kind: #{kind.inspect}" unless EXPECTED_MIME_PREFIX.key?(kind) || kind == "url"
        begin
          HTTP.request_uri(url)
        rescue HTTP::FetchError
          raise ArgumentError, "unsupported asset URL: #{url.inspect}"
        end
        { "id" => id, "url" => url, "kind" => kind }
      end
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise ArgumentError, "could not read asset manifest: #{path}: #{error.message}"
    end

    def fetch_entry(entry, output_dir, timeout, max_bytes)
      base_result = entry.dup
      fetch_url = entry.fetch("url")
      begin
        resolved_url = resolve_gyazo_url(fetch_url, timeout, max_bytes)
        fetch_url = resolved_url unless resolved_url.nil?
        response = HTTP.get(fetch_url, timeout:, max_bytes:)
        if response.status >= 400
          return base_result.merge(
            "status" => "failed",
            "http_status" => response.status,
            "error" => "HTTP #{response.status}: #{response.message}"
          )
        end

        expected_prefix = EXPECTED_MIME_PREFIX[entry["kind"]]
        if expected_prefix && !response.content_type.start_with?(expected_prefix)
          raise AssetFetchError, "expected #{expected_prefix.delete_suffix("/")} content, got #{response.content_type}"
        end
        data = response.body
        suffix = file_suffix(fetch_url, response.content_type)
        output_path = output_dir.join("#{entry.fetch("id")}#{suffix}")
        output_path.binwrite(data)
        result = base_result.merge(
          "status" => "downloaded",
          "http_status" => response.status,
          "mime_type" => response.content_type,
          "local_path" => output_path.basename.to_s,
          "size" => data.bytesize,
          "sha256" => Digest::SHA256.hexdigest(data)
        )
        result["fetched_url"] = fetch_url if fetch_url != entry.fetch("url")
        result
      rescue HTTP::FetchError, AssetFetchError, URI::InvalidURIError, ArgumentError => error
        base_result.merge("status" => "failed", "error" => error.message)
      end
    end

    def file_suffix(url, content_type)
      suffix = File.extname(HTTP.request_uri(url).path).downcase
      return suffix if suffix.match?(/\A\.[a-z0-9]+\z/) && suffix.length <= 10

      extension = AssetManifest::MIME_TYPES.key(content_type)
      extension || ".bin"
    end

    def resolve_gyazo_url(url, timeout, max_bytes)
      uri = HTTP.request_uri(url)
      return nil unless GYAZO_PAGE_HOSTS.include?(uri.host&.downcase)

      response = HTTP.get(url, timeout:, max_bytes:)
      raise AssetFetchError, "HTTP #{response.status}: #{response.message}" if response.status >= 400
      unless %w[text/html application/xhtml+xml].include?(response.content_type)
        raise AssetFetchError, "expected text/html Gyazo page, got #{response.content_type}"
      end
      image_url = HTMLMetaParser.new(response.body).image_url
      raise AssetFetchError, "Gyazo page does not contain an og:image URL" if image_url.nil?

      resolved = URI.join(response.url, image_url).to_s
      resolved_uri = URI.parse(resolved)
      raise AssetFetchError, "Gyazo og:image URL is not an HTTP(S) URL" unless %w[http https].include?(resolved_uri.scheme) && resolved_uri.host

      resolved
    rescue URI::InvalidURIError
      raise AssetFetchError, "Gyazo og:image URL is not an HTTP(S) URL"
    end

    class HTMLMetaParser
      attr_reader :image_url

      def initialize(html)
        @image_url = nil
        html.scan(/<meta\b[^>]*>/im) do |tag|
          attributes = parse_attributes(tag)
          property = (attributes["property"] || attributes["name"] || "").downcase
          next unless %w[og:image og:image:url].include?(property)
          value = CGI.unescapeHTML(attributes["content"].to_s).strip
          next if value.empty?
          @image_url = value
          break
        end
      end

      private

      def parse_attributes(tag)
        tag.scan(/([:\w-]+)\s*=\s*(["'])(.*?)\2/m).to_h { |name, _quote, value| [name.downcase, value] }
      end
    end
  end
end
