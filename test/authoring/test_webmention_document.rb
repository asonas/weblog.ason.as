# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_document"

class WebmentionDocumentTest < Minitest::Test
  def test_extracts_metadata_and_matches_a_resolved_target_link
    document = WeblogAuthoring::WebmentionDocument.new(
      <<~HTML,
        <html><head>
          <title>An &amp; Article</title>
          <meta content="Example Site" property="og:site_name">
        </head><body><a href='/target#reply'>Target</a></body></html>
      HTML
      base_url: "https://example.com/post"
    )

    assert document.links_to?("https://example.com/target")
    assert_equal "An & Article", document.title
    assert_equal "Example Site", document.site_name
    assert_equal 64, document.content_hash.length
  end

  def test_does_not_match_text_or_non_anchor_urls
    document = WeblogAuthoring::WebmentionDocument.new(
      '<html><body>https://example.com/target<img src="https://example.com/target"></body></html>',
      base_url: "https://example.com/post"
    )

    refute document.links_to?("https://example.com/target")
  end

  def test_resolves_relative_links_against_the_html_base_element
    document = WeblogAuthoring::WebmentionDocument.new(
      '<base href="https://example.com/base/"><a href="target">Target</a>',
      base_url: "https://example.com/post"
    )

    assert document.links_to?("https://example.com/base/target")
  end

  def test_matches_canonical_url_variants
    document = WeblogAuthoring::WebmentionDocument.new(
      '<a href="HTTPS://WEBLOG.ASON.AS:443/article/#reply">Target</a>',
      base_url: "https://example.com/post"
    )

    assert document.links_to?("https://weblog.ason.as/article")
  end

  def test_discovers_webmention_endpoints_in_protocol_order
    document = WeblogAuthoring::WebmentionDocument.new(
      '<link rel="webmention" href="/html-endpoint"><a rel="webmention" href="/anchor-endpoint">endpoint</a>',
      base_url: "https://example.com/post"
    )

    assert_equal(
      "https://example.com/header-endpoint?token=1",
      document.webmention_endpoint(link_header: '</header-endpoint?token=1>; rel="webmention"')
    )
    assert_equal "https://example.com/html-endpoint", document.webmention_endpoint
  end
end
