# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "rack/utils"
require "time"

module WeblogAuthoring
  class LambdaSession
    def initialize(secret:, clock: -> { Time.now })
      raise ArgumentError, "session secret must be at least 64 bytes" if secret.bytesize < 64

      @secret = secret
      @clock = clock
    end

    def issue(kind:, attributes:, ttl:)
      payload = Base64.urlsafe_encode64(
        JSON.generate(attributes.merge("kind" => kind, "expires_at" => (@clock.call + ttl).iso8601)),
        padding: false
      )
      "#{payload}.#{signature(payload)}"
    end

    def read(token, kind:)
      payload, supplied_signature = token.to_s.split(".", 2)
      payload = payload.to_s
      return nil unless valid_signature?(payload, supplied_signature)

      attributes = JSON.parse(Base64.urlsafe_decode64(payload))
      return nil unless attributes["kind"] == kind
      return nil unless Time.iso8601(attributes.fetch("expires_at")) > @clock.call

      attributes
    rescue ArgumentError, JSON::ParserError, KeyError
      nil
    end

    private

    def signature(payload)
      OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
    end

    def valid_signature?(payload, supplied)
      payload = payload.to_s
      supplied = supplied.to_s
      return false if payload.empty? || supplied.empty?

      expected = signature(payload)
      supplied.bytesize == expected.bytesize && Rack::Utils.secure_compare(supplied, expected)
    end
  end
end
