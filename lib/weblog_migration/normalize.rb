# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "pathname"
require "time"

module WeblogMigration
  module Normalize
    LINK = /\[([^\[\]]+)\]/.freeze
    EXTERNAL_URL = %r{https?://[^\s<>\[\]\\"']+}.freeze

    module_function

    def stable_post_id(project, title)
      "post_#{Digest::SHA256.hexdigest("#{project}\0#{title}")[0, 16]}"
    end

    def normalize_page(page, link_map = nil)
      issues = []
      body = page.lines.map { |line| rewrite_links(line, page.title, link_map, issues) }.join("\n")
      post_id = stable_post_id(page.project, page.title)
      frontmatter = {
        "id" => post_id,
        "title" => page.title,
        "created_at" => format_datetime(page.created_at),
        "updated_at" => format_datetime(page.updated_at),
        "published_at" => nil,
        "visibility" => "public",
        "source_kind" => "scrapbox",
        "source_project" => page.project,
        "source_title" => page.title,
        "source_url" => page.source_url
      }

      NormalizedPost.new(
        id: post_id,
        frontmatter:,
        body:,
        links: page.links,
        asset_references: page.asset_references,
        external_urls: page.external_urls,
        issues:
      )
    end

    def normalize_project(project, output_dir)
      output_dir = Pathname(output_dir)
      posts_dir = output_dir.join("posts")
      FileUtils.mkdir_p(posts_dir)
      link_map = project.pages.to_h { |page| [page.title, stable_post_id(project.name, page.title)] }
      mapping = project.pages.to_h do |page|
        ["#{project.name}\0#{page.title}", stable_post_id(project.name, page.title)]
      end
      posts = project.pages.map { |page| normalize_page(page, link_map) }
      posts.each { |post| posts_dir.join("#{post.id}.md").write(serialize_post(post), encoding: "UTF-8") }
      output_dir.join("migration-map.json").write(JSON.pretty_generate(mapping.sort.to_h) + "\n", encoding: "UTF-8")
      NormalizationResult.new(posts:, mapping:, issues: posts.flat_map(&:issues))
    end

    def serialize_post(post)
      values = post.frontmatter.map { |key, value| "#{key}: #{yaml_value(value)}" }
      "---\n#{values.join("\n")}\n---\n\n#{post.body}\n"
    end

    def rewrite_links(line, source_title, link_map, issues)
      return line if link_map.nil?

      line.gsub(LINK) do |match|
        target_title = Regexp.last_match(1).strip
        next match if target_title.match?(EXTERNAL_URL)
        target_id = link_map[target_title]
        if target_id.nil?
          issues << NormalizationIssue.new(kind: "unresolved_link", source: source_title, detail: target_title)
          match
        else
          "[#{target_title}](/posts/#{target_id}/)"
        end
      end
    end

    def format_datetime(value)
      value.nil? ? nil : TimeFormat.iso8601(value)
    end

    def yaml_value(value)
      return "null" if value.nil?
      return JSON.generate(value) if value.is_a?(String)

      value.to_s
    end
  end
end
