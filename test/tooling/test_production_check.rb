# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class ProductionCheckTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/check-production")

  def test_checks_only_expected_read_only_production_state
    with_fake_aws(account: "282782318939") do |environment, log|
      output, status = Open3.capture2e(environment, SCRIPT)

      assert_predicate status, :success?, output
      assert_includes output, "Production check passed"
      commands = File.readlines(log, chomp: true)
      assert_equal(
        1,
        commands.count { |command| command.start_with?("sts get-caller-identity ") }
      )
      assert_equal(
        5,
        commands.count { |command| command.start_with?("lambda get-function-configuration ") }
      )
      assert_equal(
        2,
        commands.count { |command| command.start_with?("secretsmanager describe-secret ") }
      )
      assert(commands.none? { |command| command.match?(/\b(put|update|delete|invoke)\b/) })
    end
  end

  def test_rejects_credentials_for_another_account
    with_fake_aws(account: "000000000000") do |environment, log|
      output, status = Open3.capture2e(environment, SCRIPT)

      refute_predicate status, :success?
      assert_includes output, "Expected AWS account 282782318939, got 000000000000"
      assert_equal 1, File.readlines(log).length
    end
  end

  private

  def with_fake_aws(account:)
    Dir.mktmpdir do |directory|
      log = File.join(directory, "aws.log")
      executable = File.join(directory, "aws")
      File.write(executable, fake_aws)
      FileUtils.chmod(0o755, executable)
      environment = {
        "FAKE_AWS_ACCOUNT" => account,
        "FAKE_AWS_LOG" => log,
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      }
      yield environment, log
    end
  end

  def fake_aws
    <<~SH
      #!/usr/bin/env bash
      set -euo pipefail
      printf '%s\\n' "$*" >> "${FAKE_AWS_LOG}"
      case "$1 $2" in
        "sts get-caller-identity") printf '%s\\n' "${FAKE_AWS_ACCOUNT}" ;;
        "lambda get-function-configuration") printf 'Active\\tSuccessful\\n' ;;
        "secretsmanager describe-secret") printf 'arn:aws:secretsmanager:ap-northeast-1:282782318939:secret:test\\n' ;;
        *) exit 64 ;;
      esac
    SH
  end
end
