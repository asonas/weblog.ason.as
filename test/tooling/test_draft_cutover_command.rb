# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class DraftCutoverCommandTest < Minitest::Test
  def test_mutation_requires_exact_target_and_preserved_evidence_before_connecting
    command = ["ruby", "-rbundler/setup", "bin/draft-cutover"]
    host = "example.dsql.ap-northeast-1.on.aws"
    output, error, status = Open3.capture3(*command, "initialize", "--host", host)
    refute status.success?
    assert_empty output
    assert_includes error, "Confirm the exact host"
    output, error, status = Open3.capture3(*command, "transition", "--host", host, "--confirm-host", host)
    refute status.success?
    assert_empty output
    assert_includes error, "evidence"
  end
end
