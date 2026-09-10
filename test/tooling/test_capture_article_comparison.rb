# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestCaptureArticleComparison < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  COMMAND = ROOT.join("bin/capture-article-comparison")

  def test_captures_both_sites_at_mobile_and_desktop_widths
    require_system_chrome

    Dir.mktmpdir do |directory|
      pair = create_pair(Pathname(directory))
      output = Pathname(directory).join("capture")
      stdout, stderr, status = Open3.capture3(
        COMMAND.to_s, "--pair", pair.to_s, "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      assert_includes stdout, "Captured article comparison"
      %w[baseline candidate].product(%w[390 1568]).each do |revision, width|
        assert output.join("screenshots/#{revision}-#{width}.png").file?
      end
      manifest = JSON.parse(output.join("manifest.json").read)
      assert_equal "Google Chrome", manifest.dig("browser", "name")
      assert_match(/\A\d+\./, manifest.dig("browser", "version"))
      assert_equal [390, 1568], (manifest.fetch("viewports").map { |viewport| viewport.fetch("width") })
      assert_equal "2026-09-09T06:58:10.000Z", manifest.fetch("fixed_time")
    end
  end

  def test_fails_when_an_article_image_cannot_be_loaded
    require_system_chrome

    Dir.mktmpdir do |directory|
      pair = create_pair(Pathname(directory), image_path: "/assets/missing.svg")
      _stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--pair", pair.to_s,
        "--output", Pathname(directory).join("capture").to_s,
        chdir: ROOT.to_s
      )

      refute status.success?
      assert_includes stderr, "Article media failed to load"
    end
  end

  def test_fails_when_a_required_stylesheet_cannot_be_loaded
    require_system_chrome

    Dir.mktmpdir do |directory|
      pair = create_pair(Pathname(directory), stylesheet: "/assets/missing.css")
      _stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--pair", pair.to_s,
        "--output", Pathname(directory).join("capture").to_s,
        chdir: ROOT.to_s
      )

      refute status.success?
      assert_includes stderr, "Required page resource failed"
      assert_includes stderr, "/assets/missing.css"
    end
  end

  private

  def create_pair(root, image_path: "/assets/pixel.svg", stylesheet: nil)
    pair = root.join("pair")
    %w[baseline candidate].each do |revision|
      site = pair.join(revision)
      site.join("assets").mkpath
      site.join("article").write(<<~HTML)
        <!doctype html>
        <html><head><title>Fixture</title>#{%(<link rel="stylesheet" href="#{stylesheet}">) if stylesheet}</head>
        <body><article data-public-article="1"><h1>Fixture</h1><img src="#{image_path}" alt=""></article></body></html>
      HTML
      site.join("assets/pixel.svg").write(
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="teal"/></svg>'
      )
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
