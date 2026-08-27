# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"
require "time"
require "aws-sdk-s3"
require "rack/utils"

module WeblogAuthoring
  class MobileUpload
    class PairingUnavailable < StandardError; end
    class PairingAttemptsExceeded < StandardError; end
    class UnsupportedContentType < ArgumentError; end

    PAIRING_TTL = 10 * 60
    SIGNATURE_TTL = 5 * 60
    MAX_BYTES = 25 * 1024 * 1024
    BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    CONTENT_TYPES = {
      "image/gif" => "gif",
      "image/jpeg" => "jpg",
      "image/png" => "png",
      "image/webp" => "webp",
    }.freeze
    CAPTURE_SOURCES = %w[photos exif uploaded].freeze

    def initialize(database:, s3_client: nil, bucket: nil, clock: Time.method(:now),
                   random_bytes: SecureRandom.method(:random_bytes), random_uuid: -> { SecureRandom.uuid.delete("-") })
      @database = database
      @s3_client = s3_client
      @bucket = bucket
      @clock = clock
      @random_bytes = random_bytes
      @random_uuid = random_uuid
    end

    def issue_pairing
      code = Array.new(12) { BASE32_ALPHABET.getbyte(random_byte % BASE32_ALPHABET.bytesize).chr }.join
      expires_at = now + PAIRING_TTL
      @database.create_mobile_pairing(code_digest: digest(code), expires_at:)
      { "code" => code, "expires_at" => expires_at.iso8601 }
    end

    def exchange_pairing(code:, device_name:)
      token = Base64.urlsafe_encode64(@random_bytes.call(32), padding: false)
      device = @database.exchange_mobile_pairing(
        code_digest: digest(code.to_s.upcase),
        device_name: device_name,
        token_digest: digest(token)
      )
      raise PairingAttemptsExceeded if device == :too_many_attempts
      raise PairingUnavailable if device.nil?

      { "token" => token, "device" => device }
    end

    def revoke_device(device_id:)
      @database.revoke_mobile_device(device_id)
    end

    def devices
      @database.active_mobile_devices.map { |device| device.reject { |key, _value| key == "token_digest" } }
    end

    def create_upload(token:, payload:)
      device = authenticate(token)
      return nil if device.nil?

      attributes = upload_attributes(payload)
      upload, created = @database.create_mobile_upload(
        device_id: device.fetch("id"),
        upload_id: @random_uuid.call,
        s3_key: inbox_key(attributes.fetch(:captured_at), attributes.fetch(:content_type)),
        **attributes
      )
      @database.touch_mobile_device(device.fetch("id"))
      [signed_upload(upload), created]
    end

    def complete_upload(token:, upload_id:)
      device = authenticate(token)
      return nil if device.nil?

      upload = @database.find_mobile_upload(upload_id:, device_id: device.fetch("id"))
      raise ConflictError, "upload_not_found" if upload.nil?

      if upload.fetch("state") == "completed"
        item = @database.find_inbox_item_by_source(source: "photo", kind: "photo", source_id: upload_id)
        return [item, false]
      end

      object = @s3_client.head_object(bucket: @bucket, key: upload.fetch("s3_key"))
      matches = object.content_type == upload.fetch("content_type") &&
                object.content_length == upload.fetch("size") &&
                object.metadata.fetch("sha256", nil) == upload.fetch("sha256")
      raise ConflictError, "s3_upload_incomplete" unless matches

      @database.complete_mobile_upload(upload_id:, device_id: device.fetch("id"))
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      raise ConflictError, "s3_upload_incomplete"
    end

    private

    def random_byte
      @random_bytes.call(1).unpack1("C")
    end

    def digest(value)
      Digest::SHA256.hexdigest(value)
    end

    def authenticate(token)
      candidate = digest(token.to_s)
      @database.active_mobile_devices.find do |device|
        Rack::Utils.secure_compare(device.fetch("token_digest"), candidate)
      end
    end

    def upload_attributes(payload)
      client_upload_id = payload["client_upload_id"].to_s
      raise ArgumentError, "client_upload_id is invalid" unless /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.match?(client_upload_id)

      content_type = payload["content_type"].to_s
      raise UnsupportedContentType, "unsupported content type" unless CONTENT_TYPES.key?(content_type)

      size = payload["size"]
      raise ArgumentError, "size is invalid" unless size.is_a?(Integer) && size.between?(1, MAX_BYTES)

      sha256 = payload["sha256"].to_s.downcase
      raise ArgumentError, "sha256 is invalid" unless /\A[0-9a-f]{64}\z/.match?(sha256)

      source = payload["captured_at_source"].to_s
      raise ArgumentError, "captured_at_source is invalid" unless CAPTURE_SOURCES.include?(source)

      captured_at = begin
        Time.iso8601(payload["captured_at"].to_s)
      rescue ArgumentError
        nil
      end
      if captured_at.nil? || captured_at >= now + (24 * 60 * 60)
        captured_at = nil
        source = "uploaded"
      end
      {
        client_upload_id:,
        content_type:,
        size:,
        sha256:,
        captured_at:,
        captured_at_source: source,
      }
    end

    def inbox_key(captured_at, content_type)
      date = (captured_at || now).getlocal("+09:00")
      "assets/inbox/#{date.strftime("%Y/%m/%d")}/#{@random_uuid.call}.#{CONTENT_TYPES.fetch(content_type)}"
    end

    def signed_upload(upload)
      expires_at = now + SIGNATURE_TTL
      expires_at_iso8601 = expires_at.iso8601
      post = Aws::S3::PresignedPost.new(
        @s3_client.config.credentials,
        @s3_client.config.region,
        @bucket,
        key: upload.fetch("s3_key"),
        content_type: upload.fetch("content_type"),
        content_length_range: 1..MAX_BYTES,
        metadata: { "sha256" => upload.fetch("sha256") },
        success_action_status: "204",
        signature_expiration: expires_at
      )
      {
        "upload_id" => upload.fetch("id"),
        "upload_url" => post.url,
        "fields" => post.fields,
        "expires_at" => expires_at_iso8601,
      }
    end

    def now
      @clock.call.dup
    end
  end
end
