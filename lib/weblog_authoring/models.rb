# frozen_string_literal: true

require "date"
require "pathname"

module WeblogAuthoring
  WikiLink = Struct.new(:name, :start, :end, keyword_init: true) do
    def initialize(name:, start: 0, end: 0)
      super(name:, start:, end:)
      freeze
    end
  end

  PageDocument = Struct.new(
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
    :links,
    keyword_init: true
  ) do
    def initialize(**attributes)
      attributes[:links] = Array(attributes[:links]).freeze
      super(**attributes)
      freeze
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

  PageProblem = Struct.new(:path, :detail, keyword_init: true) do
    def initialize(path:, detail:)
      super(path: Pathname(path), detail:)
      freeze
    end
  end

  Redirect = Struct.new(:old_route, :new_route, keyword_init: true) do
    def initialize(old_route:, new_route:)
      super(old_route:, new_route:)
      freeze
    end
  end

  InboxItem = Struct.new(
    :id, :source, :kind, :source_id, :occurred_at, :ingested_at,
    :expires_at, :payload, :created_at, :updated_at,
    keyword_init: true
  ) do
    def initialize(**attributes)
      attributes[:payload] = attributes.fetch(:payload).freeze
      super(**attributes)
      freeze
    end
  end

  InboxImageAdoption = Struct.new(
    :item_id, :inbox_key, :public_key, :prepared_at, :committed_at, :expires_at,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super(**attributes)
      freeze
    end
  end

  ReleaseSnapshot = Struct.new(:pages, :redirects, :published_at, keyword_init: true) do
    def initialize(pages: [], redirects: [], published_at: nil)
      super(pages: Array(pages).freeze, redirects: Array(redirects).freeze, published_at:)
      freeze
    end
  end

  SaveRequest = Struct.new(
    :page_type,
    :body,
    :page_id,
    :name,
    :page_date,
    :title,
    :expected_updated_at,
    :consumed_inbox_item_ids,
    keyword_init: true
  ) do
    def initialize(page_type:, body:, page_id: nil, name: nil, page_date: nil, title: nil, expected_updated_at: nil,
                   consumed_inbox_item_ids: [])
      super(
        page_type:,
        body:,
        page_id:,
        name:,
        page_date:,
        title:,
        expected_updated_at:,
        consumed_inbox_item_ids: Array(consumed_inbox_item_ids).freeze
      )
      freeze
    end
  end

  PublishRequest = Struct.new(:page_id, :expected_updated_at, keyword_init: true) do
    def initialize(page_id:, expected_updated_at: nil)
      super(page_id:, expected_updated_at:)
      freeze
    end
  end

  class ConflictError < StandardError
  end
end
