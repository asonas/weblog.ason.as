# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestHomeComparison < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  BUILD_COMMAND = ROOT.join("bin/build-article-comparison-site")
  FIXTURE = ROOT.join("test/fixtures/home_comparison/home.json")

  def test_builds_home_with_fixed_api_responses_and_images
    Dir.mktmpdir do |directory|
      output = Pathname(directory).join("site")
      stdout, stderr, status = Open3.capture3(
        BUILD_COMMAND.to_s, "--fixture", FIXTURE.to_s, "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      assert_includes stdout, "home-tags-and-images"
      assert output.join("index.html").file?
      assert_equal "home", JSON.parse(output.join("api/pages").read).fetch("mode")
      assert_equal "Ruby", JSON.parse(output.join("api/tags").read).fetch("tags").first
      assert output.join("assets/comparison/home-hero.webp").file?
      assert output.join("assets/previews/640/comparison/home-diary.webp.webp").file?
    end
  end

  def test_detects_widened_tags_through_the_production_frontend
    require_system_chrome

    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      candidate = extract_head(root)
      candidate.join("node_modules").make_symlink(ROOT.join("node_modules"))
      candidate.join("frontend/authoring/cardHome.css").open("a") do |css|
        css.puts(".card-home__tags a { inline-size: 320px !important; }")
      end
      pair = root.join("pair")
      build_site(ROOT, pair.join("baseline"))
      build_site(candidate, pair.join("candidate"))
      fixture = JSON.parse(FIXTURE.read)
      pair.join("manifest.json").write(JSON.generate(
        "baseline_commit" => capture!("git", "rev-parse", "HEAD").strip,
        "candidate_commit" => "intentional-tag-width-change",
        "fixture_id" => fixture.fetch("fixture_id"),
        "fixture_captured_at" => fixture.fetch("captured_at"),
        "page_route" => "",
        "scenario" => "home"
      ))
      capture = root.join("capture")
      capture!(ROOT.join("bin/capture-article-comparison").to_s, "--pair", pair.to_s, "--output", capture.to_s)
      report = root.join("report")
      capture!(ROOT.join("bin/report-article-comparison").to_s, "--capture", capture.to_s, "--output", report.to_s)

      comparisons = JSON.parse(report.join("manifest.json").read).fetch("comparisons")
      assert(comparisons.all? { |comparison| comparison.fetch("changed_pixels").positive? })
      assert_includes report.join("index.html").read, "トップページの比較"
    end
  end

  private

  def extract_head(root)
    archive = root.join("candidate.tar")
    source = root.join("candidate-source")
    source.mkpath
    capture!("git", "archive", "--format=tar", "--output", archive.to_s, "HEAD")
    capture!("tar", "-xf", archive.to_s, "-C", source.to_s)
    source
  end

  def build_site(source, output)
    capture!(BUILD_COMMAND.to_s, "--source-root", source.to_s, "--fixture", FIXTURE.to_s, "--output", output.to_s)
  end

  def capture!(*command)
    stdout, stderr, status = Open3.capture3(*command, chdir: ROOT.to_s)
    raise "#{command.first} failed:\n#{stderr}#{stdout}" unless status.success?

    stdout
  end
end
