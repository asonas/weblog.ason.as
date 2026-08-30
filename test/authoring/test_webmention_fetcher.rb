# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_fetcher"
require "stringio"
require "zlib"

class WebmentionFetcherTest < Minitest::Test
  class Resolver
    def initialize(addresses)
      @addresses = addresses
    end

    def getaddresses(host)
      @addresses.fetch(host)
    end
  end

  class ScriptedFetcher < WeblogAuthoring::WebmentionFetcher
    attr_reader :requests

    def initialize(resolver:, responses:)
      super(resolver:, clock: -> { 1.0 })
      @responses = responses
      @requests = []
    end

    private

    def request(uri, address, deadline, request: nil)
      requests << { uri: uri.to_s, address:, deadline:, request: request&.class }
      @responses.shift
    end
  end

  def test_rechecks_redirect_hosts_and_blocks_private_destinations
    redirect = Net::HTTPFound.new("1.1", "302", "Found")
    redirect["location"] = "http://127.0.0.1/private"
    fetcher = ScriptedFetcher.new(
      resolver: Resolver.new("example.com" => ["8.8.8.8"], "127.0.0.1" => ["127.0.0.1"]),
      responses: [[redirect, ""]]
    )

    error = assert_raises(WeblogAuthoring::WebmentionFetcher::FetchError) do
      fetcher.fetch("https://example.com/post")
    end

    assert_equal "blocked_source", error.result
    assert_equal ["https://example.com/post"], (fetcher.requests.map { |request| request.fetch(:uri) })
  end

  def test_blocks_a_private_webmention_endpoint_before_posting
    fetcher = ScriptedFetcher.new(
      resolver: Resolver.new("127.0.0.1" => ["127.0.0.1"]), responses: []
    )

    error = assert_raises(WeblogAuthoring::WebmentionFetcher::FetchError) do
      fetcher.post_form("http://127.0.0.1/webmention", "source" => "https://example.com")
    end

    assert_equal "blocked_source", error.result
    assert_empty fetcher.requests
  end

  def test_checks_the_expanded_size_of_gzip_html
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/html"
    response["content-encoding"] = "gzip"
    compressed = StringIO.new
    Zlib::GzipWriter.wrap(compressed) { |writer| writer.write("x" * (WeblogAuthoring::WebmentionFetcher::MAX_BYTES + 1)) }
    fetcher = ScriptedFetcher.new(
      resolver: Resolver.new("example.com" => ["8.8.8.8"]), responses: [[response, compressed.string]]
    )

    error = assert_raises(WeblogAuthoring::WebmentionFetcher::FetchError) do
      fetcher.fetch("https://example.com/post")
    end

    assert_equal "invalid_source", error.result
  end
end
