# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "pathname"

module WeblogMigration
  module Report
    module_function

    def build_report(input_path, project, normalized, index_path:, site_path:, asset_root: nil, run_at: nil)
      input_path = Pathname(input_path)
      asset_root ||= input_path.dirname
      asset_paths = normalized.posts.flat_map(&:asset_references).uniq.sort
      missing_asset_paths = asset_paths.reject { |source_path| asset_root.join(source_path).file? }
      unresolved = normalized.issues.filter_map do |issue|
        next unless issue.kind == "unresolved_link"
        { "source" => issue.source, "target" => issue.detail }
      end
      resolved_links = normalized.posts.sum do |post|
        source_project = post.frontmatter.fetch("source_project").to_s
        post.links.count { |target| normalized.mapping.key?("#{source_project}\0#{target}") }
      end
      duplicate_titles = project.pages.group_by(&:title).filter_map { |title, pages| title if pages.length > 1 }.sort
      undated_posts = project.pages.filter_map { |page| page.title if page.created_at.nil? }.sort
      timestamp = run_at || Time.now.utc
      manifest = AssetManifest.build_asset_manifest(normalized)
      kind_counts = manifest.group_by(&:kind).transform_values(&:length)
      manifest_path = Pathname(index_path).dirname.dirname.join("asset-manifest.json")

      {
        "input_path" => input_path.to_s,
        "input_sha256" => Digest::SHA256.file(input_path.to_s).hexdigest,
        "run_at" => TimeFormat.iso8601(timestamp),
        "pages" => project.pages.length,
        "posts" => normalized.posts.length,
        "assets" => asset_paths.length + manifest.length,
        "local_assets" => asset_paths.length,
        "external_url_candidates" => manifest.length,
        "external_url_kind_counts" => kind_counts.sort.to_h,
        "resolved_internal_links" => resolved_links,
        "unresolved_links" => unresolved.length,
        "unresolved_link_details" => unresolved,
        "missing_assets" => missing_asset_paths.length,
        "missing_asset_paths" => missing_asset_paths,
        "duplicate_titles" => duplicate_titles,
        "undated_posts" => undated_posts,
        "invalid_dates" => [],
        "asset_manifest_path" => manifest_path.to_s,
        "output_paths" => { "index" => Pathname(index_path).to_s, "site" => Pathname(site_path).to_s }
      }
    end

    def write_reports(report_dir, input_path, project, normalized, index_path:, site_path:, asset_root: nil, run_at: nil)
      report_dir = Pathname(report_dir)
      FileUtils.mkdir_p(report_dir)
      report = build_report(input_path, project, normalized, index_path:, site_path:, asset_root:, run_at:)
      report_dir.join("migration-report.json").write(JSON.pretty_generate(report) + "\n", encoding: "UTF-8")
      report_dir.join("migration-report.md").write(markdown_report(report), encoding: "UTF-8")
      report
    end

    def markdown_report(report)
      lines = [
        "# Migration report", "",
        "- Input: `#{report["input_path"]}`",
        "- Input SHA-256: `#{report["input_sha256"]}`",
        "- Run at: `#{report["run_at"]}`",
        "- Pages: #{report["pages"]}", "- Posts: #{report["posts"]}",
        "- Assets: #{report["assets"]}",
        "- External URL candidates: #{report["external_url_candidates"]}",
        "- Resolved internal links: #{report["resolved_internal_links"]}",
        "- Unresolved links: #{report["unresolved_links"]}",
        "- Missing assets: #{report["missing_assets"]}", "",
        "## Unresolved links", ""
      ]
      details = report.fetch("unresolved_link_details")
      lines.concat(details.map { |item| "- `#{item["source"]}` -> `#{item["target"]}`" })
      lines << "- なし" if details.empty?
      lines.concat(["", "## Missing assets", ""])
      paths = report.fetch("missing_asset_paths")
      lines.concat(paths.map { |path| "- `#{path}`" })
      lines << "- なし" if paths.empty?
      lines.concat(["", "## Other checks", ""])
      lines << "- Duplicate titles: #{format_values(report["duplicate_titles"])}"
      lines << "- Undated posts: #{format_values(report["undated_posts"])}"
      lines << "- Invalid dates: #{format_values(report["invalid_dates"])}"
      lines.concat(["", "## Outputs", ""])
      report.fetch("output_paths").sort.each { |name, path| lines << "- #{name}: `#{path}`" }
      lines.join("\n") + "\n"
    end

    def format_values(values)
      values.empty? ? "なし" : values.map { |value| "`#{value}`" }.join(", ")
    end
  end
end
