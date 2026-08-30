# frozen_string_literal: true

require_relative "../test_helper"

require "open3"
require "socket"

class TestDevTasks < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path.freeze

  def test_vite_fails_instead_of_selecting_another_port
    listener = begin
      TCPServer.new("127.0.0.1", 5173)
    rescue Errno::EADDRINUSE
      nil
    end
    output, status = Open3.capture2e("npm", "run", "dev", chdir: ROOT)

    refute status.success?
    assert_includes output, "Port 5173 is already in use"
  ensure
    listener&.close
  end
end
