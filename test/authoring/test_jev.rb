# frozen_string_literal: true
require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/jev"

class JevTest < Minitest::Test
  def test_loads_secure_parameter_lazily_and_reuses_it
    calls = []
    secrets = Object.new
    secrets.define_singleton_method(:get_parameter) do |**options|
      calls << options
      WeblogAuthoring::ParameterExtension::Response.new(WeblogAuthoring::ParameterExtension::Parameter.new("ssm-key"))
    end
    headers = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      headers << request["Authorization"]
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.body = '{"answers":{}}'
      response
    end
    http.define_singleton_method(:start) { |*_args, **_options, &block| block.call(http) }
    client = WeblogAuthoring::Jev.new(api_key: "old-key", secret_id: "weblog-authoring-production/typesafe", secret_client: secrets, http: http)
    assert client.configured?
    assert_empty calls
    2.times { assert_equal({}, client.evaluate(state: "test", questions: {})) }
    assert_equal [{ name: "/weblog-authoring-production/typesafe", with_decryption: true }], calls
    assert_equal ["Bearer ssm-key", "Bearer ssm-key"], headers
  end

  def test_secret_failure_is_unavailable_without_exposing_the_error
    secrets = Object.new
    secrets.define_singleton_method(:get_parameter) { |**_options| raise IOError, "secret value" }
    client = WeblogAuthoring::Jev.new(api_key: nil, secret_id: "typesafe", secret_client: secrets)
    error = assert_raises(WeblogAuthoring::Jev::Unavailable) { client.evaluate(state: "test", questions: {}) }
    refute_includes error.message, "secret value"
  end
end
