# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

class LambdaRubyEntrypointTest < Minitest::Test
  ENTRYPOINT = File.expand_path("../../scripts/lambda-ruby-entrypoint.sh", __dir__)

  def test_passes_the_selected_handler_to_the_runtime_client_and_preserves_its_status
    Dir.mktmpdir do |directory|
      client = File.join(directory, "aws_lambda_ric")
      File.write(client, "#!/bin/sh\nprintf '%s' \"$_HANDLER\"\nexit 23\n")
      File.chmod(0o755, client)

      output, error, status = Open3.capture3({ "PATH" => "#{directory}:#{ENV.fetch("PATH")}" },
                                            "sh", ENTRYPOINT, "matrix_notifier.Handler.call")

      assert_equal "matrix_notifier.Handler.call", output
      assert_empty error
      assert_equal 23, status.exitstatus
    end
  end

  def test_rejects_a_missing_handler
    _output, error, status = Open3.capture3("sh", ENTRYPOINT)

    refute status.success?
    assert_includes error, "Lambda handler is required"
  end
end
