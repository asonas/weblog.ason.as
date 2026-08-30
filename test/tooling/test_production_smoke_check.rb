# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
load File.expand_path("../../bin/smoke-production", __dir__)

class ProductionSmokeCheckTest < Minitest::Test
  Response = Struct.new(:code, :body) do
    def is_a?(klass)
      return code.start_with?("2") if klass == Net::HTTPSuccess

      super
    end
  end

  class FakeHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def get_response(uri)
      @requests << uri.to_s
      @responses.fetch(uri.to_s)
    end
  end

  def test_checks_html_referenced_asset_and_public_api
    http = FakeHttp.new(
      "https://example.test" => Response.new("200", '<script src="/static/authoring/assets/app-abc.js"></script><link href="/static/authoring/assets/app-def.css">'),
      "https://example.test/static/authoring/assets/app-abc.js" => Response.new("200", "javascript"),
      "https://example.test/static/authoring/assets/app-def.css" => Response.new("200", "css"),
      "https://example.test/api/pages" => Response.new("200", '{"pages":[]}')
    )
    ProductionSmokeCheck.new("https://example.test", http:).call
    assert_equal ["https://example.test", "https://example.test/static/authoring/assets/app-abc.js", "https://example.test/static/authoring/assets/app-def.css", "https://example.test/api/pages"], http.requests
  end

  def test_rejects_missing_asset_reference
    http = FakeHttp.new("https://example.test" => Response.new("200", "<html></html>"))
    error = assert_raises(RuntimeError) { ProductionSmokeCheck.new("https://example.test", http:).call }
    assert_equal "Production HTML does not reference an authoring asset", error.message
  end

  def test_rejects_unsuccessful_response
    http = FakeHttp.new("https://example.test" => Response.new("503", "unavailable"))
    error = assert_raises(RuntimeError) { ProductionSmokeCheck.new("https://example.test", http:).call }
    assert_equal "https://example.test returned HTTP 503", error.message
  end
end
