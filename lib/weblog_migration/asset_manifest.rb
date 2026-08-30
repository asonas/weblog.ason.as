# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require "pathname"
require "fileutils"

module WeblogMigration
  module AssetManifest
    IMAGE_HOSTS = %w[gyazo.com i.gyazo.com].freeze
    MIME_TYPES = {
      ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png", ".gif" => "image/gif",
      ".webp" => "image/webp", ".svg" => "image/svg+xml", ".mp3" => "audio/mpeg", ".wav" => "audio/wav",
      ".m4a" => "audio/mp4", ".ogg" => "audio/ogg", ".mp4" => "video/mp4", ".webm" => "video/webm",
      ".mov" => "video/quicktime",
    }.freeze

    module_function

    def canonicalize_url(url)
      raw_url = url.to_s.strip
      match = raw_url.match(%r{\A(https?)://([^/?#]+)([^?#]*)(?:\?([^#]*))?(?:#.*)?\z}i)
      raise ArgumentError, "unsupported external URL: #{url.inspect}" if match.nil?

      scheme = match[1].downcase
      authority = match[2].downcase
      path = match[3]
      query = match[4]
      "#{scheme}://#{authority}#{path}#{query.nil? ? "" : "?#{query}"}"
    rescue ArgumentError
      raise ArgumentError, "unsupported external URL: #{url.inspect}"
    end

    def stable_url_asset_id(url)
      "asset_#{Digest::SHA256.hexdigest(canonicalize_url(url))[0, 16]}"
    end

    def stable_asset_id(source_path)
      "asset_#{Digest::SHA256.hexdigest(source_path.to_s)[0, 16]}"
    end

    def classify_url(url)
      parsed = HTTP.request_uri(url)
      return "image" if IMAGE_HOSTS.include?(parsed.host&.downcase)

      mime_type = MIME_TYPES[File.extname(parsed.path).downcase]
      return "url" if mime_type.nil?
      return "image" if mime_type.start_with?("image/")
      return "audio" if mime_type.start_with?("audio/")
      return "video" if mime_type.start_with?("video/")

      "url"
    rescue URI::InvalidURIError
      "url"
    end

    def build_asset_manifest(normalized)
      sources = Hash.new { |hash, key| hash[key] = [] }
      kinds = {}
      normalized.posts.each do |post|
        post.external_urls.each do |raw_url|
          begin
            canonical_url = canonicalize_url(raw_url)
          rescue ArgumentError
            next
          end
          sources[canonical_url] << post.id unless sources[canonical_url].include?(post.id)
          kinds[canonical_url] ||= classify_url(canonical_url)
        end
      end
      sources.keys.sort.map do |url|
        AssetManifestEntry.new(
          id: stable_url_asset_id(url),
          url:,
          kind: kinds.fetch(url),
          source_post_ids: sources.fetch(url).sort
        )
      end.sort_by(&:id)
    end

    def write_asset_manifest(output_dir, normalized)
      output_dir = Pathname(output_dir)
      FileUtils.mkdir_p(output_dir)
      path = output_dir.join("asset-manifest.json")
      payload = { "assets" => build_asset_manifest(normalized).map(&:to_h) }
      path.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
      path
    end
  end
end
