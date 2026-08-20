# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/publisher"

require "fileutils"
require "tmpdir"

class TestPublisher < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T00:00:00+09:00")

  def test_release_manifest_round_trips_and_preserves_redirects
    page = published_named_page("page-a", body: "公開本文")
    snapshot = WeblogAuthoring::ReleaseSnapshot.new(
      pages: [page],
      redirects: [
        WeblogAuthoring::Redirect.new(old_route: "old-a", new_route: "old-b"),
        WeblogAuthoring::Redirect.new(old_route: "old-b", new_route: "page-a")
      ],
      published_at: FIXED_TIME
    )
    manifest = WeblogAuthoring::ReleaseManifest.new(tmpdir.join("content/.authoring-release.json"))

    serialized = manifest.serialize(snapshot)
    manifest.path.dirname.mkpath
    manifest.path.write(serialized, encoding: "UTF-8")
    loaded = manifest.load

    assert_equal snapshot.pages, loaded.pages
    assert_equal(
      [
        WeblogAuthoring::Redirect.new(old_route: "old-a", new_route: "page-a"),
        WeblogAuthoring::Redirect.new(old_route: "old-b", new_route: "page-a")
      ],
      loaded.redirects
    )
    assert_equal snapshot.published_at, loaded.published_at
  end

  def test_release_manifest_rejects_malformed_metadata
    manifest = WeblogAuthoring::ReleaseManifest.new(tmpdir.join("content/.authoring-release.json"))
    manifest.path.dirname.mkpath
    manifest.path.write("{\"version\":1,\"pages\":[],\"redirects\":[]}\n", encoding: "UTF-8")

    error = assert_raises(WeblogAuthoring::PublishError) { manifest.load }

    assert_includes error.message, "missing root key"
  end

  def test_release_manifest_rejects_missing_file
    manifest = WeblogAuthoring::ReleaseManifest.new(tmpdir.join("content/.authoring-release.json"))

    error = assert_raises(WeblogAuthoring::PublishError) { manifest.load }

    assert_includes error.message, "missing"
  end

  def test_build_uses_release_snapshot_body_for_existing_published_page
    published = published_date_page("2026-01-01", body: "未公開編集\n\n[[page-a]]")
    placeholder_source = draft_named_page("page-a", body: "下書き本文")
    release_snapshot = WeblogAuthoring::ReleaseSnapshot.new(
      pages: [published_date_page("2026-01-01", body: "旧公開本文")],
      redirects: [],
      published_at: FIXED_TIME
    )

    result = publisher.build(
      snapshot_for(pages: [published, placeholder_source]),
      tmpdir.join("site.staging"),
      release_snapshot:
    )

    public_html = tmpdir.join("site.staging/2026-01-01/index.html").read(encoding: "UTF-8")
    assert_includes public_html, "旧公開本文"
    refute_includes public_html, "未公開編集"
    assert_equal ["2026-01-01"], result.public_routes.sort
    assert_equal "未公開編集\n\n[[page-a]]", result.release_candidate.pages.fetch(0).body
    assert_equal FIXED_TIME, result.release_candidate.pages.fetch(0).published_at
  end

  def test_build_uses_current_body_and_placeholder_for_first_publish
    published = published_date_page("2026-01-01", body: "公開本文\n\n[[page-a]]")
    placeholder_source = draft_named_page("page-a", body: "下書き本文")

    result = publisher.build(
      snapshot_for(pages: [published, placeholder_source]),
      tmpdir.join("site.staging"),
      release_snapshot: WeblogAuthoring::ReleaseSnapshot.new
    )

    public_html = tmpdir.join("site.staging/2026-01-01/index.html").read(encoding: "UTF-8")
    placeholder_html = tmpdir.join("site.staging/page-a/index.html").read(encoding: "UTF-8")

    assert_includes public_html, "公開本文"
    assert_includes placeholder_html, "まだ内容がありません"
    assert_includes placeholder_html, "2026-01-01"
    refute_includes placeholder_html, "下書き本文"
    assert_equal ["2026-01-01", "page-a"], result.public_routes.sort
  end

  def test_build_published_rename_uses_released_body_at_new_route_and_redirects_old_route
    current_page = published_named_page("new-name", id: "renamed-page", body: "未公開の新本文")
    release_snapshot = WeblogAuthoring::ReleaseSnapshot.new(
      pages: [published_named_page("old-name", id: "renamed-page", body: "旧公開本文")],
      redirects: [],
      published_at: FIXED_TIME
    )

    result = publisher.build(
      snapshot_for(
        pages: [current_page],
        redirects: [WeblogAuthoring::Redirect.new(old_route: "old-name", new_route: "new-name")]
      ),
      tmpdir.join("site.staging"),
      release_snapshot:
    )

    new_route_html = tmpdir.join("site.staging/new-name/index.html").read(encoding: "UTF-8")
    old_route_html = tmpdir.join("site.staging/old-name/index.html").read(encoding: "UTF-8")

    assert_includes new_route_html, "旧公開本文"
    refute_includes new_route_html, "未公開の新本文"
    assert_includes old_route_html, "url=/new-name"
    assert_equal ["new-name", "old-name"], result.public_routes.sort
    assert_equal "未公開の新本文", result.release_candidate.pages.fetch(0).body
    assert_equal "new-name", result.release_candidate.pages.fetch(0).route
  end

  def test_build_does_not_output_draft_only_reference
    draft_source = draft_named_page("draft-source", body: "[[page-a]]")

    result = publisher.build(
      snapshot_for(pages: [draft_source]),
      tmpdir.join("site.staging"),
      release_snapshot: WeblogAuthoring::ReleaseSnapshot.new
    )

    assert_equal [], result.public_routes
    refute tmpdir.join("site.staging/page-a/index.html").exist?
  end

  def test_build_flattens_redirect_chain_and_skips_draft_only_redirect
    published = published_named_page("page-c")
    current_redirects = [
      WeblogAuthoring::Redirect.new(old_route: "page-b", new_route: "page-c"),
      WeblogAuthoring::Redirect.new(old_route: "draft-old", new_route: "draft-page")
    ]
    release_snapshot = WeblogAuthoring::ReleaseSnapshot.new(
      pages: [],
      redirects: [WeblogAuthoring::Redirect.new(old_route: "page-a", new_route: "page-b")],
      published_at: FIXED_TIME
    )

    result = publisher.build(
      snapshot_for(pages: [published], redirects: current_redirects),
      tmpdir.join("site.staging"),
      release_snapshot:
    )

    assert_includes tmpdir.join("site.staging/page-a/index.html").read(encoding: "UTF-8"), "url=/page-c"
    assert_includes tmpdir.join("site.staging/page-b/index.html").read(encoding: "UTF-8"), "url=/page-c"
    refute tmpdir.join("site.staging/draft-old/index.html").exist?
    assert_equal ["page-a", "page-b"], result.release_candidate.redirects.map(&:old_route).sort
  end

  def test_build_rejects_redirect_cycles_and_collisions
    published = published_named_page("page-c")
    cycle_snapshot = snapshot_for(
      pages: [published],
      redirects: [
        WeblogAuthoring::Redirect.new(old_route: "page-a", new_route: "page-b"),
        WeblogAuthoring::Redirect.new(old_route: "page-b", new_route: "page-a")
      ]
    )

    cycle_error = assert_raises(WeblogAuthoring::PublishError) do
      publisher.build(cycle_snapshot, tmpdir.join("cycle"), release_snapshot: WeblogAuthoring::ReleaseSnapshot.new)
    end
    assert_includes cycle_error.message, "cycle"

    collision_snapshot = snapshot_for(
      pages: [published, published_named_page("page-d")],
      redirects: [WeblogAuthoring::Redirect.new(old_route: "page-c", new_route: "page-d")]
    )

    collision_error = assert_raises(WeblogAuthoring::PublishError) do
      publisher.build(collision_snapshot, tmpdir.join("collision"), release_snapshot: WeblogAuthoring::ReleaseSnapshot.new)
    end
    assert_includes collision_error.message, "collides"
  end

  def test_build_rejects_public_source_problem
    published = published_named_page("page-a")
    problem = WeblogAuthoring::PageProblem.new(path: tmpdir.join("content/page-a.md"), detail: "broken frontmatter")

    error = assert_raises(WeblogAuthoring::PublishError) do
      publisher.build(
        snapshot_for(pages: [published], problems: [problem]),
        tmpdir.join("site.staging"),
        release_snapshot: WeblogAuthoring::ReleaseSnapshot.new
      )
    end

    assert_includes error.message, "page-a"
  end

  def test_build_ignores_draft_only_problem
    published = published_named_page("page-a")
    problem = WeblogAuthoring::PageProblem.new(path: tmpdir.join("content/draft-page.md"), detail: "broken frontmatter")

    result = publisher.build(
      snapshot_for(pages: [published], problems: [problem]),
      tmpdir.join("site.staging"),
      release_snapshot: WeblogAuthoring::ReleaseSnapshot.new
    )

    assert_equal ["page-a"], result.public_routes
    assert tmpdir.join("site.staging/page-a/index.html").exist?
  end

  def test_build_uses_case_distinguishing_output_route_encoding
    published = published_named_page("Page-A")

    result = publisher.build(
      snapshot_for(pages: [published]),
      tmpdir.join("site.staging"),
      release_snapshot: WeblogAuthoring::ReleaseSnapshot.new
    )

    assert_equal ["Page-A"], result.public_routes
    assert tmpdir.join("site.staging/%50age-%41/index.html").exist?
    refute tmpdir.join("site.staging/Page-A/index.html").exist?
  end

  def test_publish_keeps_existing_site_and_manifest_when_swap_fails
    published = published_named_page("page-a", body: "公開本文")
    site_dir = tmpdir.join("site")
    site_dir.mkpath
    site_dir.join("marker").write("before", encoding: "UTF-8")
    manifest_path = tmpdir.join("content/.authoring-release.json")
    manifest_path.dirname.mkpath
    manifest_path.write("before", encoding: "UTF-8")
    original_rename = File.method(:rename)
    publisher = publisher_for(site_dir)

    File.singleton_class.send(:define_method, :rename) do |source, destination|
      if Pathname(destination) == site_dir && Pathname(source).basename.to_s.start_with?("site.staging-")
        raise IOError, "simulated swap failure"
      end

      original_rename.call(source, destination)
    end

    error = assert_raises(WeblogAuthoring::PublishError) do
      publisher.publish(snapshot_for(pages: [published]), release_snapshot: WeblogAuthoring::ReleaseSnapshot.new)
    end

    assert_includes error.message, "simulated swap failure"
    assert_equal "before", site_dir.join("marker").read(encoding: "UTF-8")
    assert_equal "before", manifest_path.read(encoding: "UTF-8")
    assert_empty tmpdir.glob("site.staging-*")
    assert_empty tmpdir.glob("site.previous-*")
  ensure
    File.singleton_class.send(:define_method, :rename, original_rename) if defined?(original_rename) && original_rename
  end

  private

  def publisher
    @publisher ||= publisher_for(tmpdir.join("site"))
  end

  def publisher_for(path)
    WeblogAuthoring::StaticPublisher.new(path)
  end

  def snapshot_for(pages:, problems: [], redirects: [])
    WeblogAuthoring::RepositorySnapshot.new(pages:, problems:, redirects:)
  end

  def published_date_page(date_string, body: "")
    page_date = Date.iso8601(date_string)
    WeblogAuthoring::PageDocument.new(
      id: "date-#{date_string}",
      page_type: "date",
      name: nil,
      page_date:,
      title: nil,
      status: "published",
      created_at: FIXED_TIME,
      updated_at: FIXED_TIME,
      published_at: FIXED_TIME,
      path: tmpdir.join("content/#{date_string}.md"),
      body:,
      links: WeblogAuthoring.extract_wiki_links(body)
    )
  end

  def published_named_page(name, id: nil, body: "公開本文")
    WeblogAuthoring::PageDocument.new(
      id: id || "page-#{name}",
      page_type: "named",
      name:,
      page_date: nil,
      title: nil,
      status: "published",
      created_at: FIXED_TIME,
      updated_at: FIXED_TIME,
      published_at: FIXED_TIME,
      path: tmpdir.join("content/#{WeblogAuthoring.encoded_page_name(name)}.md"),
      body:,
      links: WeblogAuthoring.extract_wiki_links(body)
    )
  end

  def draft_named_page(name, body: "")
    WeblogAuthoring::PageDocument.new(
      id: "draft-#{name}",
      page_type: "named",
      name:,
      page_date: nil,
      title: nil,
      status: "draft",
      created_at: FIXED_TIME,
      updated_at: FIXED_TIME,
      published_at: nil,
      path: tmpdir.join("content/#{WeblogAuthoring.encoded_page_name(name)}.md"),
      body:,
      links: WeblogAuthoring.extract_wiki_links(body)
    )
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("weblog-authoring-publisher"))
  end
end
