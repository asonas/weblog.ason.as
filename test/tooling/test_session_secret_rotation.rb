# frozen_string_literal: true

require "json"
require "minitest/autorun"
load File.expand_path("../../bin/rotate-production-session-secret", __dir__)

class SessionSecretRotationTest < Minitest::Test
  Response = Struct.new(:parameter)
  Parameter = Struct.new(:arn, :value)

  class FakeParameterStore
    attr_reader :writes

    def initialize(current, account_id: ProductionSessionSecretRotation::AWS_ACCOUNT_ID)
      @current = current
      @account_id = account_id
      @writes = []
    end

    def get_parameter(name:, with_decryption:)
      raise "unexpected parameter" unless name == ProductionSessionSecretRotation::SECRET_ID

      Response.new(Parameter.new(
        "arn:aws:ssm:ap-northeast-1:#{@account_id}:parameter#{name}",
        with_decryption ? JSON.generate(@current) : "ciphertext"
      ))
    end

    def put_parameter(**attributes)
      @writes << attributes
    end
  end

  def test_rotates_only_the_session_secret
    current = {
      "github_client_id" => "client-id",
      "github_client_secret" => "client-secret",
      "session_secret" => "old-session-secret",
    }
    client = FakeParameterStore.new(current)

    ProductionSessionSecretRotation.new(client:).call

    assert_equal 1, client.writes.length
    write = client.writes.first
    assert_equal ProductionSessionSecretRotation::SECRET_ID, write.fetch(:name)
    assert_equal "SecureString", write.fetch(:type)
    assert_equal "Standard", write.fetch(:tier)
    assert write.fetch(:overwrite)
    rotated = JSON.parse(write.fetch(:value))
    assert_equal "client-id", rotated.fetch("github_client_id")
    assert_equal "client-secret", rotated.fetch("github_client_secret")
    refute_equal "old-session-secret", rotated.fetch("session_secret")
    assert_equal 128, rotated.fetch("session_secret").length
  end

  def test_missing_oauth_fields_fail_before_writing
    client = FakeParameterStore.new({ "session_secret" => "old-session-secret" })

    assert_raises(KeyError) { ProductionSessionSecretRotation.new(client:).call }

    assert_empty client.writes
  end

  def test_wrong_account_fails_before_decrypting_or_writing
    client = FakeParameterStore.new({}, account_id: "111111111111")

    error = assert_raises(RuntimeError) { ProductionSessionSecretRotation.new(client:).call }

    assert_equal "Expected AWS account 282782318939, got 111111111111", error.message
    assert_empty client.writes
  end
end
