# frozen_string_literal: true

require_relative "../test_helper"
require "vips"
require "weblog_authoring/cover_variants"

class CoverVariantsTest < Minitest::Test
  def test_generates_bounded_webp_covers_and_reuses_existing_outputs
    source = Vips::Image.black(1600, 800, bands: 3).write_to_buffer(".png")
    objects = { "assets/example.png" => source }
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:head_object, lambda { |context|
      objects.key?(context.params[:key]) ? {} : "Forbidden"
    })
    s3.stub_responses(:get_object, lambda { |context| { body: objects.fetch(context.params[:key]) } })
    s3.stub_responses(:put_object, lambda { |context|
      objects[context.params[:key]] = context.params[:body]
      {}
    })
    variants = WeblogAuthoring::CoverVariants.new(s3_client: s3, bucket: "site")

    2.times { variants.create("/assets/example.png") }

    small = Vips::Image.new_from_buffer(objects.fetch("assets/previews/640/example.png.webp"), "")
    large = Vips::Image.new_from_buffer(objects.fetch("assets/previews/1280/example.png.webp"), "")
    assert_equal [640, 320], [small.width, small.height]
    assert_equal [1280, 640], [large.width, large.height]
    assert_equal source, objects.fetch("assets/example.png")
    assert_equal 2, (s3.api_requests.count { |request| request[:operation_name] == :put_object })
  end
end
