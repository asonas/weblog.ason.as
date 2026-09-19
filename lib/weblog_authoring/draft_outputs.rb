# frozen_string_literal: true

require_relative "draft_publisher"
require_relative "atom_feed"
require_relative "search_indexer"
require_relative "search_index"
require_relative "local_publication_objects"

module WeblogAuthoring
  class DraftOutputs
    Collection = Data.define(:list_pages)

    def initialize(store:, s3_client:, bucket:, site_url:, search_runner: SearchIndexer::QmdRunner.new, cache_dir: "/tmp/published-search")
      @store = store
      @s3 = s3_client
      @bucket = bucket
      @site_url = site_url
      @search_runner = search_runner
      @cache_dir = cache_dir
    end

    def current?(stage)
      head = @store.output_head(stage)
      return false unless head && head.fetch("revision").to_i == @store.publication_revision
      body = @s3.get_object(bucket: @bucket, key: head.fetch("object_key")).body.read
      return false unless Digest::SHA256.hexdigest(body) == head.fetch("digest")
      if stage == "search"
        manifest = JSON.parse(body)
        index = @s3.get_object(bucket: @bucket, key: manifest.fetch("index_key")).body.read
        return false unless Digest::SHA256.hexdigest(index) == manifest.fetch("index_sha256")
      end
      true
    rescue Aws::S3::Errors::NoSuchKey, JSON::ParserError, KeyError
      false
    end

    def build(stage)
      collection = @store.published_collection
      pages = collection.fetch("snapshots").map { |snapshot| DraftPublisher.page(snapshot) }
      prefix = "published-outputs/#{collection.fetch('revision')}/#{SecureRandom.uuid}"
      if stage == "atom"
        ids = collection.fetch("snapshots").to_h { |snapshot| [snapshot.fetch("article_id"), snapshot.fetch("atom_id", "urn:uuid:#{snapshot.fetch('article_id')}")] }
        key = "#{prefix}/feed.xml"
        body = AtomFeed.new(site_url: @site_url).render(pages, ids:)
        @s3.put_object(bucket: @bucket, key:, body:, content_type: "application/atom+xml; charset=utf-8", cache_control: "public, max-age=31536000, immutable")
      else
        key = "#{prefix}/search/manifest.json"
        SearchIndexer.new(database: Collection.new(list_pages: pages), s3_client: @s3, bucket: @bucket, runner: @search_runner, manifest_key: key).call
        body = @s3.get_object(bucket: @bucket, key:).body.read
      end
      { "revision" => collection.fetch("revision"), "object_key" => key, "digest" => Digest::SHA256.hexdigest(body) }
    end

    def feed
      head = @store.output_head("atom")
      return AtomFeed.new(site_url: @site_url).render([]) unless head
      @s3.get_object(bucket: @bucket, key: head.fetch("object_key")).body.read
    end

    def search(query:, limit:)
      head = @store.output_head("search")
      raise SearchIndex::Unavailable, "No published search index" unless head
      index = SearchIndex.new(s3_client: @s3, bucket: @bucket, cache_dir: @cache_dir, manifest_key: head.fetch("object_key"))
      index.search(query:, limit:)
    ensure
      index&.close
    end
  end
end
