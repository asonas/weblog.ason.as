# frozen_string_literal: true

require "json"
require "aws-sdk-secretsmanager"

module WeblogAuthoring
  class ProductionSecrets
    REQUIRED_KEYS = %w[github_client_id github_client_secret session_secret].freeze

    def initialize(secret_id:, client: Aws::SecretsManager::Client.new)
      @secret_id = secret_id
      @client = client
    end

    def fetch
      @secrets ||= begin
        values = JSON.parse(@client.get_secret_value(secret_id: @secret_id).secret_string)
        REQUIRED_KEYS.each { |key| values.fetch(key) }
        values.freeze
      end
    end
  end
end
