# frozen_string_literal: true

require "cgi"
require "ipaddr"
require "net/http"
require "resolv"
require "uri"

module WeblogAuthoring
  class EmbedMetadataFetcher
    FetchError = Class.new(StandardError)
    UnsafeUrlError = Class.new(FetchError)
    HTML_CONTENT_TYPES = %w[text/html application/xhtml+xml].freeze
    MAX_BYTES = 1_048_576
    MAX_REDIRECTS = 5
    TIMEOUT = 5

    def initialize(resolver: Resolv.method(:getaddresses))
      @resolver = resolver
    end

    def fetch(raw_url)
      response, final_url = request(raw_url)
      content_type = response.fetch(:content_type)
      raise FetchError, "HTMLではないURLです" unless HTML_CONTENT_TYPES.include?(content_type)

      metadata = Parser.new(response.fetch(:body))
      image_url = resolve_public_url(metadata.image_url, final_url)
      {
        "url" => raw_url,
        "canonical_url" => resolve_http_url(metadata.canonical_url, final_url) || final_url,
        "title" => metadata.title || URI.parse(final_url).host,
        "description" => metadata.description,
        "image_url" => image_url,
        "site_name" => metadata.site_name || URI.parse(final_url).host,
        "status" => "ready"
      }
    rescue URI::InvalidURIError => error
      raise FetchError, error.message
    end

    private

    def request(raw_url)
      current_url = raw_url

      MAX_REDIRECTS.times do
        uri, address = public_uri(current_url)
        response = http_get(uri, address)
        if response.is_a?(Net::HTTPRedirection) && response["location"]
          current_url = URI.join(current_url, response["location"]).to_s
          next
        end
        raise FetchError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        content_type = response["content-type"].to_s.split(";", 2).first.downcase
        body = response.body.to_s.force_encoding(Encoding::UTF_8).scrub
        return [{ body:, content_type: }, current_url]
      end

      raise FetchError, "リダイレクトが多すぎます"
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError => error
      raise FetchError, error.message
    end

    def http_get(uri, address)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = address
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      request = Net::HTTP::Get.new(uri.request_uri)
      body = +""
      response = http.start do |client|
        client.request(request) do |incoming|
          if incoming["content-length"].to_i > MAX_BYTES
            raise FetchError, "レスポンスが大きすぎます"
          end
          incoming.read_body do |chunk|
            body << chunk
            raise FetchError, "レスポンスが大きすぎます" if body.bytesize > MAX_BYTES
          end
          incoming
        end
      end
      response.body = body
      response
    end

    def public_uri(raw_url)
      uri = URI.parse(raw_url)
      unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil?
        raise UnsafeUrlError, "HTTP(S) URLではありません"
      end

      addresses = @resolver.call(uri.host)
      raise UnsafeUrlError, "ホストを解決できません" if addresses.empty?
      if addresses.any? { |value| private_address?(value) }
        raise UnsafeUrlError, "プライベートネットワークには接続できません"
      end

      uri.path = "/" if uri.path.empty?
      [uri, addresses.first]
    rescue Resolv::ResolvError, IPAddr::InvalidAddressError => error
      raise FetchError, error.message
    end

    def private_address?(value)
      address = IPAddr.new(value)
      address.private? || address.loopback? || address.link_local? || address.to_i.zero?
    end

    def resolve_public_url(value, base_url)
      resolved = resolve_http_url(value, base_url)
      return nil if resolved.nil?

      public_uri(resolved)
      resolved
    rescue FetchError
      nil
    end

    def resolve_http_url(value, base_url)
      return nil if value.nil? || value.empty?

      resolved = URI.join(base_url, value).to_s
      uri = URI.parse(resolved)
      %w[http https].include?(uri.scheme) && uri.host ? resolved : nil
    end

    class Parser
      attr_reader :canonical_url, :description, :image_url, :site_name, :title

      def initialize(html)
        metadata = {}
        html.scan(/<meta\b[^>]*>/im) do |tag|
          attributes = attributes(tag)
          key = (attributes["property"] || attributes["name"]).to_s.downcase
          content = clean(attributes["content"], key == "og:description" ? 2_000 : 300)
          metadata[key] ||= content unless content.nil?
        end

        @title = metadata["og:title"] || document_title(html)
        @description = metadata["og:description"] || metadata["description"]
        @image_url = metadata["og:image"] || metadata["og:image:url"]
        @site_name = metadata["og:site_name"]
        @canonical_url = metadata["og:url"] || canonical_link(html)
      end

      private

      def attributes(tag)
        tag.scan(/([:\w-]+)\s*=\s*(["'])(.*?)\2/m).to_h do |name, _quote, value|
          [name.downcase, value]
        end
      end

      def canonical_link(html)
        html.scan(/<link\b[^>]*>/im).each do |tag|
          values = attributes(tag)
          return values["href"] if values["rel"].to_s.downcase.split.include?("canonical")
        end
        nil
      end

      def document_title(html)
        match = html.match(/<title\b[^>]*>(.*?)<\/title>/im)
        clean(match&.[](1), 300)
      end

      def clean(value, limit)
        normalized = CGI.unescapeHTML(value.to_s.gsub(/<[^>]*>/, " ")).split.join(" ")
        normalized.empty? ? nil : normalized.slice(0, limit)
      end
    end
  end
end
