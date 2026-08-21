# frozen_string_literal: true

require_relative "../test_helper"

class NormalizeMigrationTest < Minitest::Test
  FIXTURE = Pathname(__dir__).join("../fixtures/scrapbox/minimal.json").expand_path

  def test_post_id_is_stable_and_page_defaults_to_public
    first = WeblogMigration::Normalize.stable_post_id("asonas-memo", "A")
    second = WeblogMigration::Normalize.stable_post_id("asonas-memo", "A")
    assert_equal first, second
    assert_match(/\Apost_/, first)

    page = WeblogMigration::Scrapbox.load_export(FIXTURE).pages.first
    post = WeblogMigration::Normalize.normalize_page(page)
    assert_equal "public", post.frontmatter["visibility"]
    assert_equal "A", post.frontmatter["source_title"]
    assert_nil post.frontmatter["published_at"]
  end

  def test_normalize_rewrites_resolved_links_and_writes_mapping
    project = WeblogMigration::Scrapbox.load_export(FIXTURE)
    post = WeblogMigration::Normalize.normalize_page(
      project.pages.first,
      "B" => WeblogMigration::Normalize.stable_post_id("asonas-memo", "B")
    )
    assert_includes post.body, "[B](/posts/#{WeblogMigration::Normalize.stable_post_id("asonas-memo", "B")}/)"

    output = Pathname(Dir.mktmpdir)
    result = WeblogMigration::Normalize.normalize_project(project, output)
    assert output.join("posts", "#{post.id}.md").file?
    assert_match(/\Apost_/, result.mapping.fetch("asonas-memo\0A"))
  end
end
