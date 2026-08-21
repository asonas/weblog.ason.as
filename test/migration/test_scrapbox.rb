# frozen_string_literal: true

require_relative "../test_helper"

class ScrapboxMigrationTest < Minitest::Test
  FIXTURE = Pathname(__dir__).join("../fixtures/scrapbox/minimal.json").expand_path

  def test_load_export_preserves_titles_lines_and_source_references
    project = WeblogMigration::Scrapbox.load_export(FIXTURE)

    assert_equal "asonas-memo", project.name
    assert_equal %w[A B], project.pages.map(&:title)
    assert_equal ["本文", "[B]"], project.pages.first.lines
    assert_equal ["B"], project.pages.first.links
    assert_equal ["photo.jpg"], project.pages.first.asset_references
  end

  def test_load_export_separates_external_urls_from_page_links
    path = Pathname(Dir.mktmpdir).join("export.json")
    path.write(JSON.generate(
      "projectName" => "memo",
      "pages" => [
        { "title" => "A", "lines" => [{ "text" => "[B]" }, { "text" => "[https://gyazo.com/abc image] https://gyazo.com/abc" }, { "text" => "[missing]" }] },
        { "title" => "B", "lines" => [] }
      ]
    ))

    page = WeblogMigration::Scrapbox.load_export(path).pages.first
    assert_equal %w[B missing], page.links
    assert_equal ["https://gyazo.com/abc"], page.external_urls
  end
end
