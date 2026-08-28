# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lambda/inbox_sync"

class InboxSyncLambdaTest < Minitest::Test
  class FixtureRunner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(trigger:, run_id:)
      calls << { trigger:, run_id: }
      { "id" => run_id, "status" => "succeeded" }
    end
  end

  def test_scheduled_and_manual_events_run_the_same_sync_runner
    runner = FixtureRunner.new

    scheduled = WeblogAuthoring::InboxSyncLambdaHandler.call(
      event: { "source" => "aws.events", "detail-type" => "Scheduled Event" }, context: nil, runner:
    )
    manual = WeblogAuthoring::InboxSyncLambdaHandler.call(
      event: { "type" => "inbox_sync", "trigger" => "manual", "run_id" => "manual-run" }, context: nil, runner:
    )

    assert_equal "scheduled", runner.calls.fetch(0).fetch(:trigger)
    assert_match(/\A[0-9a-f]{32}\z/, scheduled.fetch("id"))
    assert_equal({ trigger: "manual", run_id: "manual-run" }, runner.calls.fetch(1))
    assert_equal "succeeded", manual.fetch("status")
  end
end
