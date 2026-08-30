# frozen_string_literal: true

require "json"
require "aws-sdk-secretsmanager"

module WeblogAuthoring
  class ProductionSecrets
    REQUIRED_KEYS = %w[github_client_id github_client_secret session_secret].freeze

    def initialize(secret_id:, client: Aws::SecretsManager::Client.new, timings: nil,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @secret_id = secret_id
      @client = client
      @timings = timings
      @monotonic_clock = monotonic_clock
    end

    def fetch
      @secrets ||= begin
        started_at = monotonic_time
        secret_string = @client.get_secret_value(secret_id: @secret_id).secret_string
        record_timing("secret_get", started_at)
        started_at = monotonic_time
        values = JSON.parse(secret_string)
        REQUIRED_KEYS.each { |key| values.fetch(key) }
        record_timing("secret_decode", started_at)
        values.freeze
      end
    end

    private

    def monotonic_time
      @monotonic_clock.call
    end

    def record_timing(name, started_at)
      return if @timings.nil?

      @timings[name] = ((monotonic_time - started_at) * 1000).round(1).to_f
    end
  end
end
