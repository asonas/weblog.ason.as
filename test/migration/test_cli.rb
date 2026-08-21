# frozen_string_literal: true

require "open3"
require_relative "../test_helper"

class MigrationCliTest < Minitest::Test
  FIXTURE = Pathname(__dir__).join("../fixtures/scrapbox/minimal.json").expand_path

  def test_cli_requires_input_output_and_report
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, Pathname(__dir__).join("../../bin/migrate").expand_path.to_s)
    refute status.success?
    assert_includes stderr, "--input"
  end

  def test_cli_rejects_missing_input
    root = Pathname(Dir.mktmpdir)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      Pathname(__dir__).join("../../bin/migrate").expand_path.to_s,
      "--input", root.join("missing.json").to_s,
      "--output", root.join("out").to_s,
      "--report", root.join("report").to_s
    )
    refute status.success?
    assert_includes stderr, "missing.json"
  end

  def test_cli_generates_normalized_index_site_manifest_and_report
    root = Pathname(Dir.mktmpdir)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      Pathname(__dir__).join("../../bin/migrate").expand_path.to_s,
      "--input", FIXTURE.to_s,
      "--output", root.join("normalized").to_s,
      "--report", root.join("report").to_s
    )
    assert status.success?, "stdout=#{stdout}\nstderr=#{stderr}"
    assert root.join("normalized", "posts").children.any?
    assert root.join("normalized", "index", "log.sqlite3").file?
    assert root.join("normalized", "asset-manifest.json").file?
    assert root.join("normalized", "site", "2024-08-01", "index.html").file?
    assert root.join("normalized", "site", "static", "cards-data.json").file?
    assert root.join("report", "migration-report.md").file?
    assert_equal 2, JSON.parse(root.join("report", "migration-report.json").read).fetch("pages")
  end
end
