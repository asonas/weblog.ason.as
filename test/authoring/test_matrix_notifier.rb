# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "weblog_authoring/matrix_notifier"

class MatrixNotifierTest < Minitest::Test
  class FixtureRequest
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(**arguments)
      calls << arguments
      { status: 200 }
    end
  end

  def test_sends_an_alarm_with_the_sns_message_id_as_the_transaction_id
    request = FixtureRequest.new
    notifier = WeblogAuthoring::MatrixNotifier.new(
      secret_loader: -> { matrix_secret }, request:
    )

    notifier.call(sns_event(
      message_id: "sns-message-1",
      state: "ALARM",
      description: "Bluesky sync failed. Runbook: https://weblog.ason.as/runbook#authentication"
    ))

    call = request.calls.fetch(0)
    assert_equal "https", call.fetch(:uri).scheme
    assert_match(%r{/rooms/%21alerts%3Amatrix\.org/send/m\.room\.message/sns-message-1\z}, call.fetch(:uri).path)
    assert_equal "Bearer matrix-access-token", call.fetch(:headers).fetch("Authorization")
    body = JSON.parse(call.fetch(:body))
    assert_equal "m.text", body.fetch("msgtype")
    assert_includes body.fetch("body"), "ALARM"
    assert_includes body.fetch("body"), "https://weblog.ason.as/runbook#authentication"
    refute_includes body.fetch("body"), "matrix-access-token"
  end

  def test_labels_an_ok_transition_as_recovered
    request = FixtureRequest.new
    notifier = WeblogAuthoring::MatrixNotifier.new(
      secret_loader: -> { matrix_secret }, request:
    )

    notifier.call(sns_event(message_id: "sns-message-2", state: "OK", description: "Recovered"))

    body = JSON.parse(request.calls.fetch(0).fetch(:body)).fetch("body")
    assert_includes body, "復旧"
  end

  private

  def matrix_secret
    {
      "homeserver_url" => "https://matrix.example.net",
      "room_id" => "!alerts:matrix.org",
      "access_token" => "matrix-access-token",
    }
  end

  def sns_event(message_id:, state:, description:)
    {
      "Records" => [{
        "EventSource" => "aws:sns",
        "Sns" => {
          "MessageId" => message_id,
          "Message" => JSON.generate(
            "AlarmName" => "weblog-inbox-bluesky-authentication-production",
            "AlarmDescription" => description,
            "NewStateValue" => state,
            "NewStateReason" => "Threshold crossed"
          ),
        },
      }],
    }
  end
end
