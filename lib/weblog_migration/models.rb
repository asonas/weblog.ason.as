# frozen_string_literal: true

module WeblogMigration
  ScrapboxPage = Struct.new(
    :project,
    :title,
    :lines,
    :created_at,
    :updated_at,
    :links,
    :asset_references,
    :external_urls,
    :source_url,
    keyword_init: true
  ) do
    def initialize(**attributes)
      attributes[:lines] = Array(attributes[:lines]).freeze
      attributes[:links] = Array(attributes[:links]).freeze
      attributes[:asset_references] = Array(attributes[:asset_references]).freeze
      attributes[:external_urls] = Array(attributes[:external_urls]).freeze
      super(**attributes)
      freeze
    end
  end

  ScrapboxProject = Struct.new(:name, :pages, keyword_init: true) do
    def initialize(name:, pages:)
      super(name:, pages: Array(pages).freeze)
      freeze
    end
  end

  NormalizationIssue = Struct.new(:kind, :source, :detail, keyword_init: true) do
    def initialize(kind:, source:, detail:)
      super
      freeze
    end
  end

  NormalizedPost = Struct.new(
    :id,
    :frontmatter,
    :body,
    :links,
    :asset_references,
    :external_urls,
    :issues,
    keyword_init: true
  ) do
    def initialize(**attributes)
      attributes[:links] = Array(attributes[:links]).freeze
      attributes[:asset_references] = Array(attributes[:asset_references]).freeze
      attributes[:external_urls] = Array(attributes[:external_urls]).freeze
      attributes[:issues] = Array(attributes[:issues]).freeze
      super(**attributes)
      freeze
    end
  end

  NormalizationResult = Struct.new(:posts, :mapping, :issues, keyword_init: true) do
    def initialize(posts:, mapping:, issues:)
      super(posts: Array(posts).freeze, mapping: mapping.dup.freeze, issues: Array(issues).freeze)
      freeze
    end
  end

  AssetManifestEntry = Struct.new(:id, :url, :kind, :source_post_ids, keyword_init: true) do
    def initialize(**attributes)
      attributes[:source_post_ids] = Array(attributes[:source_post_ids]).freeze
      super(**attributes)
      freeze
    end

    def to_h
      {
        "id" => id,
        "url" => url,
        "kind" => kind,
        "source_post_ids" => source_post_ids
      }
    end
  end
end
