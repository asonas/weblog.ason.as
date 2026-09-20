# frozen_string_literal: true

require_relative "draft_store"

module WeblogAuthoring
  class DraftCutoverApi
    def initialize(store:, legacy:, published:)
      @store = store
      @legacy = legacy
      @published = published
    end

    def call(event)
      kind = operation_kind(event)
      if kind
        @store.with_cutover_operation(kind) { |phase| api_for(phase, publication: kind == "publication").call(event) }
      else
        api_for(@store.cutover_status.fetch("phase")).call(event)
      end
    rescue DraftStore::CutoverError => error
      { statusCode: error.status, headers: { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" },
        body: JSON.generate("code" => error.code, "error" => error.message), }
    end

    private

    def api_for(phase, publication: false)
      case phase
      when "legacy", "draining", "frozen" then @legacy
      when "preparing" then publication ? @published : @legacy
      when "verifying", "open", "paused" then @published
      else raise DraftStore::CutoverError.new("authoring_maintenance")
      end
    end

    def operation_kind(event)
      return "publication" if event["source"] == "aws.events" && event["detail-type"] == "Scheduled Event"
      method = event.dig("requestContext", "http", "method").to_s
      return nil if %w[GET HEAD OPTIONS].include?(method)
      path = event.fetch("rawPath", "")
      return "legacy_write" if path == "/api/rename" || path == "/api/authoring/pages" || path.start_with?("/api/authoring/pages/")
      return "draft_write" if path == "/api/authoring/drafts" || path.start_with?("/api/authoring/drafts/")
      nil
    end
  end
end
