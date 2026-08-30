# frozen_string_literal: true

require "json"
require "minitest/autorun"
load File.expand_path("../../bin/rotate-production-session-secret", __dir__)

class SessionSecretRotationTest < Minitest::Test
  Secret = Struct.new(:secret_string)
  Description = Struct.new(:arn)

  class FakeSecretsManager
    attr_reader :writes

    def initialize(current, account_id: ProductionSessionSecretRotation::AWS_ACCOUNT_ID)
      @current = current
      @account_id = account_id
      @writes = []
    end

    def describe_secret(secret_id:)
      raise "unexpected secret" unless secret_id == ProductionSessionSecretRotation::SECRET_ID

      Description.new("arn:aws:secretsmanager:ap-northeast-1:#{@account_id}:secret:oauth")
    end

    def get_secret_value(secret_id:)
      raise "unexpected secret" unless secret_id == ProductionSessionSecretRotation::SECRET_ID

      Secret.new(JSON.generate(@current))
    end

    def put_secret_value(**attributes)
      @writes << attributes
    end
  end

  def test_rotates_only_the_session_secret
    current = {
      "github_client_id" => "client-id",
      "github_client_secret" => "client-secret",
      "session_secret" => "old-session-secret",
    }
    client = FakeSecretsManager.new(current)

    ProductionSessionSecretRotation.new(client:).call

    assert_equal 1, client.writes.length
    write = client.writes.first
    assert_equal ProductionSessionSecretRotation::SECRET_ID, write.fetch(:secret_id)
    rotated = JSON.parse(write.fetch(:secret_string))
    assert_equal "client-id", rotated.fetch("github_client_id")
    assert_equal "client-secret", rotated.fetch("github_client_secret")
    refute_equal "old-session-secret", rotated.fetch("session_secret")
    assert_equal 128, rotated.fetch("session_secret").length
  end

  def test_missing_oauth_fields_fail_before_writing
    client = FakeSecretsManager.new({ "session_secret" => "old-session-secret" })

    assert_raises(KeyError) { ProductionSessionSecretRotation.new(client:).call }

    assert_empty client.writes
  end

  def test_wrong_account_fails_before_reading_or_writing
    client = FakeSecretsManager.new({}, account_id: "111111111111")

    error = assert_raises(RuntimeError) { ProductionSessionSecretRotation.new(client:).call }

    assert_equal "Expected AWS account 282782318939, got 111111111111", error.message
    assert_empty client.writes
  end
end
