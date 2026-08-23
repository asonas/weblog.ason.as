# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/image_upload"
require_relative "../../lib/weblog_authoring/image_inbox"

class ImageInboxTest < Minitest::Test
  def setup
    @s3 = Aws::S3::Client.new(region: "ap-northeast-1", stub_responses: true)
    @inbox = WeblogAuthoring::ImageInbox.new(s3_client: @s3, bucket: "images.example")
  end

  def test_lists_images_for_one_date
    @s3.stub_responses(:list_objects_v2, contents: [{
      key: "assets/inbox/2026/08/23/image.webp",
      last_modified: Time.iso8601("2026-08-23T12:00:00Z"),
    }])

    assert_equal [{
      "key" => "assets/inbox/2026/08/23/image.webp",
      "url" => "/assets/inbox/2026/08/23/image.webp",
      "uploaded_at" => "2026-08-23T12:00:00Z",
    }], @inbox.list(date: "2026-08-23")
  end

  def test_adopts_an_inbox_image_without_downloading_it
    key = "assets/inbox/2026/08/23/11111111-2222-3333-4444-555555555555.webp"

    result = @inbox.adopt(key:)

    assert_equal "/assets/uploads/2026/08/11111111-2222-3333-4444-555555555555.webp",
                 result.fetch("public_url")
    assert_equal "images.example/#{key}", @s3.api_requests[0].fetch(:params).fetch(:copy_source)
    assert_equal key, @s3.api_requests[1].fetch(:params).fetch(:key)
  end

  def test_rejects_a_key_outside_the_inbox
    assert_raises(ArgumentError) { @inbox.adopt(key: "assets/uploads/2026/08/image.webp") }
  end
end
