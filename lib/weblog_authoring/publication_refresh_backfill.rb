# frozen_string_literal: true

require "aws-sdk-s3"

module WeblogAuthoring
  class PublicationRefreshBackfill
    LEGACY_ASSET_REFERENCE = %r{/static/authoring/assets/index-[^"'<>]+\.(?:js|css)}

    def self.call(database:, s3_client:, site_bucket:, dry_run: true, html_first: false)
      published_pages = database.list_pages
        .select { |page| page.status == "published" && !page.empty? }
        .sort_by(&:route)
      pages = published_pages.select do |page|
        html = s3_client.get_object(bucket: site_bucket, key: page.route).body.read
        html_first ? !html.include?('data-public-article="1"') : html.match?(LEGACY_ASSET_REFERENCE)
      rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
        html_first
      end

      pages.each { |page| database.request_publication_refresh(page.id) } unless dry_run

      {
        "mode" => dry_run ? "dry-run" : "apply",
        "scanned_count" => published_pages.length,
        "count" => pages.length,
        "pages" => pages.map { |page| { "id" => page.id, "route" => page.route } },
      }
    end
  end
end
