# frozen_string_literal: true

require_relative "draft_publisher"
require_relative "home_timeline"

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
      pages = @store.published_collection.fetch("snapshots").map { |snapshot| DraftPublisher.page(snapshot) }
      if kind
        pages = pages.select { |page| page.links.any? { |link| link.name == "日記" } == (kind == "diary") }
      end
      select_window(pages, limit:, before:, after:) { |page| [kind == "diary" ? page.created_at : page.updated_at, page.id] }
    end

    def list_timeline_pages(limit:, before: nil, after: nil, month: nil)
      pages = list_pages
      pages = pages.select { |page| HomeTimeline.key(page).start_with?(month) } if month
      select_window(pages, limit:, before:, after:) { |page| [HomeTimeline.key(page), page.id] }
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

    private

    def select_window(pages, limit:, before:, after:)
      ordered = pages.sort_by { |page| yield page }
      cursor = before || after
      if cursor
        boundary = [cursor.fetch(:timestamp) { cursor.fetch(:key) }, cursor.fetch(:id)]
        ordered = ordered.select { |page| (yield(page) <=> boundary) == (before ? -1 : 1) }
      end
      ordered.reverse! unless after
      ordered = ordered.first(limit) if limit
      after ? ordered.reverse : ordered
    end
  end
end
