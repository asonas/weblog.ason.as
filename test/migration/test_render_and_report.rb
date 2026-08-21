# frozen_string_literal: true

require_relative "../test_helper"

class RenderAndReportMigrationTest < Minitest::Test
  FIXTURE = Pathname(__dir__).join("../fixtures/scrapbox/minimal.json").expand_path

  def snapshot
    root = Pathname(Dir.mktmpdir)
    project = WeblogMigration::Scrapbox.load_export(FIXTURE)
    normalized = WeblogMigration::Normalize.normalize_project(project, root.join("normalized"))
    index = WeblogMigration::Index.build_index(normalized, root.join("index", "log.sqlite3"))
    [root, project, normalized, index]
  end

  def test_render_site_keeps_public_date_pages_cards_and_assets
    root, _project, normalized, index = snapshot
    private_post = normalized.posts.first
    private_post = WeblogMigration::NormalizedPost.new(
      id: "private-post", frontmatter: private_post.frontmatter.merge("id" => "private-post", "visibility" => "private"),
      body: private_post.body, links: private_post.links, asset_references: private_post.asset_references,
      external_urls: private_post.external_urls, issues: private_post.issues
    )
    undated_post = WeblogMigration::NormalizedPost.new(
      id: "undated-post", frontmatter: normalized.posts.first.frontmatter.merge("id" => "undated-post", "created_at" => nil),
      body: normalized.posts.first.body, links: normalized.posts.first.links, asset_references: normalized.posts.first.asset_references,
      external_urls: normalized.posts.first.external_urls, issues: normalized.posts.first.issues
    )
    combined = WeblogMigration::NormalizationResult.new(posts: normalized.posts + [private_post, undated_post], mapping: normalized.mapping, issues: normalized.issues)
    site = root.join("site")
    WeblogMigration::Render.render_site(combined, index, site)
    html = site.join("2024-08-01", "index.html").read
    data = JSON.parse(site.join("static", "cards-data.json").read)

    assert_operator html.index('data-post-id="post_042cbe1a3c44d285"'), :<, html.index('data-post-id="post_8b37dc86ebcff5dd"')
    refute_includes html, "private-post"
    assert_includes html, "card--expanded"
    assert_includes html, "asset_"
    assert_includes html, "photo.jpg"
    assert site.join("undated", "index.html").read.include?("data-post-id=\"undated-post\"")
    assert_equal 1, data.fetch("version")
    refute data.fetch("posts").any? { |post| post["id"] == "private-post" }
    assert data.fetch("posts").any? { |post| post["id"] == "undated-post" }
  end

  def test_card_view_deduplicates_nodes_and_exposes_controls
    _root, _project, normalized, index = snapshot
    root_id = WeblogMigration::Normalize.stable_post_id("asonas-memo", "A")
    html = WeblogMigration::Render.render_cards(normalized, index, root_id:, range_name: "7d", depth: 2)
    assert_equal 1, html.scan('data-post-id="post_8b37dc86ebcff5dd"').length
    assert_equal 1, html.scan('data-asset-id="asset_aff6100bd4df0ea6"').length
    assert_includes html, 'data-card-data-url="/static/cards-data.json"'
    assert_includes html, 'data-range="7d"'
    assert_includes html, 'data-depth-option="3"'
  end

  def test_report_counts_unresolved_and_missing_assets
    root = Pathname(Dir.mktmpdir)
    payload = JSON.parse(FIXTURE.read)
    payload["pages"].first["lines"] << { "text" => "[missing-page]" }
    input = root.join("export.json")
    input.write(JSON.generate(payload))
    project = WeblogMigration::Scrapbox.load_export(input)
    normalized = WeblogMigration::Normalize.normalize_project(project, root.join("normalized"))
    index_path = root.join("index", "log.sqlite3")
    index = WeblogMigration::Index.build_index(normalized, index_path)
    report = WeblogMigration::Report.build_report(input, project, normalized, index_path:, site_path: root.join("site"))
    assert_equal 1, report["unresolved_links"]
    assert_equal ["photo.jpg"], report["missing_asset_paths"]
    assert_equal 1, report["missing_assets"]
    assert_equal 64, report["input_sha256"].length
    WeblogMigration::Report.write_reports(root.join("report"), input, project, normalized, index_path:, site_path: root.join("site"))
    assert root.join("report", "migration-report.json").file?
    assert root.join("report", "migration-report.md").file?
  end
end
