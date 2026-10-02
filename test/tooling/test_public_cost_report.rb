# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "zlib"

class PublicCostReportTest < Minitest::Test
  SCRIPT = File.expand_path("../../scripts/report-public-cost.py", __dir__)

  def test_cached_samples_and_billing_rows_are_aggregated_without_double_counting
    Dir.mktmpdir do |directory|
      logs = File.join(directory, "logs.json")
      cur = File.join(directory, "cost.csv.gz")
      entry = { event: "operation_metrics", timestamp: "2026-10-02T12:00:00Z", request_id: "one",
        function: "authoring", workload: "public_html", delivery: "dynamic", sample_rate: 0.1,
        sql_count: 4, sql_ms: 20, sql_errors: 1, db_retries: 1, duration_ms: 100, }
      File.write(logs, JSON.generate(events: [{ message: JSON.generate(entry) }, { message: JSON.generate(entry) }]))
      Zlib::GzipWriter.open(cur) do |file|
        file.write("identity_line_item_id,line_item_usage_start_date,line_item_product_code,line_item_resource_id,line_item_usage_type,line_item_line_item_type,pricing_unit,line_item_currency_code,line_item_usage_amount,line_item_unblended_cost\n")
        file.write("a,2026-10-02T00:00:00Z,AuroraDSQL,cluster,DPU,Usage,DPU,USD,1000,0.001\n")
        file.write("b,2026-10-02T00:00:00Z,AuroraDSQL,cluster,DPU,Usage,DPU,USD,2000,0.002\n")
      end
      output, error, status = Open3.capture3("python3", SCRIPT, "--operations", logs, "--cur", cur, "--cur", cur,
        "--start", "2026-10-02", "--end", "2026-10-03")
      assert status.success?, error
      result = JSON.parse(output)
      row = result.fetch("operations").fetch(0)
      assert_equal 1, row.fetch("samples")
      assert_equal 10, row.fetch("estimated_operations")
      assert_equal 40, row.fetch("estimated_sql_count")
      assert_equal 10, row.fetch("estimated_db_retries")
      assert_equal 100, row.fetch("sample_mean_duration_ms")
      assert_equal "0.003", result.fetch("costs").fetch(0).fetch("unblended_cost")
      assert_equal "3000", result.fetch("costs").fetch(0).fetch("usage")
    end
  end

  def test_truncated_log_export_is_rejected_instead_of_reported_as_complete
    Dir.mktmpdir do |directory|
      path = File.join(directory, "truncated.json")
      File.write(path, JSON.generate(events: [], NextToken: "next"))
      _output, error, status = Open3.capture3("python3", SCRIPT, "--operations", path, "--start", "2026-10-02", "--end", "2026-10-03")
      refute status.success?
      assert_includes error, "Incomplete log export"
    end
  end
end
