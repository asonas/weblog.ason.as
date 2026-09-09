# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestComparePublicArticle < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  COMMAND = ROOT.join("bin/compare-public-article")

  def test_records_the_stage_and_reason_when_comparison_fails
    Dir.mktmpdir do |directory|
      output = Pathname(directory).join("comparison")
      _stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--baseline", "missing-comparison-ref",
        "--candidate", "HEAD",
        "--output", output.to_s,
        chdir: ROOT.to_s
      )

      refute status.success?
      assert_includes stderr, "Comparison failed during build"
      result = JSON.parse(output.join("result.json").read)
      assert_equal "failed", result.fetch("status")
      assert_equal "build", result.fetch("stage")
      assert_includes result.fetch("reason"), "Cannot resolve commit: missing-comparison-ref"
    end
  end
end
