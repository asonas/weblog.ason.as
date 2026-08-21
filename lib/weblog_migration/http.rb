# frozen_string_literal: true

require "net/http"
require "uri"

module WeblogMigration
  module HTTP
    Response = Struct.new(:status, :message, :content_type, :content_length, :body, :url, keyword_init: true)
    FetchError = Class.new(StandardError)
    PATH_SAFE = /[^A-Za-z0-9\-._~!$&'()*+,;=:@\/%]/.freeze
    QUERY_SAFE = /[^A-Za-z0-9\-._~!$&'()*+,;=:@\/?%]/.freeze

    module_function

    def get(url, timeout:, max_bytes:, redirects: 5)
      current_url = url.to_s
      redirects.times do
        uri = request_uri(current_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        response = http.start { |client| client.request(Net::HTTP::Get.new(uri.request_uri)) }
        if response.is_a?(Net::HTTPRedirection) && response["location"]
          current_url = URI.join(current_url, response["location"]).to_s
          next
        end

        body = response.body.to_s
        content_length = response["content-length"]
        if content_length && content_length.to_i > max_bytes
          raise FetchError, "response exceeds #{max_bytes} bytes"
        end
        raise FetchError, "response exceeds #{max_bytes} bytes" if body.bytesize > max_bytes

        return Response.new(
          status: response.code.to_i,
          message: response.message,
          content_type: response["content-type"].to_s.split(";", 2).first.downcase,
          content_length: content_length,
          body:,
          url: current_url
        )
      end
      raise FetchError, "too many HTTP redirects"
    rescue URI::InvalidURIError, SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError => error
      raise FetchError, error.message
    end

    def request_uri(url)
      raw_url = url.to_s
      if raw_url.ascii_only?
        uri = URI.parse(raw_url)
      else
        match = raw_url.match(%r{\A(https?)://([^/?#]+)([^?#]*)(?:\?([^#]*))?(?:#.*)?\z}i)
        raise FetchError, "unsupported URL: #{url}" if match.nil?
        uri = URI.parse("#{match[1]}://#{match[2]}")
        uri.path = URI::DEFAULT_PARSER.escape(match[3], PATH_SAFE)
        uri.query = URI::DEFAULT_PARSER.escape(match[4], QUERY_SAFE) unless match[4].nil?
      end
      raise FetchError, "unsupported URL: #{url}" unless %w[http https].include?(uri.scheme) && uri.host

      uri.path = URI::DEFAULT_PARSER.escape(uri.path.empty? ? "/" : uri.path, PATH_SAFE)
      uri.query = URI::DEFAULT_PARSER.escape(uri.query, QUERY_SAFE) unless uri.query.nil?
      uri
    end
  end
end
