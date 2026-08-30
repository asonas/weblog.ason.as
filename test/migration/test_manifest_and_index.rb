# frozen_string_literal: true

require_relative "../test_helper"

class ManifestAndIndexMigrationTest < Minitest::Test
  def external_result(*groups)
    posts = groups.each_with_index.map do |urls, index|
      WeblogMigration::NormalizedPost.new(
        id: "post-#{("a".ord + index).chr}",
        frontmatter: {
          "title" => "Post #{index}", "source_project" => "memo", "created_at" => nil,
          "updated_at" => nil, "published_at" => nil, "visibility" => "public",
        },
        body: "", links: [], asset_references: [], external_urls: urls, issues: []
      )
    end
    WeblogMigration::NormalizationResult.new(posts:, mapping: {}, issues: [])
  end

  def test_manifest_deduplicates_canonical_urls_and_classifies_media
    normalized = external_result(["https://gyazo.com/abc#top"], ["https://gyazo.com/abc", "https://example.test/voice.mp3"])
    entries = WeblogMigration::AssetManifest.build_asset_manifest(normalized)
    assert_equal 2, entries.length
    gyazo = entries.find { |entry| entry.url == "https://gyazo.com/abc" }
    assert_equal "image", gyazo.kind
    assert_equal %w[post-a post-b], gyazo.source_post_ids
    assert_equal "https://example.test/image.png", WeblogMigration::AssetManifest.canonicalize_url("HTTPS://EXAMPLE.TEST/image.png#top")
    assert_equal "audio", WeblogMigration::AssetManifest.classify_url("https://example.test/voice.mp3")
    assert_equal "video", WeblogMigration::AssetManifest.classify_url("https://example.test/movie.webm")
  end

  def test_index_backlinks_neighbors_and_rebuild_are_deterministic
    fixture = Pathname(__dir__).join("../fixtures/scrapbox/minimal.json").expand_path
    project = WeblogMigration::Scrapbox.load_export(fixture)
    root = Pathname(Dir.mktmpdir)
    normalized = WeblogMigration::Normalize.normalize_project(project, root.join("normalized"))
    first = WeblogMigration::Index.build_index(normalized, root.join("first.sqlite3"))
    second = WeblogMigration::Index.build_index(normalized, root.join("second.sqlite3"))
    asset_id = WeblogMigration::AssetManifest.stable_asset_id("photo.jpg")
    post_a = WeblogMigration::Normalize.stable_post_id("asonas-memo", "A")
    post_b = WeblogMigration::Normalize.stable_post_id("asonas-memo", "B")

    assert_equal [post_a, post_b], first.find_backlinks(asset_id)
    assert_includes first.neighbors(post_a, depth: 1), post_b
    assert_includes first.neighbors(post_a, depth: 1), asset_id
    assert_equal [], first.neighbors(post_a, depth: 0)
    assert_equal first.find_backlinks(asset_id), second.find_backlinks(asset_id)
  end
end
