# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestReportArticleComparison < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  CAPTURE_COMMAND = ROOT.join("bin/capture-article-comparison")
  REPORT_COMMAND = ROOT.join("bin/report-article-comparison")

  def test_reports_baseline_candidate_and_pixel_difference
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      pair = create_pair(root)
      capture = root.join("capture")
      _stdout, stderr, status = Open3.capture3(
        CAPTURE_COMMAND.to_s, "--pair", pair.to_s, "--output", capture.to_s,
        chdir: ROOT.to_s
      )
      assert status.success?, stderr

      output = root.join("report")
      stdout, stderr, status = Open3.capture3(
        REPORT_COMMAND.to_s, "--capture", capture.to_s, "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      assert_includes stdout, "Generated article comparison report"
      %w[390 1568].each do |width|
        assert output.join("images/diff-#{width}.png").file?
      end
      html = output.join("index.html").read
      assert_includes html, "基準"
      assert_includes html, "変更版"
      assert_includes html, "差分"
      assert_includes html, "差分あり"
      assert_includes html, "Google Chrome"
      assert_includes html, "a" * 40
      assert_includes html, "b" * 40
    end
  end

  def test_fails_when_a_required_screenshot_is_missing
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      capture = root.join("capture")
      capture.mkpath
      capture.join("manifest.json").write(JSON.generate("viewports" => [{ "width" => 390 }]))

      _stdout, stderr, status = Open3.capture3(
        REPORT_COMMAND.to_s,
        "--capture", capture.to_s,
        "--output", root.join("report").to_s,
        chdir: ROOT.to_s
      )

      refute status.success?
      assert_includes stderr, "Required screenshot not found"
    end
  end

  def test_reports_no_difference_for_the_same_input
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      pair = create_pair(root, candidate_color: "#003c3c", candidate_height: 900)
      capture = root.join("capture")
      _stdout, stderr, status = Open3.capture3(
        CAPTURE_COMMAND.to_s, "--pair", pair.to_s, "--output", capture.to_s,
        chdir: ROOT.to_s
      )
      assert status.success?, stderr

      output = root.join("report")
      _stdout, stderr, status = Open3.capture3(
        REPORT_COMMAND.to_s, "--capture", capture.to_s, "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      comparisons = JSON.parse(output.join("manifest.json").read).fetch("comparisons")
      assert_equal [0, 0], (comparisons.map { |comparison| comparison.fetch("changed_pixels") })
      assert_equal [false, false], (comparisons.map { |comparison| comparison.fetch("dimensions_changed") })
      assert_equal 2, output.join("index.html").read.scan("差分なし").length
    end
  end

  private

  def create_pair(root, candidate_color: "#006060", candidate_height: 1200)
    pair = root.join("pair")
    {
      "baseline" => { color: "#003c3c", height: 900 },
      "candidate" => { color: candidate_color, height: candidate_height },
    }.each do |revision, appearance|
      site = pair.join(revision)
      site.mkpath
      site.join("article").write(<<~HTML)
        <!doctype html>
        <html><head><title>Fixture</title></head>
        <body style="margin: 0; min-height: #{appearance.fetch(:height)}px; background: #{appearance.fetch(:color)}"><article data-public-article="1"><h1>Fixture</h1></article></body></html>
      HTML
    end
    pair.join("manifest.json").write(JSON.generate(
      "baseline_commit" => "a" * 40,
      "candidate_commit" => "b" * 40,
      "fixture_id" => "fixture",
      "fixture_captured_at" => "2026-09-09T06:58:10Z",
      "page_route" => "article"
    ))
    pair
  end
end
