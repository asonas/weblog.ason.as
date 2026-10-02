# frozen_string_literal: true

require "json"
require "time"
require "digest"

module WeblogAuthoring
  module OperationMetrics
    module_function

    def current = Thread.current[:weblog_operation_metrics]

    def measure(event:, context:, workload: classify(event))
      return yield if current
      rate = sample_rate
      return yield unless rate.positive? && Digest::SHA256.hexdigest(context&.aws_request_id.to_s)[0, 8].to_i(16) < rate * (2**32)

      started = monotonic
      metrics = {
        "event" => "operation_metrics", "schema" => 1, "timestamp" => Time.now.utc.iso8601(3),
        "request_id" => context&.aws_request_id,
        "gateway_request_id" => event.dig("requestContext", "requestId"),
        "function" => ENV["AWS_LAMBDA_FUNCTION_NAME"], "code_revision" => ENV["BUILD_CONTENT_HASH"],
        "workload" => workload, "sample_rate" => rate, "sql_count" => 0, "sql_ms" => 0.0,
        "sql_errors" => 0, "db_retries" => 0, "failed" => true,
      }
      Thread.current[:weblog_operation_metrics] = metrics
      begin
        response = yield
        metrics["status"] = response[:statusCode] || response["statusCode"] if response.is_a?(Hash)
        metrics["failed"] = false
        response
      ensure
        Thread.current[:weblog_operation_metrics] = nil
        metrics["duration_ms"] = ((monotonic - started) * 1000).round(3)
        metrics["sql_ms"] = metrics["sql_ms"].round(3)
        puts JSON.generate(metrics)
      end
    end

    def sample_rate
      deadline = Float(ENV.fetch("OPERATION_METRICS_UNTIL", "0"), exception: false)
      rate = Float(ENV.fetch("OPERATION_METRICS_SAMPLE_RATE", "0"), exception: false)
      return 0.0 unless deadline && deadline.finite? && deadline > Time.now.to_f
      return 0.0 unless rate && rate.finite? && rate.positive? && rate <= 1

      rate
    end

    def classify(event)
      method = event.dig("requestContext", "http", "method")
      return "scheduled_maintenance" if event["source"] == "aws.events"
      return "maintenance" unless method

      path = event.fetch("rawPath", "")
      return "auth" if path.start_with?("/api/auth/", "/oauth/")
      return "health" if path == "/health"
      return "authoring" if path.start_with?("/authoring/", "/draft-editor")
      return "public_html" if %w[GET HEAD].include?(method) && !path.start_with?("/api/")
      return "publication" if path.match?(%r{\A/api/authoring/drafts/[^/]+/publications(?:/|\z)})
      return "public_api" if method == "GET" && (
        %w[/api/pages /api/search /api/tags /api/archive /api/page-names /api/related /api/diary-navigation /api/embed].include?(path) ||
        path.start_with?("/api/pages/", "/api/routes/")
      )

      "authoring"
    end

    def delivery(mode, release: nil)
      return unless current

      current["delivery"] = mode
      current["display_release"] = release if release
    end

    # Pool retries re-enter this block; implicit BEGIN/COMMIT commands are excluded.
    def with_connection(pool, **options)
      metrics = current
      return pool.with(**options) { |connection| yield connection } unless metrics

      attempts = 0
      pool.with(**options) do |connection|
        metrics["db_retries"] += 1 if attempts.positive?
        attempts += 1
        yield Connection.new(connection, metrics)
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class Connection
      def initialize(connection, metrics)
        @connection = connection
        @metrics = metrics
      end

      def exec(...) = measure { @connection.exec(...) }
      def exec_params(...) = measure { @connection.exec_params(...) }
      def transaction(&block) = @connection.transaction(&block)

      private

      def measure
        started = OperationMetrics.monotonic
        @metrics["sql_count"] += 1
        succeeded = false
        begin
          result = yield
          succeeded = true
          result
        ensure
          @metrics["sql_ms"] += (OperationMetrics.monotonic - started) * 1000
          @metrics["sql_errors"] += 1 unless succeeded
        end
      end
    end
  end
end
