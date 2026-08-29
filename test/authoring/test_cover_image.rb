# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/cover_image"
require "weblog_authoring/models"

class CoverImageTest < Minitest::Test
  def test_auto_uses_the_first_local_image_in_document_order
    page = page_document(<<~MARKDOWN)
      ![external](https://example.com/external.jpg)
      [https://legacy.example/first.jpg legacy]
      ![local](/assets/uploads/second.jpg)
    MARKDOWN

    assert_equal "/assets/legacy/first.jpg", WeblogAuthoring::CoverImage.resolve(
      page,
      asset_image_paths: { "https://legacy.example/first.jpg" => "legacy/first.jpg" }
    )
  end

  def test_none_is_blank_and_explicit_does_not_depend_on_body
    none = page_document("![body](/assets/body.jpg)", cover_mode: "none")
    explicit = page_document("本文", cover_mode: "explicit", cover_image_url: "/assets/chosen.jpg")

    assert_nil WeblogAuthoring::CoverImage.resolve(none)
    assert_equal "/assets/chosen.jpg", WeblogAuthoring::CoverImage.resolve(explicit)
  end

  private

  def page_document(body, cover_mode: "auto", cover_image_url: nil)
    WeblogAuthoring::PageDocument.new(body:, links: [], cover_mode:, cover_image_url:)
  end
end
