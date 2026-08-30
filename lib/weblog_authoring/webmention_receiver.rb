# frozen_string_literal: true

require "base64"
require "digest"
require "ipaddr"
require "json"
require "resolv"
require "securerandom"
require "time"
require "uri"

require_relative "webmention_network_policy"

module WeblogAuthoring
  class WebmentionReceiver
    MAX_BODY_BYTES = 8 * 1024
    MAX_URL_LENGTH = 2_048
    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze

    def initialize(database:, sqs_client:, queue_url:, site_url:, enabled: true,
                   clock: -> { Time.now.utc }, id_generator: -> { SecureRandom.uuid }, resolver: Resolv,
                   logger: $stdout)
      @database = database
      @sqs_client = sqs_client
      @queue_url = queue_url
      @site_uri = URI.parse(site_url)
      @enabled = enabled
      @clock = clock
      @id_generator = id_generator
      @resolver = resolver
      @logger = logger
    end

    def call(event)
      return unavailable_response unless @enabled

      body = request_body(event)
      return error_response(413, "Request body is too large") if body.bytesize > MAX_BODY_BYTES
      return error_response(415, "Content-Type must be application/x-www-form-urlencoded") unless form_request?(event)

      form = URI.decode_www_form(body).to_h
      source = parse_source(form["source"])
      target, route = parse_target(form["target"])
      return error_response(422, "source and target must be different") if comparable_url(source) == comparable_url(target)

      page = @database.find_route(route)
      return error_response(400, "target must be a published article") unless publishable?(page)

      job_id = @id_generator.call
      @sqs_client.send_message(
        queue_url: @queue_url,
        message_body: JSON.generate(
          "type" => "verify",
          "job_id" => job_id,
          "source" => source.to_s,
          "target" => canonical_target(route),
          "target_page_id" => page.id,
          "received_at" => @clock.call.iso8601
        ),
        message_group_id: Digest::SHA256.hexdigest("#{source}\0#{canonical_target(route)}"),
        message_deduplication_id: job_id
      )

      response(202, "status" => "accepted")
    rescue URI::InvalidURIError, ArgumentError => error
      error_response(422, error.message)
    rescue StandardError => error
      @logger.puts(JSON.generate(
        "event" => "webmention_receiver_error", "error_class" => error.class.name
      ))
      unavailable_response
    end

    private

    def request_body(event)
      body = event.fetch("body", "").to_s
      event["isBase64Encoded"] ? Base64.strict_decode64(body) : body
    end

    def form_request?(event)
      headers = event.fetch("headers", {})
      content_type = headers.find { |name, _value| name.downcase == "content-type" }&.last.to_s
      content_type.split(";", 2).first.strip.downcase == "application/x-www-form-urlencoded"
    end

    def parse_source(value)
      uri = parse_http_url(value, "source")
      raise ArgumentError, "source must not contain credentials" if uri.userinfo
      raise ArgumentError, "source must use a public host" unless public_host?(uri.host)

      uri.fragment = nil
      uri
    end

    def parse_target(value)
      uri = parse_http_url(value, "target")
      raise ArgumentError, "target must belong to this site" unless same_origin?(uri, @site_uri)
      raise ArgumentError, "target must not contain a query or fragment" if uri.query || uri.fragment

      path = uri.path.sub(%r{/+\z}, "")
      segments = path.split("/").reject(&:empty?)
      raise ArgumentError, "target must be an individual article" unless segments.length == 1

      route = URI.decode_www_form_component(segments.fetch(0))
      raise ArgumentError, "target must be an individual article" if route.empty? || route.include?("/")

      [uri, route]
    end

    def parse_http_url(value, field)
      raise ArgumentError, "#{field} is required" if value.to_s.empty?
      raise ArgumentError, "#{field} is too long" if value.bytesize > MAX_URL_LENGTH

      uri = URI.parse(value)
      unless %w[http https].include?(uri.scheme&.downcase) && uri.host
        raise ArgumentError, "#{field} must be an absolute HTTP or HTTPS URL"
      end

      uri
    end

    def same_origin?(left, right)
      left.scheme.downcase == right.scheme.downcase &&
        left.host.downcase == right.host.downcase &&
        left.port == right.port
    end

    def public_host?(host)
      return false if host.nil? || host.casecmp("localhost").zero? || host.end_with?(".localhost")

      addresses = @resolver.getaddresses(host)
      !addresses.empty? && addresses.all? do |value|
        WebmentionNetworkPolicy.public_address?(IPAddr.new(value))
      end
    rescue IPAddr::InvalidAddressError, Resolv::ResolvError
      false
    end

    def comparable_url(uri)
      copy = uri.dup
      copy.fragment = nil
      copy.path = "/" if copy.path.empty?
      copy.to_s
    end

    def publishable?(page)
      page && page.status == "published" && !page.empty?
    end

    def canonical_target(route)
      base = @site_uri.to_s.end_with?("/") ? @site_uri.to_s : "#{@site_uri}/"
      URI.join(base, URI::DEFAULT_PARSER.escape(route)).to_s
    end

    def unavailable_response
      response(503, { "error" => "Webmention receiver is temporarily unavailable" }, "retry-after" => "3600")
    end

    def error_response(status, message)
      response(status, "error" => message)
    end

    def response(status, payload, headers = {})
      @logger.puts(JSON.generate(
        "event" => "webmention_receiver_result", "status" => status,
        "result" => status == 202 ? "accepted" : "rejected"
      ))
      { statusCode: status, headers: JSON_HEADERS.merge(headers), body: JSON.generate(payload) }
    end
  end
end
