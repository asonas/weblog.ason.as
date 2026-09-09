# frozen_string_literal: true

require "aws-sdk-s3"

module WeblogAuthoring
  class CoverVariants
    WIDTHS = [640, 1280].freeze

    def initialize(s3_client:, bucket:)
      @s3_client = s3_client
      @bucket = bucket
    end

    def create(url)
      return unless url&.start_with?("/assets/")

      require "vips"
      source = nil
      WIDTHS.each do |width|
        key = "assets/previews/#{width}/#{url.delete_prefix('/assets/')}.webp"
        begin
          @s3_client.head_object(bucket: @bucket, key:)
          next
        rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey,
               Aws::S3::Errors::Forbidden, Aws::S3::Errors::AccessDenied
          # S3 returns 403 for missing keys when the publisher cannot list the bucket.
          source ||= @s3_client.get_object(bucket: @bucket, key: url.delete_prefix("/")).body.read
        end
        image = Vips::Image.thumbnail_buffer(source, width, size: :down)
        @s3_client.put_object(
          bucket: @bucket, key:, body: image.write_to_buffer(".webp", Q: 75, strip: true),
          content_type: "image/webp", cache_control: "public, max-age=31536000, immutable"
        )
      end
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey, Vips::Error => error
      warn "Cover preview unavailable: #{url}: #{error.class}"
    end
  end
end
