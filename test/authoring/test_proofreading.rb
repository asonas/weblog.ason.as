# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/proofreading"

class ProofreadingTest < Minitest::Test
  def test_local_node_process_returns_real_textlint_findings
    result = WeblogAuthoring::Proofreading.new.call("見れる。")
    assert_equal "no-dropping-the-ra", result.fetch("messages").fetch(0).fetch("ruleId")
    assert_equal [1, 2], result.fetch("messages").fetch(0).fetch("range")
  end

  def test_lambda_failure_is_reported_as_unavailable
    client = Aws::Lambda::Client.new(stub_responses: true)
    client.stub_responses(:invoke, function_error: "Unhandled", payload: "{}")
    service = WeblogAuthoring::Proofreading.new(lambda_client: client, function_name: "proofreading")
    assert_raises(WeblogAuthoring::Proofreading::Unavailable) { service.call("本文。") }
  end
end
