# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/operation_metrics"

class OperationMetricsTest < Minitest::Test
  Metrics = WeblogAuthoring::OperationMetrics
  Context = Data.define(:aws_request_id)

  class Connection
    def initialize(failures: 0)
      @failures = failures
    end

    def exec_params(_sql, _values)
      if @failures.positive?
        @failures -= 1
        raise IOError, "private SQL parameter"
      end
      [{ "id" => 1 }]
    end
  end

  class Pool
    def initialize(connection)
      @connection = connection
    end

    def with
      yield @connection
    rescue IOError
      yield @connection
    end
  end

  def setup
    @environment = %w[OPERATION_METRICS_SAMPLE_RATE OPERATION_METRICS_UNTIL].to_h { |key| [key, ENV[key]] }
    ENV["OPERATION_METRICS_SAMPLE_RATE"] = "1"
    ENV["OPERATION_METRICS_UNTIL"] = (Time.now.to_i + 60).to_s
  end

  def teardown
    @environment.each { |key, value| ENV[key] = value }
  end

  def test_counts_failed_query_attempts_and_pool_retries_without_logging_content
    event = { "rawPath" => "/private-title", "body" => "secret-body", "headers" => { "cookie" => "secret-cookie" },
      "requestContext" => { "http" => { "method" => "GET" } }, }
    output, = capture_io do
      response = Metrics.measure(event:, context: Context.new("one")) do
        rows = Metrics.with_connection(Pool.new(Connection.new(failures: 1))) do |connection|
          connection.exec_params("SELECT private_column", ["private-parameter"])
        end
        assert_equal [{ "id" => 1 }], rows
        Metrics.delivery("dynamic", release: "a" * 40)
        { statusCode: 200, body: "secret-response" }
      end
      assert_equal "secret-response", response[:body]
    end
    entry = JSON.parse(output)
    assert_equal 2, entry.fetch("sql_count")
    assert_equal 1, entry.fetch("sql_errors")
    assert_equal 1, entry.fetch("db_retries")
    assert_equal "public_html", entry.fetch("workload")
    assert_equal "dynamic", entry.fetch("delivery")
    assert_equal false, entry.fetch("failed")
    assert_operator entry.fetch("sql_ms"), :>=, 0
    assert_operator output.bytesize, :<, 1024
    refute_match(/private|secret|SELECT/, output)
    assert_nil Metrics.current
  end

  def test_exception_propagates_and_next_operation_has_fresh_counters
    output, = capture_io do
      assert_raises(IOError) do
        Metrics.measure(event: {}, context: Context.new("failed")) { raise IOError, "secret" }
      end
      assert_nil Metrics.current
      Metrics.measure(event: {}, context: Context.new("next")) { { statusCode: 204 } }
    end
    failed, following = output.lines.map { |line| JSON.parse(line) }
    assert_equal true, failed.fetch("failed")
    assert_equal false, following.fetch("failed")
    assert_equal 0, following.fetch("sql_count")
    refute_includes output, "secret"
  end

  def test_distinguishes_publication_from_editing_and_public_reads
    requests = [
      ["POST", "/api/authoring/drafts/private-id/publications/prepare", "publication"],
      ["POST", "/api/authoring/drafts/private-id/uploads", "authoring"],
      ["GET", "/api/pages", "public_api"],
      ["GET", "/api/auth/session", "auth"],
    ]
    requests.each do |method, path, expected|
      event = { "rawPath" => path, "requestContext" => { "http" => { "method" => method } } }
      assert_equal expected, Metrics.classify(event)
    end
  end

  def test_expired_disabled_invalid_and_unsampled_requests_produce_no_extra_log
    [["1", "0"], ["0", (Time.now.to_i + 60).to_s], ["invalid", "invalid"], ["0.000000001", (Time.now.to_i + 60).to_s]].each do |rate, deadline|
      ENV["OPERATION_METRICS_SAMPLE_RATE"] = rate
      ENV["OPERATION_METRICS_UNTIL"] = deadline
      output, = capture_io do
        assert_equal :response, Metrics.measure(event: {}, context: Context.new("unsampled")) { :response }
      end
      assert_empty output
      assert_nil Metrics.current
    end
  end
end
