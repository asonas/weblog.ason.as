# frozen_string_literal: true

require_relative "draft_publisher"

module WeblogAuthoring
  class DraftReader
    def initialize(store:, database:)
      @store = store
      @database = database
    end

    def find(id, timings: nil) # rubocop:disable Lint/UnusedMethodArgument
      DraftPublisher.page(@store.published_snapshot(id))
    end

    def find_route(route)
      DraftPublisher.page(@store.resolve_published_route(route)["snapshot"])
    end

    def list_pages(limit: nil, before: nil, after: nil, kind: nil, timings: nil) # rubocop:disable Lint/UnusedMethodArgument
      @store.published_pages(limit:, before:, after:, kind:).map { |snapshot| DraftPublisher.page(snapshot) }
    end

    def list_timeline_pages(limit:, before: nil, after: nil, month: nil)
      @store.published_timeline_pages(limit:, before:, after:, month:).map { |snapshot| DraftPublisher.page(snapshot) }
    end

    def list_diary_routes
      list_pages(kind: "diary").reject(&:empty?).map(&:route)
    end

    def find_image_dimensions(url)
      @database.find_image_dimensions(url)
    end

    def approved_webmentions_for_page(id)
      @database.approved_webmentions_for_page(id)
    end
  end
end
