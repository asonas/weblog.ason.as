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
      needle = query.to_s.downcase
      articles = []
      page_cursor = decode_cursor(cursor)
      last_scanned = nil
      has_more = false
      loop do
        rows = @store.administration_page(page_cursor)
        rows.first(25).each do |row|
          last_scanned = row
          article = article_row(row, needle)
          articles << article if article
          break if articles.length == 25
        end
        has_more = rows.length > 25
        break if articles.length == 25 || !has_more
        page_cursor = cursor_fields(rows.fetch(24))
      end
      { "articles" => articles, "cursor" => has_more && last_scanned ? encode_cursor(last_scanned) : nil }
    end

    private

    def article_row(row, needle)
      metadata = row.fetch("metadata").transform_values { |field| field.fetch("value") }
      return unless [metadata.fetch("title"), DraftStore.working_route(metadata), row["public_route"]].compact.any? { |value| value.downcase.include?(needle) }
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

    def decode_cursor(cursor)
      return nil if cursor.to_s.empty?
      values = JSON.parse(Base64.urlsafe_decode64(cursor))
      raise DraftStore::Error, "一覧のカーソルが正しくありません。" unless values.is_a?(Array) && values.length == 2 && values.all?(String)
      { "updated_at" => values.fetch(0), "id" => values.fetch(1) }
    rescue ArgumentError, JSON::ParserError
      raise DraftStore::Error, "一覧のカーソルが正しくありません。"
    end

    def encode_cursor(row)
      Base64.urlsafe_encode64(JSON.generate(cursor_fields(row).values), padding: false)
    end

    def cursor_fields(row)
      row.slice("updated_at", "id")
    end
  end
end
