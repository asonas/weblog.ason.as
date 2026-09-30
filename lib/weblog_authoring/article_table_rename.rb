# frozen_string_literal: true

require "digest"
require "json"

module WeblogAuthoring
  class ArticleTableRename
    TABLES = {
      "draft_articles" => "articles",
      "draft_published_versions" => "article_published_versions",
      "draft_publication_jobs" => "article_publication_jobs",
      "draft_publication_heads" => "article_publication_heads",
      "draft_publication_receipts" => "article_publication_receipts",
      "draft_publication_routes" => "article_publication_routes",
      "draft_publication_clock" => "article_publication_clock",
      "draft_publication_stages" => "article_publication_stages",
      "draft_dispatches" => "article_publication_dispatches",
      "draft_output_heads" => "article_output_heads",
      "draft_html_outputs" => "article_html_outputs",
      "draft_atom_ids" => "article_atom_ids",
      "draft_webmention_requests" => "article_webmention_requests",
      "draft_route_reservations" => "article_route_reservations",
      "draft_redirects" => "article_redirects",
      "draft_rename_batches" => "article_rename_batches",
      "draft_rename_members" => "article_rename_members",
    }.freeze

    def initialize(db)
      @db = db
    end

    def status
      names = @db.table_names
      TABLES.map do |old, current|
        { "old" => old, "current" => current, "old_exists" => names.include?(old), "current_exists" => names.include?(current) }
      end
    end

    def require_current_schema!
      return unless status.any? { |row| row.fetch("old_exists") }

      raise "Article tables need an explicit rename; run bin/rename-article-tables before setup"
    end

    def snapshot
      status.to_h do |row|
        old, current = row.values_at("old", "current")
        raise "Ambiguous table state: #{old} / #{current}" if row.fetch("old_exists") == row.fetch("current_exists")

        [current, fingerprint(row.fetch("current_exists") ? current : old)]
      end
    end

    def rename!(direction:)
      raise ArgumentError, "Expected forward or reverse" unless %w[forward reverse].include?(direction)

      before = snapshot
      yield({ "event" => "before", "direction" => direction, "tables" => before }) if block_given?
      pairs = direction == "forward" ? TABLES.to_a : TABLES.to_a.reverse.map(&:reverse)
      pairs.each do |source, target|
        names = @db.table_names
        raise "Ambiguous table state: #{source} / #{target}" if names.include?(source) == names.include?(target)
        next if names.include?(target)

        yield({ "event" => "renaming", "source" => source, "target" => target }) if block_given?
        # DSQL permits only one DDL statement per transaction.
        @db.query("ALTER TABLE #{@db.prefix}#{source} RENAME TO #{target}")
        yield({ "event" => "renamed", "source" => source, "target" => target }) if block_given?
      end
      after = snapshot
      raise "Article table contents changed during rename" unless before == after

      yield({ "event" => "verified", "direction" => direction, "tables" => after }) if block_given?
      after
    end

    private

    def fingerprint(table)
      rows = @db.query("SELECT * FROM #{@db.prefix}#{table}").map { |row| JSON.generate(row.to_h.sort.to_h) }.sort
      { "rows" => rows.length, "sha256" => Digest::SHA256.hexdigest(JSON.generate(rows)) }
    end
  end
end
