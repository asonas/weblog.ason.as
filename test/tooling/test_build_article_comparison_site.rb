# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestBuildArticleComparisonSite < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  COMMAND = ROOT.join("bin/build-article-comparison-site")
  FIXTURE = ROOT.join("test/fixtures/article_comparison/rubykaigi-follow-up.json")

  def test_builds_an_isolated_publication_site
    Dir.mktmpdir do |directory|
      output = Pathname(directory).join("site")
      stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--fixture", FIXTURE.to_s,
        "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      assert_includes stdout, "Built comparison site rubykaigi-2026-follow-up"
      assert output.join("static/authoring/assets").directory?
      assert output.join("assets/comparison/rubykaigi-follow-up.webp").file?
      article = output.join("RubyKaigi 2026 follow upで登壇してきた")
      assert article.file?
      assert_includes article.read, "/static/authoring/assets/"
      assert_includes article.read, "/assets/comparison/rubykaigi-follow-up.webp"
    end
  end

  def test_fails_when_a_fixed_resource_is_missing
    Dir.mktmpdir do |directory|
      fixture = Pathname(directory).join("fixture.json")
      data = JSON.parse(FIXTURE.read)
      data.fetch("resources").first["source"] = "missing.webp"
      fixture.write(JSON.pretty_generate(data))

      _stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--fixture", fixture.to_s,
        "--output", Pathname(directory).join("site").to_s,
        chdir: ROOT.to_s
      )

      refute status.success?
      assert_includes stderr, "Fixed resource not found"
    end
  end
end
