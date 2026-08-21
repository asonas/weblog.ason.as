# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"

require_relative "frontmatter"
require_relative "markdown"
require_relative "models"
require_relative "publisher"
require_relative "repository"

module WeblogAuthoring
  class AuthoringService
    attr_reader :repository, :publisher
    attr_writer :publisher

    def initialize(repository, publisher, clock:)
      @repository = repository
      @publisher = publisher
      @clock = clock
      @release_manifest = ReleaseManifest.new(repository.content_dir.join(".authoring-release.json"))
    end

    def save_draft(request)
      repository.save_draft(request)
    end

    def save_and_publish(request)
      saved = save_draft(request)
      publish(PublishRequest.new(page_id: saved.id, expected_updated_at: saved.updated_at))
    end

    def preview(request, mode: "local")
      MarkdownRenderer.new.render(request.body, mode:)
    end

    def today
      current_time.to_date
    end

    def daily_template
      date = today
      weekdays = %w[日曜日 月曜日 火曜日 水曜日 木曜日 金曜日 土曜日]
      {
        title: date.iso8601,
        body: "[[#{weekdays.fetch(date.wday)}]]\n[[#{date.strftime('%Y%m')}]] [[#{date.strftime('%m%d')}]] [[日記]]"
      }
    end

    def publish(request)
      snapshot = repository.refresh
      page = find_page(snapshot, request.page_id)
      validate_expected_update(page, request)
      release_snapshot = load_release_snapshot(snapshot)
      validate_release_sources(snapshot, release_snapshot)
      now = current_time
      published = replace_document(
        page,
        status: "published",
        updated_at: now,
        published_at: page.published_at || now
      )
      candidate = candidate_snapshot(snapshot, published, release_snapshot)
      release_for_build = remove_release_page(release_snapshot, page.id)
      publish_candidate(candidate, release_for_build, published)
      repository.find_route(page.route) || published
    end

    def unpublish(page_id)
      snapshot = repository.refresh
      page = find_page(snapshot, page_id)
      unless page.status == "published"
        raise ConflictError, "only published pages can be unpublished"
      end

      release_snapshot = load_release_snapshot(snapshot)
      validate_release_sources(snapshot, release_snapshot)
      draft = replace_document(page, status: "draft", updated_at: current_time)
      candidate = candidate_snapshot(snapshot, draft, release_snapshot)
      publish_candidate(candidate, release_snapshot, draft)
      repository.find_route(page.route) || draft
    end

    def rename(page_id, new_name)
      snapshot = repository.refresh
      unless snapshot.problems.empty?
        raise ConflictError, "cannot rename while source documents have problems"
      end

      page = find_page(snapshot, page_id)
      release_snapshot = if page.status == "published"
                           loaded = load_release_snapshot(snapshot)
                           validate_release_sources(snapshot, loaded)
                           loaded
                         end
      source_before = source_files if page.status == "published"
      renamed = repository.rename_named_page(page_id, new_name)
      return renamed if page.status != "published" || renamed.route == page.route

      after_rename = repository.refresh
      renamed_release = rename_release_snapshot(release_snapshot, page, renamed)
      redirect = Redirect.new(old_route: page.route, new_route: renamed.route)
      release_after_rename = ReleaseSnapshot.new(
        pages: renamed_release.pages,
        redirects: StaticPublisher.flatten_redirects(renamed_release.redirects + [redirect]),
        published_at: renamed_release.published_at
      )
      candidate = release_candidate_snapshot(after_rename, release_after_rename)
      publish_candidate(candidate, release_after_rename, nil, source_before:)
      repository.find_route(renamed.route) || renamed
    rescue ConflictError, PublishError, ArgumentError, FileTransactionError, SystemCallError, IOError
      restore_source_files(source_before) if defined?(source_before) && source_before
      repository.refresh if defined?(source_before) && source_before
      raise
    end

    private

    def find_page(snapshot, page_id)
      page = snapshot.pages.find { |candidate| candidate.id == page_id }
      raise ConflictError, "page does not exist: #{page_id}" if page.nil?

      page
    end

    def validate_expected_update(page, request)
      return if request.expected_updated_at.nil? || request.expected_updated_at == page.updated_at

      raise ConflictError, "page was updated by another edit"
    end

    def current_time
      value = @clock.call
      raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

      value.getlocal(TOKYO_OFFSET)
    end

    def load_release_snapshot(snapshot)
      return @release_manifest.load if @release_manifest.path.exist?
      return ReleaseSnapshot.new unless snapshot.pages.any? { |page| page.status == "published" }

      raise PublishError, "release manifest is missing: #{@release_manifest.path}"
    end

    def candidate_snapshot(snapshot, replacement, release_snapshot)
      released_by_id = release_snapshot.pages.each_with_object({}) do |page, pages|
        pages[page.id] = page
      end
      pages = snapshot.pages.map do |page|
        next replacement if page.id == replacement.id

        released_by_id.fetch(page.id, page)
      end
      RepositorySnapshot.new(
        pages:,
        problems: snapshot.problems,
        redirects: release_snapshot.redirects
      )
    end

    def release_candidate_snapshot(snapshot, release_snapshot)
      released_by_id = release_snapshot.pages.each_with_object({}) do |page, pages|
        pages[page.id] = page
      end
      RepositorySnapshot.new(
        pages: snapshot.pages.map { |page| released_by_id.fetch(page.id, page) },
        problems: snapshot.problems,
        redirects: release_snapshot.redirects
      )
    end

    def validate_release_sources(snapshot, release_snapshot)
      current_by_id = snapshot.pages.each_with_object({}) do |page, pages|
        pages[page.id] = page
      end
      problems_by_path = snapshot.problems.each_with_object({}) do |problem, problems|
        problems[problem.path] = problem
      end

      release_snapshot.pages.each do |released_page|
        problem = problems_by_path[released_page.path]
      unless problem.nil?
        raise PublishError, "released page is invalid: #{released_page.route}: #{problem.detail}"
      end

        current_page = current_by_id[released_page.id]
        raise PublishError, "released page is missing: #{released_page.route}" if current_page.nil?
        next if current_page.path == released_page.path

        raise PublishError, "released page path changed: #{released_page.route}"
      end
    end

    def remove_release_page(snapshot, page_id)
      ReleaseSnapshot.new(
        pages: snapshot.pages.reject { |page| page.id == page_id },
        redirects: snapshot.redirects,
        published_at: snapshot.published_at
      )
    end

    def rename_release_snapshot(snapshot, original, renamed)
      pages = snapshot.pages.map do |page|
        body = WeblogAuthoring.replace_wiki_links(
          page.body,
          old_name: original.name.to_s,
          new_name: renamed.name.to_s
        )
        changes = { body:, links: WeblogAuthoring.extract_wiki_links(body) }
        if page.id == original.id
          changes[:name] = renamed.name
          changes[:path] = renamed.path
        end
        PageDocument.new(**page.to_h.merge(changes))
      end
      ReleaseSnapshot.new(
        pages:,
        redirects: snapshot.redirects,
        published_at: snapshot.published_at
      )
    end

    def publish_candidate(snapshot, release_snapshot, replacement, source_before: nil)
      staging = repository.content_dir.dirname.join(
        "#{publisher.output_dir.basename}.staging-#{SecureRandom.hex(8)}"
      )
      source_before ||= source_files

      begin
        result = publisher.build(snapshot, staging, release_snapshot:)
        transaction = FileTransaction.new
        unless replacement.nil?
          transaction.write(replacement.path, WeblogAuthoring.serialize_document(replacement))
        end
        transaction.write(@release_manifest.path, result.release_manifest_json)
        transaction.commit

        begin
          publisher.swap(staging)
        rescue PublishError, FileTransactionError, SystemCallError, IOError
          restore_source_files(source_before)
          raise
        end
      rescue PublishError
        restore_source_files(source_before)
        remove_staging(staging)
        repository.refresh
        raise
      rescue ArgumentError, TypeError, FileTransactionError, SystemCallError, IOError => error
        restore_source_files(source_before)
        remove_staging(staging)
        repository.refresh
        raise PublishError, "could not publish page: #{error.message}"
      ensure
        remove_staging(staging)
      end

      repository.refresh
    end

    def source_files
      files = Pathname.glob(repository.content_dir.join("*.md").to_s).each_with_object({}) do |path, result|
        result[path] = path.binread
      end
      files[@release_manifest.path] = @release_manifest.path.binread if @release_manifest.path.exist?
      files
    end

    def restore_source_files(files)
      transaction = FileTransaction.new
      current_paths = Pathname.glob(repository.content_dir.join("*.md").to_s)
      current_paths << @release_manifest.path if @release_manifest.path.exist?
      current_paths.uniq.each do |path|
        transaction.delete(path) unless files.key?(path)
      end
      files.each { |path, content| transaction.write(path, content) }
      transaction.commit
    end

    def remove_staging(path)
      FileUtils.rm_rf(path) if path.exist?
    end

    def replace_document(document, **changes)
      PageDocument.new(**document.to_h.merge(changes))
    end
  end
end
