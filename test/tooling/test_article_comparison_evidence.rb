# frozen_string_literal: true

require_relative "../test_helper"

require "fileutils"
require "open3"

class TestArticleComparisonEvidence < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  FIXTURE = ROOT.join("test/fixtures/article_comparison/rubykaigi-follow-up.json")

  def test_detects_an_article_layout_change_through_the_publication_path
    require_system_chrome

    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      candidate_source = extract_head(root)
      candidate_source.join("node_modules").make_symlink(ROOT.join("node_modules"))
      candidate_source.join("frontend/authoring/publicArticle.css").open("a") do |css|
        css.puts(".public-article-body { font-size: 24px !important; }")
      end
      pair = root.join("pair")
      build_site(ROOT, pair.join("baseline"))
      build_site(candidate_source, pair.join("candidate"))
      fixture = JSON.parse(FIXTURE.read)
      commit = capture!("git", "rev-parse", "HEAD", chdir: ROOT).strip
      pair.join("manifest.json").write(JSON.generate(
        "baseline_commit" => commit,
        "candidate_commit" => "intentional-layout-change",
        "fixture_id" => fixture.fetch("fixture_id"),
        "fixture_captured_at" => fixture.fetch("captured_at"),
        "page_route" => fixture.fetch("page").fetch("name")
      ))

      capture = root.join("capture")
      capture!(
        ROOT.join("bin/capture-article-comparison").to_s,
        "--pair", pair.to_s,
        "--output", capture.to_s
      )
      report = root.join("report")
      capture!(
        ROOT.join("bin/report-article-comparison").to_s,
        "--capture", capture.to_s,
        "--output", report.to_s
      )

      comparisons = JSON.parse(report.join("manifest.json").read).fetch("comparisons")
      assert(comparisons.all? { |comparison| comparison.fetch("changed_pixels").positive? })
      assert_includes report.join("index.html").read, "差分あり"
    end
  end

  private

  def extract_head(root)
    archive = root.join("candidate.tar")
    source = root.join("candidate-source")
    source.mkpath
    capture!("git", "archive", "--format=tar", "--output", archive.to_s, "HEAD", chdir: ROOT)
    capture!("tar", "-xf", archive.to_s, "-C", source.to_s, chdir: ROOT)
    source
  end

  def build_site(source, output)
    capture!(
      ROOT.join("bin/build-article-comparison-site").to_s,
      "--source-root", source.to_s,
      "--fixture", FIXTURE.to_s,
      "--output", output.to_s
    )
  end

  def capture!(*command, chdir: ROOT)
    stdout, stderr, status = Open3.capture3(*command, chdir: chdir.to_s)
    raise "#{command.first} failed:\n#{stderr}#{stdout}" unless status.success?

    stdout
  end
end
