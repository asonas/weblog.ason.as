# frozen_string_literal: true

module WeblogAuthoring
  class InboxThumbnail
    MAX_DIMENSION = 512
    CACHE_CONTROL = "private, max-age=604800"

    def initialize(s3_client:, bucket:, image_class: nil)
      @s3_client = s3_client
      @bucket = bucket
      @image_class = image_class
    end

    def create(key:)
      match = ImageInbox::KEY_PATTERN.match(key.to_s)
      raise ArgumentError, "写真インボックスのキーが不正です" if match.nil?

      source = @s3_client.get_object(bucket: @bucket, key:).body.read
      image = image_class.thumbnail_buffer(
        source, MAX_DIMENSION, height: MAX_DIMENSION, size: :down
      )
      body = image.write_to_buffer(".webp", Q: 75, strip: true)
      thumbnail_key = "assets/inbox/thumbnails/#{match[1]}/#{match[2]}/#{match[3]}/#{match[4]}.webp"
      @s3_client.put_object(
        bucket: @bucket,
        key: thumbnail_key,
        body:,
        content_type: "image/webp",
        cache_control: CACHE_CONTROL
      )
      thumbnail_key
    end

    private

    def image_class
      return @image_class unless @image_class.nil?

      require "vips"
      Vips::Image
    end
  end
end
