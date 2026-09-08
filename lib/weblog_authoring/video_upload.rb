# frozen_string_literal: true

require "aws-sdk-s3"
require "securerandom"

module WeblogAuthoring
  class VideoUpload
    MAX_BYTES = 50 * 1024 * 1024

    def initialize(s3_client:, bucket:, clock: Time.method(:now))
      @s3_client = s3_client
      @bucket = bucket
      @clock = clock
    end

    def create(size:)
      raise ArgumentError, "動画は50MB以下のMP4に変換してください" unless size.is_a?(Integer) && size.positive? && size <= MAX_BYTES

      now = @clock.call
      key = "assets/uploads/#{now.strftime("%Y/%m")}/#{SecureRandom.uuid}.mp4"
      post = Aws::S3::PresignedPost.new(
        @s3_client.config.credentials, @s3_client.config.region, @bucket,
        key:, content_type: "video/mp4", content_length_range: 1..MAX_BYTES,
        cache_control: "public, max-age=31536000, immutable",
        success_action_status: "204", signature_expiration: now + 300
      )
      { "upload_url" => post.url, "fields" => post.fields, "public_url" => "/#{key}" }
    end
  end
end
