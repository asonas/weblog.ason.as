# frozen_string_literal: true

require "cgi"
require "date"
require "erb"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"

require_relative "links"
require_relative "markdown"
require_relative "models"
require_relative "names"

module WeblogAuthoring
  class PublishError < StandardError
  end

  BuildResult = Struct.new(
    :destination,
    :release_candidate,
    :release_manifest_json,
    :public_routes,
    keyword_init: true
  ) do
    def initialize(destination:, release_candidate:, release_manifest_json:, public_routes:)
      super(
        destination: Pathname(destination),
        release_candidate:,
        release_manifest_json:,
        public_routes: Array(public_routes).freeze
      )
      freeze
    end
  end

  PublishResult = Struct.new(
    :site_path,
    :release_candidate,
    :release_manifest_json,
    :public_routes,
    keyword_init: true
  ) do
    def initialize(site_path:, release_candidate:, release_manifest_json:, public_routes:)
      super(
        site_path: Pathname(site_path),
        release_candidate:,
        release_manifest_json:,
        public_routes: Array(public_routes).freeze
      )
      freeze
    end
  end

  class ReleaseManifest
    VERSION = 1
    ROOT_KEYS = %w[version published_at pages redirects].freeze
    PAGE_KEYS = %w[
      id
      route
      page_type
      name
      page_date
      title
      status
      created_at
      updated_at
      published_at
      path
      body
    ].freeze

    attr_reader :path

    def initialize(path)
      @path = Pathname(path)
    end

    def load
      raise PublishError, "release manifest is missing: #{path}" unless path.exist?

      payload = JSON.parse(path.read(encoding: "UTF-8"))
      raise ArgumentError, "manifest root must be an object" unless payload.is_a?(Hash)

      validate_root(payload)
      normalize(
        ReleaseSnapshot.new(
          pages: load_pages(payload.fetch("pages")),
          redirects: load_redirects(payload.fetch("redirects")),
          published_at: parse_optional_time(payload.fetch("published_at"), "published_at")
        )
      )
    rescue JSON::ParserError => error
      raise PublishError, "release manifest is invalid JSON: #{error.message}"
    rescue ArgumentError, PublishError => error
      raise PublishError, "release manifest is invalid: #{error.message}"
    end

    def serialize(snapshot)
      normalized = normalize(snapshot)
      JSON.pretty_generate(
        {
          "version" => VERSION,
          "published_at" => normalized.published_at&.iso8601,
          "pages" => normalized.pages.map { |page| serialize_page(page) },
          "redirects" => normalized.redirects.map do |redirect|
            {
              "old_route" => redirect.old_route,
              "new_route" => redirect.new_route
            }
          end
        }
      ) + "\n"
    rescue ArgumentError, PublishError => error
      raise PublishError, "release manifest cannot be serialized: #{error.message}"
    end

    def normalize(snapshot)
      raise ArgumentError, "release snapshot must be a ReleaseSnapshot" unless snapshot.is_a?(ReleaseSnapshot)

      page_ids = {}
      page_routes = {}
      pages = snapshot.pages.map.with_index do |page, index|
        validate_release_page(page, index)
        raise ArgumentError, "duplicate release page id: #{page.id}" if page_ids.key?(page.id)
        raise ArgumentError, "duplicate release route: #{page.route}" if page_routes.key?(page.route)

        page_ids[page.id] = true
        page_routes[page.route] = true
        page
      end

      redirects = StaticPublisher.flatten_redirects(snapshot.redirects)
      redirects.each do |redirect|
        raise ArgumentError, "redirect collides with published route: #{redirect.old_route}" if page_routes.key?(redirect.old_route)
      end

      ReleaseSnapshot.new(pages:, redirects:, published_at: snapshot.published_at)
    end

    private

    def validate_root(payload)
      unknown_keys = payload.keys - ROOT_KEYS
      raise ArgumentError, "unknown root key: #{unknown_keys.sort.first}" unless unknown_keys.empty?

      missing_keys = ROOT_KEYS - payload.keys
      raise ArgumentError, "missing root key: #{missing_keys.sort.first}" unless missing_keys.empty?
      raise ArgumentError, "version must be #{VERSION}" unless payload["version"] == VERSION
      raise ArgumentError, "pages must be an array" unless payload["pages"].is_a?(Array)
      raise ArgumentError, "redirects must be an array" unless payload["redirects"].is_a?(Array)
    end

    def load_pages(entries)
      entries.map.with_index do |entry, index|
        raise ArgumentError, "page entry #{index} must be an object" unless entry.is_a?(Hash)

        unknown_keys = entry.keys - PAGE_KEYS
        raise ArgumentError, "page entry #{index} has unknown key: #{unknown_keys.sort.first}" unless unknown_keys.empty?

        missing_keys = PAGE_KEYS - entry.keys
        raise ArgumentError, "page entry #{index} is missing key: #{missing_keys.sort.first}" unless missing_keys.empty?

        page = PageDocument.new(
          id: require_string(entry["id"], "pages[#{index}].id"),
          page_type: require_string(entry["page_type"], "pages[#{index}].page_type"),
          name: entry["name"],
          page_date: parse_optional_date(entry["page_date"], "pages[#{index}].page_date"),
          title: entry["title"],
          status: require_string(entry["status"], "pages[#{index}].status"),
          created_at: parse_time(entry["created_at"], "pages[#{index}].created_at"),
          updated_at: parse_time(entry["updated_at"], "pages[#{index}].updated_at"),
          published_at: parse_optional_time(entry["published_at"], "pages[#{index}].published_at"),
          path: Pathname(require_string(entry["path"], "pages[#{index}].path")),
          body: require_string(entry["body"], "pages[#{index}].body"),
          links: WeblogAuthoring.extract_wiki_links(require_string(entry["body"], "pages[#{index}].body"))
        )
        serialized_route = require_string(entry["route"], "pages[#{index}].route")
        raise ArgumentError, "pages[#{index}].route does not match page data" unless page.route == serialized_route

        page
      end
    end

    def load_redirects(entries)
      entries.map.with_index do |entry, index|
        raise ArgumentError, "redirect entry #{index} must be an object" unless entry.is_a?(Hash)

        keys = entry.keys.sort
        raise ArgumentError, "redirect entry #{index} must only contain old_route/new_route" unless keys == %w[new_route old_route]

        Redirect.new(
          old_route: require_route(entry["old_route"], "redirects[#{index}].old_route"),
          new_route: require_route(entry["new_route"], "redirects[#{index}].new_route")
        )
      end
    end

    def validate_release_page(page, index)
      raise ArgumentError, "release snapshot page #{index} must be a PageDocument" unless page.is_a?(PageDocument)
      raise ArgumentError, "release snapshot pages must be published" unless page.status == "published"
      raise ArgumentError, "release snapshot pages require published_at" if page.published_at.nil?
      raise ArgumentError, "release snapshot page #{index} must have created_at" if page.created_at.nil?
      raise ArgumentError, "release snapshot page #{index} must have updated_at" if page.updated_at.nil?
      raise ArgumentError, "release snapshot page #{index} has unknown page_type" unless %w[date named].include?(page.page_type)

      if page.page_type == "named"
        normalized_name = WeblogAuthoring.validate_page_name(page.name.to_s)
        raise ArgumentError, "release snapshot page #{index} name must be normalized" unless normalized_name == page.name
        raise ArgumentError, "release snapshot page #{index} must not have page_date" unless page.page_date.nil?
      else
        raise ArgumentError, "release snapshot page #{index} requires page_date" unless page.page_date.instance_of?(Date)
        raise ArgumentError, "release snapshot page #{index} must not have name" unless page.name.nil?
      end
    end

    def serialize_page(page)
      {
        "id" => page.id,
        "route" => page.route,
        "page_type" => page.page_type,
        "name" => page.name,
        "page_date" => page.page_date&.iso8601,
        "title" => page.title,
        "status" => page.status,
        "created_at" => page.created_at.iso8601,
        "updated_at" => page.updated_at.iso8601,
        "published_at" => page.published_at&.iso8601,
        "path" => page.path.to_s,
        "body" => page.body
      }
    end

    def require_string(value, label)
      raise ArgumentError, "#{label} must be a string" unless value.is_a?(String)

      value
    end

    def require_route(value, label)
      route = require_string(value, label)
      raise ArgumentError, "#{label} must not be empty" if route.empty?
      raise ArgumentError, "#{label} must not start or end with /" if route.start_with?("/") || route.end_with?("/")

      route
    end

    def parse_time(value, label)
      raise ArgumentError, "#{label} must be an ISO8601 datetime string" unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      raise ArgumentError, "#{label} must be an ISO8601 datetime string"
    end

    def parse_optional_time(value, label)
      return nil if value.nil?

      parse_time(value, label)
    end

    def parse_optional_date(value, label)
      return nil if value.nil?
      raise ArgumentError, "#{label} must be an ISO8601 date string" unless value.is_a?(String)

      Date.iso8601(value)
    rescue ArgumentError
      raise ArgumentError, "#{label} must be an ISO8601 date string"
    end
  end

  class StaticPublisher
    TEMPLATE_PATH = Pathname(__dir__).join("../../templates/authoring/public.html").expand_path.freeze

    BuildPlan = Struct.new(
      :public_pages,
      :backlinks,
      :redirects,
      :release_candidate,
      :public_routes,
      keyword_init: true
    )

    class << self
      def flatten_redirects(redirects)
        normalized = Array(redirects).map do |redirect|
          raise PublishError, "redirect must be a Redirect" unless redirect.is_a?(Redirect)

          Redirect.new(
            old_route: normalize_route(redirect.old_route, "redirect old_route"),
            new_route: normalize_route(redirect.new_route, "redirect new_route")
          )
        end

        direct_targets = {}
        normalized.each do |redirect|
          if direct_targets.key?(redirect.old_route) && direct_targets[redirect.old_route] != redirect.new_route
            raise PublishError, "redirect collision detected for #{redirect.old_route}"
          end

          direct_targets[redirect.old_route] = redirect.new_route
        end

        normalized.map do |redirect|
          Redirect.new(
            old_route: redirect.old_route,
            new_route: resolve_redirect_target(redirect.old_route, direct_targets)
          )
        end.uniq
      end

      private

      def normalize_route(route, label)
        value = route.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
        raise PublishError, "#{label} must not be empty" if value.empty?

        value
      end

      def resolve_redirect_target(old_route, direct_targets)
        route = old_route
        visited = {}

        while direct_targets.key?(route)
          raise PublishError, "redirect cycle detected for #{old_route}" if visited.key?(route)

          visited[route] = true
          route = direct_targets.fetch(route)
        end

        route
      end
    end

    attr_reader :output_dir, :release_manifest

    def initialize(
      output_dir,
      template_path: TEMPLATE_PATH,
      release_manifest_path: Pathname("content/.authoring-release.json")
    )
      @output_dir = Pathname(output_dir)
      @template_path = Pathname(template_path)
      @release_manifest = ReleaseManifest.new(Pathname(release_manifest_path))
    end

    def build(snapshot, destination, release_snapshot:)
      destination_path = Pathname(destination)
      plan = build_plan(snapshot, release_snapshot:)
      renderer = MarkdownRenderer.new(pages: plan.public_pages)

      reset_destination(destination_path)
      plan.public_pages.each do |page|
        html = renderer.render_page(page, backlinks: plan.backlinks.fetch(page.route), mode: "public")
        write_page(destination_path, page.route, render_document(page.display_title, html))
      end

      plan.redirects.each do |redirect|
        write_page(destination_path, redirect.old_route, redirect_document(redirect.new_route))
      end

      BuildResult.new(
        destination: destination_path,
        release_candidate: plan.release_candidate,
        release_manifest_json: @release_manifest.serialize(plan.release_candidate),
        public_routes: plan.public_routes
      )
    rescue PublishError
      remove_path(destination_path) if defined?(destination_path) && destination_path.exist?
      raise
    rescue ArgumentError, TypeError, EncodingError, SystemCallError, IOError => error
      remove_path(destination_path) if defined?(destination_path) && destination_path.exist?
      raise PublishError, "public site build failed: #{error.message}"
    end

    def swap(destination)
      destination_path = Pathname(destination)
      previous_path = output_dir.dirname.join("#{output_dir.basename}.previous-#{SecureRandom.hex(8)}")

      begin
        File.rename(output_dir, previous_path) if output_dir.exist?
        File.rename(destination_path, output_dir)
      rescue SystemCallError, IOError => error
        begin
          File.rename(previous_path, output_dir) if previous_path.exist? && !output_dir.exist?
        rescue SystemCallError, IOError => restore_error
          raise PublishError, "public site swap failed: #{error.message}; restore failed: #{restore_error.message}"
        end

        raise PublishError, "public site swap failed: #{error.message}"
      ensure
        remove_path(destination_path) if destination_path.exist?
        remove_path(previous_path) if previous_path.exist?
      end
    end

    def publish(snapshot, release_snapshot:)
      staging_path = output_dir.dirname.join("#{output_dir.basename}.staging-#{SecureRandom.hex(8)}")
      build_result = build(snapshot, staging_path, release_snapshot:)
      swap(build_result.destination)

      PublishResult.new(
        site_path: output_dir,
        release_candidate: build_result.release_candidate,
        release_manifest_json: build_result.release_manifest_json,
        public_routes: build_result.public_routes
      )
    rescue PublishError
      remove_path(staging_path) if defined?(staging_path) && staging_path.exist?
      raise
    end

    private

    def flatten_redirects(redirects)
      self.class.flatten_redirects(redirects)
    end

    def build_plan(snapshot, release_snapshot:)
      validate_snapshot(snapshot)

      normalized_release = @release_manifest.normalize(release_snapshot)
      current_published_pages = snapshot.pages.select { |page| page.status == "published" }.sort_by(&:route)
      release_by_id = normalized_release.pages.each_with_object({}) { |page, pages| pages[page.id] = page }

      render_pages = current_published_pages.map do |page|
        previously_released = release_by_id[page.id]
        if previously_released
          validate_release_identity(page, previously_released)
          merge_released_page(page, previously_released)
        else
          refresh_links(page)
        end
      end

      release_candidate_pages = current_published_pages.map do |page|
        previously_released = release_by_id[page.id]
        published_at = previously_released&.published_at || page.published_at
        raise PublishError, "published page is missing published_at: #{page.route}" if published_at.nil?

        refresh_links(PageDocument.new(**page.to_h.merge(status: "published", published_at:)))
      end

      public_pages = build_public_pages(render_pages, snapshot.pages)
      backlinks = build_backlinks(public_pages, render_pages)
      redirects = build_public_redirects(snapshot.redirects, normalized_release.redirects, public_pages)

      validate_public_problems(snapshot, public_pages)
      validate_render_pages(render_pages, public_pages)

      BuildPlan.new(
        public_pages: public_pages.freeze,
        backlinks: backlinks.freeze,
        redirects: redirects.freeze,
        release_candidate: ReleaseSnapshot.new(
          pages: release_candidate_pages,
          redirects: redirects,
          published_at: normalized_release.published_at
        ),
        public_routes: (public_pages.map(&:route) + redirects.map(&:old_route)).uniq.freeze
      )
    end

    def validate_snapshot(snapshot)
      raise PublishError, "snapshot must be a RepositorySnapshot" unless snapshot.is_a?(RepositorySnapshot)
    end

    def validate_release_identity(current_page, released_page)
      raise PublishError, "release metadata mismatch for page #{current_page.id}" unless released_page.page_type == current_page.page_type
      raise PublishError, "release metadata mismatch for page #{current_page.id}" unless released_page.created_at == current_page.created_at
    end

    def merge_released_page(current_page, released_page)
      refresh_links(
        PageDocument.new(
          **current_page.to_h.merge(
            title: released_page.title,
            created_at: released_page.created_at,
            updated_at: released_page.updated_at,
            published_at: released_page.published_at,
            body: released_page.body
          )
        )
      )
    end

    def refresh_links(page)
      PageDocument.new(**page.to_h.merge(links: WeblogAuthoring.extract_wiki_links(page.body)))
    end

    def build_public_pages(render_pages, snapshot_pages)
      published_names = render_pages.each_with_object({}) do |page, names|
        names[page.name] = true if page.page_type == "named" && !page.name.nil?
      end
      source_pages_by_name = snapshot_pages.each_with_object({}) do |page, pages|
        pages[page.name] = page if page.page_type == "named" && !page.name.nil?
      end

      placeholders = {}
      render_pages.each do |page|
        page.links.each do |link|
          begin
            normalized_name = WeblogAuthoring.validate_page_name(link.name)
          rescue ArgumentError => error
            raise PublishError, "public page is invalid: #{page.route}: #{error.message}"
          end

          next if published_names.key?(normalized_name)
          next if placeholders.key?(normalized_name)

          placeholders[normalized_name] = build_placeholder_page(source_pages_by_name[normalized_name], normalized_name)
        end
      end

      (render_pages + placeholders.values).sort_by(&:route)
    end

    def build_placeholder_page(source_page, name)
      if source_page
        PageDocument.new(**source_page.to_h.merge(body: "", links: []))
      else
        zero_time = Time.at(0).utc
        PageDocument.new(
          id: "placeholder-#{name}",
          page_type: "named",
          name:,
          page_date: nil,
          title: nil,
          status: "draft",
          created_at: zero_time,
          updated_at: zero_time,
          published_at: nil,
          path: Pathname("content/#{WeblogAuthoring.encoded_page_name(name)}.md"),
          body: "",
          links: []
        )
      end
    end

    def build_backlinks(public_pages, render_pages)
      public_pages.each_with_object({}) do |page, backlinks|
        backlinks[page.route] = if page.name.nil?
                                  []
                                else
                                  render_pages.select { |source| source.links.any? { |link| link.name == page.name } }.sort_by(&:route)
                                end
      end
    end

    def build_public_redirects(current_redirects, released_redirects, public_pages)
      public_routes = public_pages.each_with_object({}) { |page, routes| routes[page.route] = true }
      flattened = flatten_redirects(Array(released_redirects) + Array(current_redirects))

      flattened.each do |redirect|
        raise PublishError, "redirect collides with public route: #{redirect.old_route}" if public_routes.key?(redirect.old_route)
      end

      flattened.select { |redirect| public_routes.key?(redirect.new_route) }
    end

    def validate_public_problems(snapshot, public_pages)
      public_routes = public_pages.each_with_object({}) { |page, routes| routes[page.route] = true }

      snapshot.problems.each do |problem|
        route = CGI.unescape(Pathname(problem.path).basename(".md").to_s)
        next unless public_routes.key?(route)

        raise PublishError, "public source is invalid for #{route}: #{problem.detail}"
      end
    end

    def validate_render_pages(render_pages, public_pages)
      renderer = MarkdownRenderer.new(pages: public_pages)

      render_pages.each do |page|
        rendered = renderer.render(page.body, mode: "public")
        next if rendered.problems.empty?

        raise PublishError, "public page is invalid: #{page.route}: #{rendered.problems.join('; ')}"
      end
    end

    def reset_destination(destination)
      remove_path(destination) if destination.exist?
      destination.mkpath
    rescue SystemCallError, IOError => error
      raise PublishError, "cannot prepare staging directory: #{error.message}"
    end

    def remove_path(path)
      FileUtils.rm_rf(path)
    end

    def write_page(destination, route, content)
      output_path = destination.join(encoded_route(route), "index.html")
      output_path.dirname.mkpath
      output_path.write(content, encoding: "UTF-8")
    rescue EncodingError, SystemCallError, IOError => error
      raise PublishError, "cannot write public page #{route}: #{error.message}"
    end

    def render_document(title, page_html)
      ERB.new(@template_path.read(encoding: "UTF-8")).result_with_hash(title:, page_html:)
    end

    def redirect_document(new_route)
      href = "/#{encoded_route(new_route)}"
      escaped = CGI.escapeHTML(href)
      <<~HTML
        <!doctype html>
        <html lang="ja">
          <head>
            <meta charset="utf-8">
            <meta http-equiv="refresh" content="0; url=#{escaped}">
            <link rel="canonical" href="#{escaped}">
            <title>Redirecting</title>
          </head>
          <body>
            <p><a href="#{escaped}">#{escaped}</a></p>
          </body>
        </html>
      HTML
    end

    def encoded_route(route)
      WeblogAuthoring.encoded_route(route)
    end
  end
end
