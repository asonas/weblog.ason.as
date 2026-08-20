# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/service"

require "fileutils"
require "tmpdir"

class TestService < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T12:00:00+09:00")

  def test_preview_does_not_create_source_or_index
    service = service_for

    rendered = service.preview(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "[[bad/name]]"
      )
    )

    assert rendered.problems.any? { |problem| problem.include?("page name contains a forbidden character") }
    refute tmpdir.join("content").exist?
    refute tmpdir.join("data").exist?
  end

  def test_save_draft_writes_source_without_changing_public_site
    service = service_for

    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        title: "今日",
        body: "本文"
      )
    )

    assert_equal "draft", page.status
    assert_equal "本文", service.repository.find_route("/2026-01-01").body
    refute tmpdir.join("site").exist?
    refute tmpdir.join("content/.authoring-release.json").exist?
  end

  def test_publish_build_failure_keeps_draft_and_previous_public_site
    site = tmpdir.join("site")
    site.mkpath
    site.join("marker").write("以前の公開版", encoding: "UTF-8")
    service = service_for(publisher: FailingBuildPublisher.new(site))
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "公開前の本文"
      )
    )

    error = assert_raises(WeblogAuthoring::PublishError) do
      service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))
    end

    assert_includes error.message, "simulated build failure"
    assert_equal "draft", service.repository.find_route("/2026-01-01").status
    assert_equal "公開前の本文", page.path.read(encoding: "UTF-8").split("---").last.strip
    assert_equal "以前の公開版", site.join("marker").read(encoding: "UTF-8")
    refute tmpdir.join("content/.authoring-release.json").exist?
  end

  def test_publish_promotes_draft_and_writes_site_and_release_manifest
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "公開本文"
      )
    )

    published = service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))

    assert_equal "published", published.status
    assert_equal FIXED_TIME, published.published_at
    assert_includes tmpdir.join("site/2026-01-01/index.html").read(encoding: "UTF-8"), "公開本文"
    assert service.publisher.release_manifest.path.exist?
    assert_equal [page.id], service.publisher.release_manifest.load.pages.map(&:id)
  end

  def test_publish_rejects_a_stale_updated_at
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "本文"
      )
    )

    error = assert_raises(WeblogAuthoring::ConflictError) do
      service.publish(
        WeblogAuthoring::PublishRequest.new(
          page_id: page.id,
          expected_updated_at: Time.iso8601("2025-12-31T12:00:00+09:00")
        )
      )
    end

    assert_includes error.message, "updated by another edit"
    assert_equal "draft", service.repository.find_route("/2026-01-01").status
  end

  def test_publish_swap_failure_restores_draft_and_previous_public_site
    site = tmpdir.join("site")
    site.mkpath
    site.join("marker").write("以前の公開版", encoding: "UTF-8")
    service = service_for(publisher: FailingSwapPublisher.new(site))
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "公開前の本文"
      )
    )

    error = assert_raises(WeblogAuthoring::PublishError) do
      service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))
    end

    assert_includes error.message, "simulated swap failure"
    restored = service.repository.find_route("/2026-01-01")
    assert_equal "draft", restored.status
    assert_equal "公開前の本文", restored.body
    assert_equal "以前の公開版", site.join("marker").read(encoding: "UTF-8")
    refute tmpdir.join("content/.authoring-release.json").exist?
  end

  def test_saving_published_page_updates_local_source_without_changing_public_site
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "公開版"
      )
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))

    saved = service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "date", page_id: page.id, body: "編集版")
    )

    assert_equal "published", saved.status
    assert_equal "編集版", saved.body
    public_html = tmpdir.join("site/2026-01-01/index.html").read(encoding: "UTF-8")
    assert_includes public_html, "公開版"
    refute_includes public_html, "編集版"
  end

  def test_republish_preserves_first_published_at
    times = [
      Time.iso8601("2026-01-01T12:00:00+09:00"),
      Time.iso8601("2026-01-01T12:01:00+09:00"),
      Time.iso8601("2026-01-01T12:02:00+09:00"),
      Time.iso8601("2026-01-01T12:03:00+09:00")
    ].each
    service = service_for(clock: -> { times.next })
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "公開版"
      )
    )
    first = service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))
    service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "date", page_id: page.id, body: "更新版")
    )

    republished = service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))

    assert_equal first.published_at, republished.published_at
    assert_operator republished.updated_at, :>, first.updated_at
  end

  def test_publishing_unrelated_page_rejects_corrupt_released_source
    service = service_for
    page_a = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "Aの公開版"
      )
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: page_a.id))
    page_b = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 2),
        body: "Bの公開版"
      )
    )
    page_a.path.write("---\nstatus: broken\n---\n壊れた本文\n", encoding: "UTF-8")
    site_before = Pathname.glob(tmpdir.join("site/**/*").to_s).select(&:file?).to_h do |path|
      [path, path.binread]
    end

    error = assert_raises(WeblogAuthoring::PublishError) do
      service.publish(WeblogAuthoring::PublishRequest.new(page_id: page_b.id))
    end

    assert_includes error.message, "released page"
    site_after = Pathname.glob(tmpdir.join("site/**/*").to_s).select(&:file?).to_h do |path|
      [path, path.binread]
    end
    assert_equal site_before, site_after
    refute tmpdir.join("site/2026-01-02").exist?
  end

  def test_unpublish_keeps_referenced_page_as_public_placeholder
    service = service_for
    source = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "[[page-a]]"
      )
    )
    target = service.repository.find_route("/page-a")
    refute_nil target
    service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "named", page_id: target.id, body: "非公開本文")
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: source.id))
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: target.id))

    unpublished = service.unpublish(target.id)

    assert_equal "draft", unpublished.status
    placeholder = tmpdir.join("site/page-a/index.html").read(encoding: "UTF-8")
    assert_includes placeholder, "まだ内容がありません"
    refute_includes placeholder, "非公開本文"
  end

  def test_published_rename_adds_redirect_but_draft_rename_does_not
    service = service_for
    published = service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "old-public", body: "本文")
    )
    draft = service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "old-draft", body: "本文")
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: published.id))

    renamed = service.rename(published.id, "new-public")
    service.rename(draft.id, "new-draft")

    assert_equal published.id, renamed.id
    redirect = tmpdir.join("site/old-public/index.html").read(encoding: "UTF-8")
    assert_includes redirect, "url=/new-public"
    refute tmpdir.join("site/old-draft").exist?
    assert_equal published.id, service.repository.find_route("/new-public").id
  end

  def test_published_rename_redirect_survives_restart_and_flattens
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "page-a", body: "本文")
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))
    service.rename(page.id, "page-b")
    service.rename(page.id, "page-c")

    restarted = service_for
    later = restarted.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 2),
        body: "後続公開"
      )
    )
    restarted.publish(WeblogAuthoring::PublishRequest.new(page_id: later.id))

    redirect_a = tmpdir.join("site/page-a/index.html").read(encoding: "UTF-8")
    redirect_b = tmpdir.join("site/page-b/index.html").read(encoding: "UTF-8")
    assert_includes redirect_a, "url=/page-c"
    assert_includes redirect_b, "url=/page-c"
    refute_includes redirect_a, "url=/page-b"
  end

  def test_failed_published_rename_restores_source_and_release_metadata
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(page_type: "named", name: "old-public", body: "本文")
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))
    metadata_before = tmpdir.join("content/.authoring-release.json").binread
    service.publisher = FailingBuildPublisher.new(tmpdir.join("site"))

    error = assert_raises(WeblogAuthoring::PublishError) do
      service.rename(page.id, "new-public")
    end

    assert_includes error.message, "simulated build failure"
    assert tmpdir.join("content/old-public.md").exist?
    refute tmpdir.join("content/new-public.md").exist?
    assert_equal metadata_before, tmpdir.join("content/.authoring-release.json").binread
  end

  def test_published_rename_updates_self_links_in_the_release_snapshot
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "named",
        name: "old-public",
        body: "[[old-public]]"
      )
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))

    service.rename(page.id, "new-public")

    public_html = tmpdir.join("site/new-public/index.html").read(encoding: "UTF-8")
    assert_includes public_html, 'href="/new-public"'
    refute_includes public_html, 'href="/old-public"'
  end

  def test_failed_unpublish_swap_restores_published_source_and_release_metadata
    service = service_for
    page = service.save_draft(
      WeblogAuthoring::SaveRequest.new(
        page_type: "date",
        page_date: Date.new(2026, 1, 1),
        body: "公開本文"
      )
    )
    service.publish(WeblogAuthoring::PublishRequest.new(page_id: page.id))
    metadata_before = tmpdir.join("content/.authoring-release.json").binread
    service.publisher = FailingSwapPublisher.new(tmpdir.join("site"))

    error = assert_raises(WeblogAuthoring::PublishError) do
      service.unpublish(page.id)
    end

    assert_includes error.message, "simulated swap failure"
    assert_equal "published", service.repository.find_route("/2026-01-01").status
    assert_equal metadata_before, tmpdir.join("content/.authoring-release.json").binread
  end

  private

  def service_for(clock: -> { FIXED_TIME }, publisher: nil)
    content_dir = tmpdir.join("content")
    repository = WeblogAuthoring::ContentRepository.new(
      content_dir,
      tmpdir.join("data/index/authoring.sqlite3"),
      clock
    )
    publisher ||= WeblogAuthoring::StaticPublisher.new(
      tmpdir.join("site"),
      release_manifest_path: content_dir.join(".authoring-release.json")
    )
    WeblogAuthoring::AuthoringService.new(repository, publisher, clock:)
  end

  def tmpdir
    @tmpdir ||= Pathname(Dir.mktmpdir("weblog-authoring-service"))
  end

  def teardown
    FileUtils.remove_entry(tmpdir.to_s) if defined?(@tmpdir) && tmpdir.exist?
  end

  class FailingBuildPublisher < WeblogAuthoring::StaticPublisher
    def build(_snapshot, _destination, release_snapshot:)
      raise WeblogAuthoring::PublishError, "simulated build failure"
    end
  end

  class FailingSwapPublisher < WeblogAuthoring::StaticPublisher
    def swap(_destination)
      raise WeblogAuthoring::PublishError, "simulated swap failure"
    end
  end
end
