# frozen_string_literal: true

require "fileutils"
require_relative "draft_publication"
require_relative "models"
require_relative "webmention_site_publisher"

module WeblogAuthoring
  class DraftPublisher
    def self.s3(publication:, database:, s3_client:, site_bucket:, site_url:, shell_key: "index.html")
      read = ->(key) { s3_client.get_object(bucket: site_bucket, key:).body.read }
      new(publication:, database:, site_url:, shell: -> { read.call(shell_key) }, read:) do |key, html|
        s3_client.put_object(bucket: site_bucket, key:, body: html, content_type: "text/html; charset=utf-8", cache_control: "public, max-age=31536000, immutable", if_none_match: "*")
      rescue Aws::S3::Errors::PreconditionFailed
        # A previous attempt placed this version before its activation was recorded.
        nil
      end
    end

    def self.local(publication:, database:, root:, shell:, site_url:)
      new(publication:, database:, site_url:, shell:, read: ->(key) { root.join(key).read }) do |key, html|
        path = root.join(key)
        FileUtils.mkdir_p(path.dirname)
        temporary = path.sub_ext(".#{SecureRandom.hex(8)}.tmp")
        temporary.write(html)
        begin
          File.link(temporary, path)
        rescue Errno::EEXIST
          nil
        ensure
          File.unlink(temporary)
        end
      end
    end

    def initialize(publication:, database:, site_url:, shell:, read:, &place)
      @publication = publication
      @shell = shell
      @place = place
      @read = read
      @site_url = site_url.delete_suffix("/")
      @renderer = WebmentionSitePublisher.new(database:, s3_client: nil, site_bucket: nil, sqs_client: nil, delivery_queue_url: nil, sender_enabled: false, draft_authoring: true)
    end

    def read(snapshot)
      @read.call(snapshot.fetch("html_key", "published/#{snapshot.fetch('article_id')}/#{snapshot.fetch('id')}.html"))
    end

    def current?(snapshot)
      snapshot && snapshot["html_digest"] && Digest::SHA256.hexdigest(read(snapshot)) == snapshot.fetch("html_digest")
    rescue Aws::S3::Errors::NoSuchKey, Errno::ENOENT
      false
    end

    def repair(snapshot)
      unless snapshot["html_digest"]
        begin
          body = read(snapshot)
          return { "html_key" => "published/#{snapshot.fetch('article_id')}/#{snapshot.fetch('id')}.html", "html_digest" => Digest::SHA256.hexdigest(body) }
        rescue Aws::S3::Errors::NoSuchKey, Errno::ENOENT
          # An interrupted placement is rebuilt from its immutable snapshot.
        end
      end
      page = self.class.page(snapshot)
      html = @renderer.render_document(page, shell: @shell.call, source_url: "#{@site_url}/#{URI::DEFAULT_PARSER.escape(page.route)}")
      key = "published/#{snapshot.fetch('article_id')}/#{snapshot.fetch('id')}/#{SecureRandom.uuid}.html"
      @place.call(key, html)
      { "html_key" => key, "html_digest" => Digest::SHA256.hexdigest(html) }
    end

    def run(id, version_id)
      @publication.complete(id, version_id) do |snapshot|
        shell = @shell.call
        page = self.class.page(snapshot)
        html = @renderer.render_document(page, shell:, source_url: "#{@site_url}/#{URI::DEFAULT_PARSER.escape(page.route)}")
        key = "published/#{snapshot.fetch('article_id')}/#{snapshot.fetch('id')}.html"
        @place.call(key, html)
        key
      end
    end

    def self.page(snapshot)
      return nil unless snapshot
      metadata = snapshot.fetch("metadata")
      PageDocument.new(id: snapshot.fetch("article_id"), page_type: metadata.fetch("page_type"),
        name: snapshot.fetch("route"), page_date: metadata.fetch("page_type") == "date" ? Date.iso8601(snapshot.fetch("route")) : nil,
        title: metadata.fetch("title"), status: "published", body: snapshot.fetch("body"),
        created_at: Time.iso8601(snapshot.fetch("article_created_at")),
        updated_at: Time.iso8601(snapshot.fetch("updated_at", snapshot.fetch("created_at"))),
        published_at: Time.iso8601(snapshot.fetch("published_at", snapshot.fetch("created_at"))),
        cover_mode: metadata.fetch("cover_mode"), cover_image_url: metadata["cover_image_url"],
        links: WeblogAuthoring.extract_wiki_links(snapshot.fetch("body")))
    end
  end
end
