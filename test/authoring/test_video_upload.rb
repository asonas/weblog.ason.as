# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/video_upload"

class VideoUploadTest < Minitest::Test
  def test_limits_signed_uploads_to_mp4_under_50mb
    s3 = Aws::S3::Client.new(region: "ap-northeast-1", credentials: Aws::Credentials.new("test", "test"), stub_responses: true)
    upload = WeblogAuthoring::VideoUpload.new(s3_client: s3, bucket: "assets", clock: -> { Time.utc(2026, 9, 8) })
    result = upload.create(size: 10_000_000)
    assert_match(%r{\A/assets/uploads/2026/09/[a-f0-9-]+\.mp4\z}, result.fetch("public_url"))
    assert_equal "video/mp4", result.dig("fields", "Content-Type")
    policy = JSON.parse(Base64.decode64(result.dig("fields", "policy")))
    assert_includes policy.fetch("conditions"), ["content-length-range", 1, 50 * 1024 * 1024]
    [0, -1, (50 * 1024 * 1024) + 1, "1000"].each do |size|
      assert_raises(ArgumentError) { upload.create(size:) }
    end
  end
end
