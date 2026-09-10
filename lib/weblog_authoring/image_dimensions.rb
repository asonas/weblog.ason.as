# frozen_string_literal: true

require "aws-sdk-s3"

module WeblogAuthoring
  class ImageDimensions
    def self.validate(width, height)
      return if width.nil? && height.nil?
      unless [width, height].all? { |value| value.is_a?(Integer) && value.between?(1, 99_999) }
        raise ArgumentError, "画像の幅と高さが不正です"
      end
      [width, height]
    end

    def initialize(database:, s3_client:, bucket:)
      @database = database
      @s3_client = s3_client
      @bucket = bucket
    end

    def backfill(src)
      return unless src.start_with?("/assets/")
      cached = @database.find_image_dimensions(src)
      return cached if cached

      require "vips"
      begin
        source = @s3_client.get_object(bucket: @bucket, key: src.delete_prefix("/")).body.read
        image = Vips::Image.new_from_buffer(source, "").autorot
        dimensions = [image.width, image.height]
        @database.save_image_dimensions(src, width: image.width, height: image.height)
        dimensions
      rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey, Vips::Error => error
        warn "Image dimensions unavailable: #{src}: #{error.class}"
        nil
      end
    end
  end
end
