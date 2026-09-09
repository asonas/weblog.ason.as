# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestBuildArticleComparisonPair < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  COMMAND = ROOT.join("bin/build-article-comparison-pair")
  FIXTURE = ROOT.join("test/fixtures/article_comparison/rubykaigi-follow-up.json")

  def test_builds_two_sites_from_fixed_commits
    commit = git("rev-parse", "HEAD").strip
    Dir.mktmpdir do |directory|
      output = Pathname(directory).join("comparison")
      stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--baseline", commit,
        "--candidate", commit,
        "--fixture", FIXTURE.to_s,
        "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      assert_includes stdout, "Built comparison pair"
      assert output.join("baseline/RubyKaigi 2026 follow upで登壇してきた").file?
      assert output.join("candidate/RubyKaigi 2026 follow upで登壇してきた").file?
      manifest = JSON.parse(output.join("manifest.json").read)
      assert_equal commit, manifest.fetch("baseline_commit")
      assert_equal commit, manifest.fetch("candidate_commit")
      assert_equal "rubykaigi-2026-follow-up", manifest.fetch("fixture_id")
      assert_equal "RubyKaigi 2026 follow upで登壇してきた", manifest.fetch("page_route")
    end
  end

  def test_fails_when_a_commit_cannot_be_resolved
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--baseline", "missing-comparison-ref",
        "--candidate", "HEAD",
        "--fixture", FIXTURE.to_s,
        "--output", Pathname(directory).join("comparison").to_s,
        chdir: ROOT.to_s
      )

      refute status.success?
      assert_includes stderr, "Cannot resolve commit: missing-comparison-ref"
    end
  end

  private

  def git(*arguments)
    output, status = Open3.capture2("git", *arguments, chdir: ROOT.to_s)
    raise output unless status.success?

    output
  end
end
