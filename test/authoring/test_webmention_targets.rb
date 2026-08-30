# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_targets"

class WebmentionTargetsTest < Minitest::Test
  def test_extracts_unique_external_links_rendered_as_public_anchors
    targets = WeblogAuthoring::WebmentionTargets.new(site_url: "https://weblog.ason.as").extract(
      <<~MARKDOWN,
        [external](https://example.com/post#section)
        <https://example.com/post>
        [internal](https://weblog.ason.as/other)
        ![image](https://images.example/image.jpg)
        <iframe src="https://video.example/embed"></iframe>
      MARKDOWN
      source_url: "https://weblog.ason.as/article"
    )

    assert_equal ["https://example.com/post"], targets
  end
end
