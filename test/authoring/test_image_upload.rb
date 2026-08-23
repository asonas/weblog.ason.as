# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/image_upload"

class ImageUploadTest < Minitest::Test
  def setup
    @s3 = Aws::S3::Client.new(
      region: "ap-northeast-1",
      credentials: Aws::Credentials.new("access-key", "secret-key"),
      stub_responses: true
    )
    @upload = WeblogAuthoring::ImageUpload.new(
      s3_client: @s3,
      bucket: "images.example",
      clock: -> { Time.iso8601("2026-08-24T12:00:00+09:00") },
      random: -> { "11111111-2222-3333-4444-555555555555" }
    )
  end

  def test_creates_a_short_lived_presigned_post_for_an_image
    result = @upload.create(content_type: "image/webp", size: 1024)

    assert_match(%r{\Ahttps://s3\.ap-northeast-1\.amazonaws\.com/images\.example\z}, result.fetch("upload_url"))
    assert_equal "/assets/uploads/2026/08/11111111-2222-3333-4444-555555555555.webp",
                 result.fetch("public_url")
    assert_equal "assets/uploads/2026/08/11111111-2222-3333-4444-555555555555.webp",
                 result.dig("fields", "key")
    assert_equal "image/webp", result.dig("fields", "Content-Type")
    assert_equal WeblogAuthoring::ImageUpload::CACHE_CONTROL, result.dig("fields", "Cache-Control")
  end

  def test_rejects_unsupported_or_oversized_files
    assert_raises(ArgumentError) { @upload.create(content_type: "image/svg+xml", size: 100) }
    assert_raises(ArgumentError) do
      @upload.create(content_type: "image/png", size: WeblogAuthoring::ImageUpload::MAX_BYTES + 1)
    end
  end

  def test_creates_an_inbox_upload_for_the_selected_date
    result = @upload.create(content_type: "image/webp", size: 1024, inbox_date: "2026-08-23")

    assert_equal "assets/inbox/2026/08/23/11111111-2222-3333-4444-555555555555.webp",
                 result.dig("fields", "key")
    assert_equal "/assets/inbox/2026/08/23/11111111-2222-3333-4444-555555555555.webp",
                 result.fetch("public_url")
    assert_equal WeblogAuthoring::ImageUpload::INBOX_CACHE_CONTROL, result.dig("fields", "Cache-Control")
  end

  def test_rejects_an_invalid_inbox_date
    assert_raises(ArgumentError) do
      @upload.create(content_type: "image/webp", size: 1024, inbox_date: "2026-02-30")
    end
  end
end
