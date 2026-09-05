# frozen_string_literal: true

module WeblogAuthoring
  class PublicationRefreshBackfill
    def self.call(database:, dry_run: true)
      pages = database.list_pages
        .select { |page| page.status == "published" && !page.empty? }
        .sort_by(&:route)

      pages.each { |page| database.request_publication_refresh(page.id) } unless dry_run

      {
        "mode" => dry_run ? "dry-run" : "apply",
        "count" => pages.length,
        "pages" => pages.map { |page| { "id" => page.id, "route" => page.route } },
      }
    end
  end
end
