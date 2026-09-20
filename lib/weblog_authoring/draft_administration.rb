# frozen_string_literal: true

require_relative "draft_store"

module WeblogAuthoring
  class DraftAdministration
    def initialize(store:, publication:)
      @store = store
      @publication = publication
    end

    def daily(date)
      raise DraftStore::Error, "日付はYYYY-MM-DDで指定してください。" unless date.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(date)
      Date.iso8601(date)
      { "id" => @store.daily_draft(date) }
    rescue ArgumentError
      raise DraftStore::Error, "正しい日付を指定してください。"
    end

    def list(query: "", cursor: "")
      rows = @store.administration_page(cursor)
      needle = query.to_s.downcase
      articles = rows.filter_map do |row|
        metadata = row.fetch("metadata").transform_values { |field| field.fetch("value") }
        next unless [metadata.fetch("title"), row["public_route"]].compact.any? { |value| value.downcase.include?(needle) }
        state = "draft"
        error = nil
        if row["public_hash"]
          begin
            working = @publication.working_content_hash(row.fetch("id"))
            raise DraftStore::Error.new("一覧の取得中に更新されました。再読み込みしてください。", 409) unless working.fetch("through") == row.fetch("head")
            state = working.fetch("content_hash") == row.fetch("public_hash") ? "public" : "unpublished_changes"
          rescue DraftStore::Error => failure
            state = failure.status == 422 ? "unpublished_changes" : "unknown"
            error = failure.message
          end
        end
        publication = row["latest_id"] && @store.publication_job(row.fetch("id"), row.fetch("latest_id"))
        publication = publication.merge("stages" => @store.publication_stages(row.fetch("id"), row.fetch("latest_id"))) if publication
        row.slice("id", "head", "created_at", "updated_at", "public_route", "public_hash").merge("metadata" => metadata, "state" => state, "state_error" => error, "publication" => publication)
      end
      { "articles" => articles, "cursor" => rows.length == 25 ? rows.last.fetch("id") : nil }
    end
  end
end
