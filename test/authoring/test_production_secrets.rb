# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/production_secrets"

class ProductionSecretsTest < Minitest::Test
  Response = Data.define(:parameter)
  Parameter = Data.define(:value)

  def test_reports_secret_fetch_and_decode_timings
    client = Object.new
    client.define_singleton_method(:get_parameter) do |name:, with_decryption:|
      raise "unexpected secret" unless name == "/oauth" && with_decryption

      Response.new(Parameter.new(JSON.generate(
        "github_client_id" => "id",
        "github_client_secret" => "secret",
        "session_secret" => "session"
      )))
    end
    samples = [0.0, 1.0, 2.0, 3.0]
    timings = {}
    secrets = WeblogAuthoring::ProductionSecrets.new(
      secret_id: "oauth", client:, timings:, monotonic_clock: -> { samples.shift }
    ).fetch

    assert_equal "id", secrets.fetch("github_client_id")
    assert_equal({ "secret_get" => 1000.0, "secret_decode" => 1000.0 }, timings)
  end
end
