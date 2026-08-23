# frozen_string_literal: true

require "date"
require "time"

module WeblogAuthoring
  class ImageInbox
    KEY_PATTERN = %r{\Aassets/inbox/(\d{4})/(\d{2})/(\d{2})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(gif|jpg|png|webp)\z}
    CONTENT_TYPES = {
      "gif" => "image/gif",
      "jpg" => "image/jpeg",
      "png" => "image/png",
      "webp" => "image/webp",
    }.freeze

    def initialize(s3_client:, bucket:)
      @s3_client = s3_client
      @bucket = bucket
    end

    def list(date:)
      date = parse_date(date)
      prefix = "assets/inbox/#{date.strftime("%Y/%m/%d")}/"
      objects = @s3_client.list_objects_v2(bucket: @bucket, prefix:).contents
      objects.sort_by { |object| object.last_modified || Time.at(0) }.reverse.map do |object|
        {
          "key" => object.key,
          "url" => "/#{object.key}",
          "uploaded_at" => object.last_modified&.iso8601,
        }
      end
    end

    def adopt(key:)
      match = KEY_PATTERN.match(key.to_s)
      raise ArgumentError, "写真インボックスのキーが不正です" if match.nil?

      destination = "assets/uploads/#{match[1]}/#{match[2]}/#{match[4]}.#{match[5]}"
      @s3_client.copy_object(
        bucket: @bucket,
        copy_source: "#{@bucket}/#{key}",
        key: destination,
        content_type: CONTENT_TYPES.fetch(match[5]),
        cache_control: ImageUpload::CACHE_CONTROL,
        metadata_directive: "REPLACE"
      )
      @s3_client.delete_object(bucket: @bucket, key:)
      { "public_url" => "/#{destination}" }
    end

    private

    def parse_date(value)
      date = Date.iso8601(value.to_s)
      raise ArgumentError, "写真の日付が不正です" unless date.iso8601 == value

      date
    rescue Date::Error
      raise ArgumentError, "写真の日付が不正です"
    end
  end
end
