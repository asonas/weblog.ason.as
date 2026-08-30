# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/production_secrets"

class ProductionSecretsTest < Minitest::Test
  Response = Data.define(:secret_string)

  def test_reports_secret_fetch_and_decode_timings
    client = Object.new
    client.define_singleton_method(:get_secret_value) do |secret_id:|
      raise "unexpected secret" unless secret_id == "oauth"

      Response.new(JSON.generate(
        "github_client_id" => "id",
        "github_client_secret" => "secret",
        "session_secret" => "session"
      ))
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
