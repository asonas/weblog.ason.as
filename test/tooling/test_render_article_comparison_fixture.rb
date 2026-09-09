# frozen_string_literal: true

require_relative "../test_helper"

require "open3"

class TestRenderArticleComparisonFixture < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  COMMAND = ROOT.join("bin/render-article-comparison-fixture")
  FIXTURE = ROOT.join("test/fixtures/article_comparison/rubykaigi-follow-up.json")

  def test_renders_a_fixed_article_through_the_publication_path
    Dir.mktmpdir do |directory|
      output = Pathname(directory).join("article.html")
      stdout, stderr, status = Open3.capture3(
        COMMAND.to_s,
        "--fixture", FIXTURE.to_s,
        "--shell", ROOT.join("public.html").to_s,
        "--output", output.to_s,
        chdir: ROOT.to_s
      )

      assert status.success?, stderr
      assert_equal "Rendered fixture rubykaigi-2026-follow-up to #{output}\n", stdout
      html = output.read
      assert_includes html, "RubyKaigi 2026 follow upで登壇してきた"
      assert_includes html, "実装してきたソフトウェアの楽器"
      assert_includes html, "/assets/comparison/rubykaigi-follow-up.webp"
      assert_includes html, "https://www.gakkihaku.jp/"
      assert_includes html, 'data-public-article="1"'
      refute_includes stderr, "Could not open library 'vips.42'"
    end
  end

  def test_fails_when_the_public_shell_is_missing
    _stdout, stderr, status = Open3.capture3(
      COMMAND.to_s,
      "--fixture", FIXTURE.to_s,
      "--shell", ROOT.join("missing-public.html").to_s,
      "--output", "/tmp/article.html",
      chdir: ROOT.to_s
    )

    refute status.success?
    assert_includes stderr, "Public shell not found"
  end
end
