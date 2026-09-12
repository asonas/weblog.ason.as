# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "weblog_authoring/parameter_extension"
require "weblog_authoring/production_secrets"

class ParameterExtensionTest < Minitest::Test
  def with_extension(status:, body:)
    server = TCPServer.new("127.0.0.1", 0)
    variables = {
      "PARAMETERS_SECRETS_EXTENSION_HTTP_PORT" => server.addr[1].to_s,
      "AWS_SESSION_TOKEN" => "test-session-token",
    }
    previous = variables.to_h { |key, _value| [key, ENV[key]] }
    variables.each { |key, value| ENV[key] = value }
    worker = Thread.new do
      socket = server.accept
      request = []
      loop do
        line = socket.gets
        break if line.nil? || line == "\r\n"

        request << line.chomp
      end
      socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
      request
    end
    yield worker
  ensure
    server&.close
    worker&.kill
    worker&.join
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_fetches_decrypted_configuration_and_reuses_it
    value = JSON.generate("github_client_id" => "id", "github_client_secret" => "secret", "session_secret" => "session")
    with_extension(status: "200 OK", body: JSON.generate("Parameter" => { "Value" => value })) do |worker|
      loader = WeblogAuthoring::ProductionSecrets.new(secret_id: "oauth/a b", client: WeblogAuthoring::ParameterExtension.new)
      secrets = loader.fetch
      assert_equal "id", secrets.fetch("github_client_id")
      assert_same secrets, loader.fetch
      request = worker.value
      assert_equal "GET /systemsmanager/parameters/get?name=%2Foauth%2Fa+b&withDecryption=true HTTP/1.1", request.first
      assert_includes request.map(&:downcase), "x-aws-parameters-secrets-token: test-session-token"
    end
  end

  def test_rejects_failed_responses_without_exposing_the_body
    with_extension(status: "403 Forbidden", body: "sensitive response") do |_worker|
      error = assert_raises(RuntimeError) do
        WeblogAuthoring::ParameterExtension.new.get_parameter(name: "/oauth", with_decryption: true)
      end
      assert_equal "Parameter extension returned HTTP 403", error.message
    end
  end
end
