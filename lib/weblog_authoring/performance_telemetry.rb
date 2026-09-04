# frozen_string_literal: true

require "base64"
require "json"
require "rack/utils"
require "time"

module WeblogAuthoring
  class PerformanceTelemetry
    MAX_BODY_BYTES = 64 * 1024
    MAX_METRICS = 24
    MAX_SPANS = 8
    ALLOWED_ATTRIBUTE_KEYS = %w[
      deployment.environment.name
      browser.time_origin_unix_ms
      navigation.type
      page.body_length_bucket
      page.external_link_count_bucket
      page.image_count_bucket
      page.wiki_link_count_bucket
      service.name
      service.version
      session.discarded
    ].freeze
    ALLOWED_METRIC_NAMES = %w[
      authoring.dom.nodes
      authoring.documents
      authoring.frames
      authoring.interaction.duration
      authoring.js_heap.bytes
      authoring.long_task.duration
      authoring.requests.embed.duration
      authoring.requests.embed.total
      authoring.requests.save.duration
      authoring.requests.save.total
      authoring.session_storage.duration
    ].freeze
    ALLOWED_SPAN_NAMES = %w[authoring.session.restore].freeze
    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze

    def self.validate_payload!(payload)
      allocate.send(:validate_payload!, payload)
    end

    def initialize(session_codec:, allowed_github_user_id:, logger: $stdout, clock: Time.method(:now))
      @session_codec = session_codec
      @allowed_github_user_id = allowed_github_user_id
      @logger = logger
      @clock = clock
    end

    def call(event)
      return response(404, error: "Not Found") unless post_request?(event)
      return response(413, error: "Telemetry payload is too large") if decoded_body(event).bytesize > MAX_BODY_BYTES

      session = session_from(event)
      return response(401, error: "Authentication required") unless allowed_session?(session)
      return response(403, error: "CSRF token mismatch") unless secure_equal?(session.fetch("csrf_token", ""), csrf_token(event))

      payload = JSON.parse(decoded_body(event))
      validate_payload!(payload)
      restore_max_ms = payload.fetch("spans", []).filter_map do |span|
        span["duration_ms"] if span["name"] == "authoring.session.restore"
      end.max
      @logger.puts(JSON.generate(
        "event" => "authoring_performance_telemetry",
        "received_at" => @clock.call.iso8601(6),
        "restore_max_ms" => restore_max_ms,
        "payload" => payload,
      ))
      response(202, status: "accepted")
    rescue JSON::ParserError
      response(422, error: "Telemetry payload must be valid JSON")
    rescue ArgumentError => error
      response(422, error: error.message)
    end

    private

    def post_request?(event)
      event.dig("requestContext", "http", "method") == "POST" && event["rawPath"] == "/api/authoring/telemetry"
    end

    def validate_payload!(payload)
      raise ArgumentError, "Telemetry payload must be an object" unless payload.is_a?(Hash)
      raise ArgumentError, "Unsupported telemetry schema" unless payload["schema_version"] == "1.0"

      attributes = payload.fetch("resource", {}).fetch("attributes", {})
      validate_attributes!(attributes)
      metrics = payload.fetch("metrics", [])
      spans = payload.fetch("spans", [])
      raise ArgumentError, "Too many metrics" unless metrics.is_a?(Array) && metrics.length <= MAX_METRICS
      raise ArgumentError, "Too many spans" unless spans.is_a?(Array) && spans.length <= MAX_SPANS

      metrics.each { |metric| validate_metric!(metric) }
      spans.each { |span| validate_span!(span) }
    end

    def validate_attributes!(attributes)
      raise ArgumentError, "Telemetry attributes must be an object" unless attributes.is_a?(Hash)
      raise ArgumentError, "Unsupported telemetry attribute" unless (attributes.keys - ALLOWED_ATTRIBUTE_KEYS).empty?
      valid_values = attributes.values.all? do |value|
        value.is_a?(String) || value == true || value == false || (value.is_a?(Numeric) && value.finite?)
      end
      raise ArgumentError, "Telemetry attribute value is invalid" unless valid_values
      raise ArgumentError, "Telemetry attribute value is too long" if attributes.values.any? { |value| value.is_a?(String) && value.bytesize > 64 }
    end

    def validate_metric!(metric)
      raise ArgumentError, "Telemetry metric must be an object" unless metric.is_a?(Hash)
      raise ArgumentError, "Unsupported telemetry metric" unless ALLOWED_METRIC_NAMES.include?(metric["name"])
      allowed_keys = %w[name unit count sum min max explicit_bounds bucket_counts value]
      raise ArgumentError, "Unsupported telemetry metric field" unless (metric.keys - allowed_keys).empty?
      numeric_values = metric.values_at("count", "sum", "min", "max", "value").compact
      raise ArgumentError, "Telemetry metric value is invalid" unless numeric_values.all? { |value| value.is_a?(Numeric) && value.finite? }
      bounds = metric.fetch("explicit_bounds", [])
      counts = metric.fetch("bucket_counts", [])
      raise ArgumentError, "Telemetry histogram is invalid" unless bounds.is_a?(Array) && counts.is_a?(Array) && bounds.length <= 16 && counts.length <= 17
      raise ArgumentError, "Telemetry histogram value is invalid" unless (bounds + counts).all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 }
    end

    def validate_span!(span)
      raise ArgumentError, "Telemetry span must be an object" unless span.is_a?(Hash)
      raise ArgumentError, "Unsupported telemetry span" unless ALLOWED_SPAN_NAMES.include?(span["name"])
      raise ArgumentError, "Unsupported telemetry span field" unless (span.keys - %w[name duration_ms attributes]).empty?
      duration = span["duration_ms"]
      raise ArgumentError, "Telemetry span duration is invalid" unless duration.is_a?(Numeric) && duration.finite? && duration >= 0
      validate_attributes!(span.fetch("attributes", {}))
    end

    def session_from(event)
      raw = Array(event["cookies"]).find { |cookie| cookie.start_with?("weblog_authoring_session=") }
      @session_codec.read(raw.to_s.delete_prefix("weblog_authoring_session="), kind: "session")
    end

    def allowed_session?(session)
      session && Integer(session.fetch("github_user_id")) == @allowed_github_user_id
    rescue ArgumentError, KeyError, TypeError
      false
    end

    def csrf_token(event)
      event.fetch("headers", {}).fetch("x-csrf-token", "")
    end

    def decoded_body(event)
      body = event.fetch("body", "").to_s
      event["isBase64Encoded"] ? Base64.decode64(body) : body
    end

    def secure_equal?(expected, supplied)
      expected = expected.to_s
      supplied = supplied.to_s
      !expected.empty? && expected.bytesize == supplied.bytesize && Rack::Utils.secure_compare(expected, supplied)
    end

    def response(status, payload)
      { statusCode: status, headers: JSON_HEADERS, body: JSON.generate(payload) }
    end
  end
end
