# frozen_string_literal: true

require_relative "webmention_targets"

module WeblogAuthoring
  module DraftWebmentionStore
    def setup_webmentions(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_webmention_requests (article_id TEXT NOT NULL, version_id TEXT NOT NULL, targets TEXT, status TEXT NOT NULL, PRIMARY KEY (article_id, version_id))")
    end

    def webmention_requests(id = nil)
      @connect.call do |db|
        db.query("SELECT * FROM #{db.prefix}draft_webmention_requests" + (id ? " WHERE article_id = $1" : " WHERE status = 'pending' LIMIT 100"), id ? [id] : [])
      end
    end

    def request_webmentions(id, version_id, targets)
      @connect.call do |db|
        db.transaction do
          head = db.query("SELECT active_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $1", [id]).first
          raise DraftStore::Error.new("公開版が変わりました。記事を保存してから送信してください。", 409) unless head && head["active_id"] == version_id
          db.query("UPDATE #{db.prefix}draft_publication_heads SET active_id = active_id WHERE article_id = $1", [id])
          db.query("INSERT INTO #{db.prefix}draft_webmention_requests (article_id, version_id, targets, status) VALUES ($1, $2, $3, 'pending') ON CONFLICT (article_id, version_id) DO NOTHING", [id, version_id, JSON.generate(targets)])
        end
      end
    end

    def complete_webmention_request(id, version_id)
      @connect.call { |db| db.query("UPDATE #{db.prefix}draft_webmention_requests SET status = 'queued' WHERE article_id = $1 AND version_id = $2", [id, version_id]) }
    end

    def first_published_snapshot(id)
      @connect.call do |db|
        row = db.query("SELECT v.id FROM #{db.prefix}draft_published_versions v JOIN #{db.prefix}draft_publication_jobs j ON j.id = v.id WHERE v.article_id = $1 AND j.status = 'completed' ORDER BY v.created_at, v.id LIMIT 1", [id]).first
        row && snapshot_from(db, id, row.fetch("id"))
      end
    end
  end

  class DraftWebmentions
    def initialize(store:, sqs_client:, queue_url:, site_url:, enabled:)
      @store = store
      @sqs = sqs_client
      @queue_url = queue_url
      @site_url = site_url.delete_suffix("/")
      @enabled = enabled
      @targets = WebmentionTargets.new(site_url:)
    end

    def status(id)
      snapshot = @store.published_snapshot(id)
      raise DraftStore::Error.new("公開済みの記事がありません。", 409) unless snapshot
      requests = @store.webmention_requests(id)
      baseline = @store.first_published_snapshot(id)
      known = baseline ? targets(baseline) : []
      requests.each do |request|
        known |= request["targets"] ? JSON.parse(request.fetch("targets")) : targets(@store.publication_snapshot(id, request.fetch("version_id")))
      end
      { "version_id" => snapshot.fetch("id"), "targets" => targets(snapshot) - known,
        "pending" => requests.any? { |request| request.fetch("status") == "pending" }, "enabled" => @enabled, }
    end

    def send_new(id, version_id)
      raise DraftStore::Error.new("Webmentionの送信は停止中です。", 503) unless @enabled
      current = status(id)
      raise DraftStore::Error.new("公開版が変わりました。記事を保存してから送信してください。", 409) unless current.fetch("version_id") == version_id
      @store.request_webmentions(id, version_id, current.fetch("targets")) unless current.fetch("targets").empty?
      dispatch(id)
      status(id)
    end

    def dispatch(id = nil)
      return unless @enabled
      @store.webmention_requests(id).each do |request|
        next unless request.fetch("status") == "pending"
        article_id, version_id = request.values_at("article_id", "version_id")
        snapshot = @store.publication_snapshot(article_id, version_id)
        current = @store.published_snapshot(article_id)
        next unless current
        urls = request["targets"] ? JSON.parse(request.fetch("targets")) : targets(snapshot)
        # Only notify links that remain in the publicly readable version.
        (urls & targets(current)).each do |target|
          source = source_url(current)
          delivery_id = Digest::SHA256.hexdigest("#{article_id}\0#{version_id}\0#{source}\0#{target}")
          @sqs.send_message(queue_url: @queue_url,
            message_body: JSON.generate("type" => "deliver", "delivery_id" => delivery_id, "page_id" => article_id, "source" => source, "target" => target),
            message_group_id: Digest::SHA256.hexdigest("#{source}\0#{target}"), message_deduplication_id: delivery_id)
        end
        @store.complete_webmention_request(article_id, version_id)
      end
    end

    private

    def source_url(snapshot) = "#{@site_url}/#{URI::DEFAULT_PARSER.escape(snapshot.fetch('route'))}"
    def targets(snapshot) = @targets.extract(snapshot.fetch("body"), source_url: source_url(snapshot))
  end
end
