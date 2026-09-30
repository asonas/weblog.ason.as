# frozen_string_literal: true

require "date"
require "time"
require "pathname"
require_relative "links"

module WeblogAuthoring
  class WikiLink < Struct.new(:name, :start, :end, keyword_init: true)
    def initialize(name:, start: 0, end: 0)
      super(name:, start:, end:) # steep:ignore UnexpectedKeywordArgument
      freeze
    end
  end

  class ArticleDocument < Struct.new(
    :id,
    :page_type,
    :name,
    :page_date,
    :title,
    :status,
    :created_at,
    :updated_at,
    :published_at,
    :path,
    :body,
    :pieces,
    :tags,
    :links,
    :cover_mode,
    :cover_image_url,
    keyword_init: true
  )
    def initialize(**attributes)
      attributes[:links] = Array(attributes[:links]).freeze # steep:ignore ArgumentTypeMismatch
      attributes[:cover_mode] ||= "auto"
      super(**attributes)
      freeze
    end

    def self.from_published_version(snapshot)
      return nil unless snapshot
      metadata = snapshot.fetch("metadata")
      ArticleDocument.new(id: snapshot.fetch("article_id"), page_type: metadata.fetch("page_type"),
        name: snapshot.fetch("route"), page_date: metadata.fetch("page_type") == "date" ? Date.iso8601(snapshot.fetch("route")) : nil,
        title: metadata.fetch("title"), status: "published", body: snapshot.fetch("body"),
        pieces: metadata.dig("content", "pieces"), tags: metadata.dig("content", "tags"),
        created_at: Time.iso8601(snapshot.fetch("article_created_at")),
        updated_at: Time.iso8601(snapshot.fetch("updated_at", snapshot.fetch("created_at"))),
        published_at: Time.iso8601(snapshot.fetch("published_at", snapshot.fetch("created_at"))),
        cover_mode: metadata.fetch("cover_mode"), cover_image_url: metadata["cover_image_url"],
        links: WeblogAuthoring.extract_wiki_links(snapshot.fetch("body")))
    end

    def display_title
      return name.to_s if page_type == "named"
      return title unless title.nil? || title.empty?

      page_date&.iso8601.to_s
    end

    def route
      page_type == "named" ? name.to_s : page_date&.iso8601.to_s
    end

    def empty?
      body.to_s.strip.empty?
    end
  end

  class PageProblem < Struct.new(:path, :detail, keyword_init: true)
    def initialize(path:, detail:)
      super(path: Pathname(path), detail:) # steep:ignore UnexpectedKeywordArgument
      freeze
    end
  end

  class Redirect < Struct.new(:old_route, :new_route, keyword_init: true)
    def initialize(old_route:, new_route:)
      super(old_route:, new_route:) # steep:ignore UnexpectedKeywordArgument
      freeze
    end
  end

  class InboxItem < Struct.new(
    :id, :source, :kind, :source_id, :occurred_at, :ingested_at,
    :expires_at, :payload, :created_at, :updated_at,
    keyword_init: true
  )
    def initialize(**attributes)
      attributes[:payload] = attributes.fetch(:payload).freeze
      super(**attributes)
      freeze
    end
  end

  class InboxImageAdoption < Struct.new(
    :item_id, :inbox_key, :public_key, :prepared_at, :committed_at, :expires_at,
    keyword_init: true
  )
    def initialize(**attributes)
      super(**attributes)
      freeze
    end
  end

  class InboxItemUsage < Struct.new(:item_id, :page_id, :page_route, :used_at, keyword_init: true)
    def initialize(**attributes)
      super(**attributes)
      freeze
    end
  end

  class ReleaseSnapshot < Struct.new(:pages, :redirects, :published_at, keyword_init: true)
    def initialize(pages: [], redirects: [], published_at: nil)
      super(pages: Array(pages).freeze, redirects: Array(redirects).freeze, published_at:) # steep:ignore UnexpectedKeywordArgument
      freeze
    end
  end

  class SaveRequest < Struct.new(
    :page_type,
    :body,
    :page_id,
    :name,
    :page_date,
    :title,
    :expected_updated_at,
    :consumed_inbox_item_ids,
    :cover_mode,
    :cover_image_url,
    keyword_init: true
  )
    def initialize(page_type:, body:, page_id: nil, name: nil, page_date: nil, title: nil, expected_updated_at: nil,
                   consumed_inbox_item_ids: [], cover_mode: nil, cover_image_url: nil)
      # steep:ignore:start
      super(
        page_type:,
        body:,
        page_id:,
        name:,
        page_date:,
        title:,
        expected_updated_at:,
        consumed_inbox_item_ids: Array(consumed_inbox_item_ids).freeze,
        cover_mode:,
        cover_image_url:
      )
      # steep:ignore:end
      freeze
    end
  end

  class PublishRequest < Struct.new(:page_id, :expected_updated_at, keyword_init: true)
    def initialize(page_id:, expected_updated_at: nil)
      super(page_id:, expected_updated_at:) # steep:ignore UnexpectedKeywordArgument
      freeze
    end
  end

  class ConflictError < StandardError
  end
end
