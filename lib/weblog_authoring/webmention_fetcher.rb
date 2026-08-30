# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"
require "stringio"
require "time"
require "uri"
require "zlib"

require_relative "webmention_network_policy"

module WeblogAuthoring
  class WebmentionFetcher
    class FetchError < StandardError
      attr_reader :result

      def initialize(message, result: "temporary_failure")
        super(message)
        @result = result
      end
    end

    Response = Data.define(:url, :status, :content_type, :link_header, :body, :redirect_count, :duration_ms)
    MAX_REDIRECTS = 5
    MAX_BYTES = 2 * 1024 * 1024
    CONNECT_TIMEOUT = 3
    TOTAL_TIMEOUT = 10
    HTML_CONTENT_TYPES = ["text/html", "application/xhtml+xml"].freeze

    def initialize(resolver: Resolv, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @resolver = resolver
      @clock = clock
    end

    def fetch(url)
      started_at = @clock.call
      deadline = started_at + TOTAL_TIMEOUT
      uri = URI.parse(url)
      redirects = 0

      loop do
        validate_uri!(uri)
        address = public_addresses(uri.host).first
        raise FetchError, "source host did not resolve" unless address

        response, body = request(uri, address, deadline)
        if response.is_a?(Net::HTTPRedirection) && response["location"]
          raise FetchError.new("source redirected too many times", result: "invalid_source") if redirects >= MAX_REDIRECTS

          uri = URI.join(uri, response["location"])
          redirects += 1
          next
        end

        body = decode_body(response, body) if response.is_a?(Net::HTTPSuccess)
        content_type = response["content-type"].to_s.split(";", 2).first.downcase
        if response.is_a?(Net::HTTPSuccess) && !HTML_CONTENT_TYPES.include?(content_type)
          raise FetchError.new("source is not HTML", result: "invalid_source")
        end

        return Response.new(
          url: uri.to_s, status: response.code.to_i, content_type:,
          link_header: response["link"], body:,
          redirect_count: redirects, duration_ms: ((@clock.call - started_at) * 1000).round
        )
      end
    rescue URI::InvalidURIError => error
      raise FetchError.new(error.message, result: "invalid_source")
    rescue Timeout::Error, SystemCallError => error
      raise FetchError, error.message
    end

    def post_form(url, form)
      started_at = @clock.call
      deadline = started_at + TOTAL_TIMEOUT
      uri = URI.parse(url)
      validate_uri!(uri)
      address = public_addresses(uri.host).first
      raise FetchError, "Webmention endpoint did not resolve" unless address

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Accept-Encoding"] = "identity"
      request.set_form_data(form)
      response, = request(uri, address, deadline, request:)
      response.code.to_i
    rescue URI::InvalidURIError => error
      raise FetchError.new(error.message, result: "invalid_source")
    rescue Timeout::Error, SystemCallError => error
      raise FetchError, error.message
    end

    private

    def validate_uri!(uri)
      unless %w[http https].include?(uri.scheme&.downcase) && uri.host
        raise FetchError.new("source must be an absolute HTTP or HTTPS URL", result: "invalid_source")
      end
      raise FetchError.new("source must not contain credentials", result: "invalid_source") if uri.userinfo
    end

    def public_addresses(host)
      @resolver.getaddresses(host).filter_map do |value|
        address = IPAddr.new(value)
        address.to_s if WebmentionNetworkPolicy.public_address?(address)
      rescue IPAddr::InvalidAddressError
        nil
      end.tap do |addresses|
        raise FetchError.new("source resolved to a non-public address", result: "blocked_source") if addresses.empty?
      end
    end

    def request(uri, address, deadline, request: nil)
      remaining = deadline - @clock.call
      raise FetchError, "source fetch timed out" unless remaining.positive?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme.casecmp("https").zero?
      http.ipaddr = address
      http.open_timeout = [CONNECT_TIMEOUT, remaining].min
      http.read_timeout = remaining
      request ||= Net::HTTP::Get.new(uri.request_uri).tap do |get|
        get["Accept"] = "text/html, application/xhtml+xml"
        get["Accept-Encoding"] = "identity"
      end

      body = +""
      response = http.start do |client|
        client.request(request) do |incoming|
          incoming.read_body do |chunk|
            body << chunk
            raise FetchError.new("source response is too large", result: "invalid_source") if body.bytesize > MAX_BYTES
            raise FetchError, "source fetch timed out" if @clock.call >= deadline
          end
        end
      end
      [response, body]
    end

    def decode_body(response, body)
      encoding = response["content-encoding"].to_s.strip.downcase
      return body if encoding.empty? || encoding == "identity"

      reader = case encoding
               when "gzip" then Zlib::GzipReader.new(StringIO.new(body))
               else
                 raise FetchError.new("unsupported source content encoding", result: "invalid_source")
               end
      decoded = +""
      until reader.eof?
        decoded << reader.read(16 * 1024)
        raise FetchError.new("source response is too large", result: "invalid_source") if decoded.bytesize > MAX_BYTES
      end
      decoded
    rescue Zlib::Error => error
      raise FetchError.new("invalid compressed source response: #{error.message}", result: "invalid_source")
    ensure
      reader&.close
    end
  end
end
