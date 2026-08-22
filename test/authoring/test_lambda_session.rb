# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/lambda_session"

class LambdaSessionTest < Minitest::Test
  def test_round_trips_a_signed_session
    clock = -> { Time.iso8601("2026-08-22T12:00:00Z") }
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64, clock:)
    token = codec.issue(kind: "session", attributes: { "login" => "asonas" }, ttl: 60)

    assert_equal "asonas", codec.read(token, kind: "session").fetch("login")
  end

  def test_rejects_tampered_and_expired_sessions
    now = Time.iso8601("2026-08-22T12:00:00Z")
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64, clock: -> { now })
    token = codec.issue(kind: "session", attributes: {}, ttl: 60)

    assert_nil codec.read("#{token}changed", kind: "session")
    now += 61
    assert_nil codec.read(token, kind: "session")
  end
end
