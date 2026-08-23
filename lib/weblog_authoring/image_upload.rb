# frozen_string_literal: true

require "aws-sdk-s3"
require "date"
require "securerandom"

module WeblogAuthoring
  class ImageUpload
    MAX_BYTES = 25 * 1024 * 1024
    CACHE_CONTROL = "public, max-age=31536000, immutable"
    INBOX_CACHE_CONTROL = "public, max-age=300"
    CONTENT_TYPES = {
      "image/gif" => "gif",
      "image/jpeg" => "jpg",
      "image/png" => "png",
      "image/webp" => "webp",
    }.freeze

    def initialize(s3_client:, bucket:, clock: Time.method(:now), random: SecureRandom.method(:uuid))
      @s3_client = s3_client
      @bucket = bucket
      @clock = clock
      @random = random
    end

    def create(content_type:, size:, inbox_date: nil)
      extension = CONTENT_TYPES[content_type]
      raise ArgumentError, "対応していない画像形式です" if extension.nil?
      raise ArgumentError, "画像サイズが不正です" unless size.is_a?(Integer) && size.positive?
      raise ArgumentError, "画像は25MB以下にしてください" if size > MAX_BYTES

      now = @clock.call
      prefix = inbox_date.nil? ? "uploads/#{now.strftime("%Y/%m")}" : inbox_prefix(inbox_date)
      key = "assets/#{prefix}/#{@random.call}.#{extension}"
      cache_control = inbox_date.nil? ? CACHE_CONTROL : INBOX_CACHE_CONTROL
      post = Aws::S3::PresignedPost.new(
        @s3_client.config.credentials,
        @s3_client.config.region,
        @bucket,
        key:,
        content_type:,
        content_length_range: 1..MAX_BYTES,
        cache_control:,
        success_action_status: "204",
        signature_expiration: now + 300
      )

      {
        "upload_url" => post.url,
        "fields" => post.fields,
        "public_url" => "/#{key}",
      }
    end

    private

    def inbox_prefix(value)
      date = Date.iso8601(value.to_s)
      raise ArgumentError, "写真の日付が不正です" unless date.iso8601 == value

      "inbox/#{date.strftime("%Y/%m/%d")}"
    rescue Date::Error
      raise ArgumentError, "写真の日付が不正です"
    end
  end
end
