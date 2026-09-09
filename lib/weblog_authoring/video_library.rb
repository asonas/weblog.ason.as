# frozen_string_literal: true

require "aws-sdk-s3"

module WeblogAuthoring
  class VideoLibrary
    PATH = %r{\A/assets/uploads/\d{4}/\d{2}/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.mp4\z}

    def initialize(database:, s3_client:, bucket:)
      @database = database
      @s3_client = s3_client
      @bucket = bucket
    end

    def register(payload)
      avc = payload["avc"]
      match = PATH.match(avc.to_s)
      raise ArgumentError, "動画のURLが不正です" unless match
      av1 = payload["av1"]
      raise ArgumentError, "AV1のURLが不正です" unless av1.nil? || PATH.match?(av1.to_s)
      width, height = payload.values_at("width", "height")
      raise ArgumentError, "動画の寸法が不正です" unless [width, height].all? { |n| n.is_a?(Integer) && n.between?(1, 1920) }
      name = payload["name"]
      raise ArgumentError, "動画の名前が不正です" unless name.is_a?(String) && name.length.between?(1, 255)
      duration = payload["duration"]
      raise ArgumentError, "動画の長さが不正です" unless duration.nil? || (duration.is_a?(Numeric) && duration.finite? && duration.positive? && duration <= 60.1)
      id = match[1].delete("-")
      existing = @database.list_video_materials.find { |item| item.fetch("id") == id }
      return existing if existing

      bytes = [avc, av1].compact.sum do |path|
        object = @s3_client.head_object(bucket: @bucket, key: path.delete_prefix("/"))
        unless object.content_type == "video/mp4" && object.content_length.between?(1, 50 * 1024 * 1024)
          raise ArgumentError, "アップロード済みのMP4を確認できませんでした"
        end
        object.content_length
      end
      @database.save_video_material(id:, payload: { "avc" => avc, "av1" => av1, "width" => width, "height" => height,
                                                  "name" => name, "duration" => duration, "size" => bytes, })
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      raise ArgumentError, "動画のアップロードが完了していません"
    end
  end
end
