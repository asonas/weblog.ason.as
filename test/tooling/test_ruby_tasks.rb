# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestRubyTasks < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path.freeze
  TASK_ENV = {
    "AWS_ACCESS_KEY_ID" => nil,
    "AWS_SECRET_ACCESS_KEY" => nil,
    "AWS_SESSION_TOKEN" => nil,
    "RUBY_TASK_PROCESS_TEST" => "1",
  }.freeze

  def test_verification_tasks_succeed_without_credentials_or_tracked_changes
    skip if ENV["RUBY_TASK_PROCESS_TEST"] == "1"

    original_diff = tracked_diff
    %w[ruby:lint ruby:test ruby:coverage].each do |task|
      output, status = Open3.capture2e(TASK_ENV, "mise", "run", task, chdir: ROOT)

      assert status.success?, "#{task} failed:\n#{output}"
      assert_equal original_diff, tracked_diff, "#{task} changed tracked files"
    end
  end

  private

  def tracked_diff
    output, status = Open3.capture2e("git", "diff", "--binary", chdir: ROOT)
    raise output unless status.success?

    output
  end
end
