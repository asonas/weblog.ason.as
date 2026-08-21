# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/embed_metadata"

class TestEmbedMetadata < Minitest::Test
  def test_parser_reads_open_graph_metadata_and_fallbacks
    parser = WeblogAuthoring::EmbedMetadataFetcher::Parser.new(<<~HTML)
      <html><head>
        <title>Fallback title</title>
        <meta property="og:title" content="OGP title">
        <meta property="og:description" content="Description &amp; detail">
        <meta property="og:image" content="/card.jpg">
        <meta property="og:site_name" content="Example">
        <link rel="canonical" href="https://example.com/canonical">
      </head></html>
    HTML

    assert_equal "OGP title", parser.title
    assert_equal "Description & detail", parser.description
    assert_equal "/card.jpg", parser.image_url
    assert_equal "Example", parser.site_name
    assert_equal "https://example.com/canonical", parser.canonical_url
  end

  def test_fetcher_rejects_private_addresses_before_requesting_them
    fetcher = WeblogAuthoring::EmbedMetadataFetcher.new(resolver: ->(_host) { ["127.0.0.1"] })

    error = assert_raises(WeblogAuthoring::EmbedMetadataFetcher::FetchError) do
      fetcher.fetch("http://example.com/private")
    end

    assert_includes error.message, "プライベートネットワーク"
  end
end
