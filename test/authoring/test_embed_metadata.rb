# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/embed_metadata"

class TestEmbedMetadata < Minitest::Test
  class SpeakerDeckFetcher < WeblogAuthoring::EmbedMetadataFetcher
    attr_reader :requested_urls

    def initialize(player_url: "https://speakerdeck.com/player/01c1db30c790447fafdf79a27979b67e")
      super(resolver: ->(_host) { ["8.8.8.8"] })
      @player_url = player_url
      @requested_urls = []
    end

    private

    def http_get(uri, _address)
      @requested_urls << uri.to_s
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response["content-type"] = uri.path == "/oembed.json" ? "application/json" : "text/html"
      response.body = if uri.path == "/oembed.json"
                        JSON.generate(html: %(<iframe src="#{@player_url}"></iframe>), width: 710, height: 399)
                      else
                        +"<title>module Synths; end</title>"
                      end
      response
    end
  end

  def test_speakerdeck_resolves_the_official_player_and_dimensions
    fetcher = SpeakerDeckFetcher.new
    url = "https://speakerdeck.com/asonas/module-synths-end"

    metadata = fetcher.fetch(url)

    assert_equal "module Synths; end", metadata["title"]
    assert_equal({ "src" => "https://speakerdeck.com/player/01c1db30c790447fafdf79a27979b67e",
                   "width" => 710, "height" => 399, }, metadata["speakerdeck"])
    assert_equal [url, "https://speakerdeck.com/oembed.json?#{URI.encode_www_form(url:)}"], fetcher.requested_urls
  end

  def test_speakerdeck_rejects_an_untrusted_player_source
    fetcher = SpeakerDeckFetcher.new(player_url: "https://example.com/player/01c1db30c790447fafdf79a27979b67e")

    assert_raises(WeblogAuthoring::EmbedMetadataFetcher::FetchError) do
      fetcher.fetch("https://speakerdeck.com/asonas/module-synths-end")
    end
  end

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
