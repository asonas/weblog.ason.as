# frozen_string_literal: true

require "time"

require_relative "image_upload"
require_relative "models"

module WeblogAuthoring
  class ImageInbox
    KEY_PATTERN = %r{\Aassets/inbox/(\d{4})/(\d{2})/(\d{2})/([0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(gif|jpg|png|webp)\z}
    CONTENT_TYPES = {
      "gif" => "image/gif",
      "jpg" => "image/jpeg",
      "png" => "image/png",
      "webp" => "image/webp",
    }.freeze

    def initialize(s3_client:, bucket:, database:)
      @s3_client = s3_client
      @bucket = bucket
      @database = database
    end

    def prepare(item_id:)
      item = @database.find_inbox_item(item_id)
      raise ConflictError, "inbox_item_expired" unless item&.source == "photo" && item.kind == "photo"

      key = item.payload.fetch("inbox_key")
      match = KEY_PATTERN.match(key.to_s)
      raise ArgumentError, "写真インボックスのキーが不正です" if match.nil?

      destination = "assets/uploads/#{match[1]}/#{match[2]}/#{match[4]}.#{match[5]}"
      adoption = @database.prepare_inbox_image_adoption(
        item_id: item.id,
        inbox_key: key,
        public_key: destination
      )
      @s3_client.copy_object(
        bucket: @bucket,
        copy_source: "#{@bucket}/#{adoption.inbox_key}",
        key: adoption.public_key,
        content_type: CONTENT_TYPES.fetch(match[5]),
        cache_control: ImageUpload::CACHE_CONTROL,
        metadata_directive: "REPLACE",
        tagging: "weblog-inbox-adoption=pending",
        tagging_directive: "REPLACE"
      )
      { "public_url" => "/#{adoption.public_key}" }
    end

    def finalize(limit: 100)
      @database.list_pending_inbox_image_finalizations(limit:).each do |adoption|
        @s3_client.put_object_tagging(
          bucket: @bucket,
          key: adoption.public_key,
          tagging: { tag_set: [] }
        )
        @s3_client.delete_object(bucket: @bucket, key: adoption.inbox_key)
        @database.complete_inbox_image_adoption(item_id: adoption.item_id)
      end.length
    end
  end
end
