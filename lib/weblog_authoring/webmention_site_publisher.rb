# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "securerandom"
require "uri"

require_relative "markdown"

module WeblogAuthoring
  class WebmentionSitePublisher
    def initialize(database:, s3_client:, cloudfront_client:, sqs_client:, site_bucket:,
                   distribution_id:, delivery_queue_url:, sender_enabled: true)
      @database = database
      @s3_client = s3_client
      @cloudfront_client = cloudfront_client
      @sqs_client = sqs_client
      @site_bucket = site_bucket
      @distribution_id = distribution_id
      @delivery_queue_url = delivery_queue_url
      @sender_enabled = sender_enabled
    end

    def call(event)
      outboxes = if event.key?("Records")
                   event.fetch("Records").map do |record|
                     payload = JSON.parse(record.fetch("body"))
                     @database.webmention_outbox(payload.fetch("outbox_id"))
                   end.compact
                 else
                   @database.pending_webmention_outbox(limit: 100)
                 end
      outboxes.each { |outbox| publish(outbox) }
    end

    def publish(outbox)
      page = @database.find(outbox.fetch("page_id"))
      raise KeyError, "Webmention outbox page not found" unless page
      desired_updated_at = outbox.dig("payload", "desired_updated_at")
      return if desired_updated_at && page.updated_at.iso8601(9) != desired_updated_at

      old_route = previous_route(outbox.fetch("payload"), current_route: page.route)
      unless page.status == "published" && !page.empty?
        routes = [page.route, old_route].compact.uniq
        routes.each { |route| @s3_client.delete_object(bucket: @site_bucket, key: route) }
        invalidate(routes, outbox.fetch("id"))
        @database.complete_webmention_outbox(
          outbox.fetch("id"), revision: outbox.dig("payload", "revision")
        )
        return
      end

      shell = site_shell
      body = render_page(page)
      html = shell.sub('<div id="authoring-root"></div>', %(<div id="authoring-root">#{body}</div>))
      raise "site shell does not contain authoring-root" if html == shell

      @s3_client.put_object(
        bucket: @site_bucket, key: page.route, body: html,
        content_type: "text/html; charset=utf-8", cache_control: "public, max-age=0, must-revalidate"
      )
      @s3_client.delete_object(bucket: @site_bucket, key: old_route) if old_route
      invalidate([page.route, old_route].compact.uniq, outbox.fetch("id"))
      completed = @database.complete_webmention_outbox(
        outbox.fetch("id"), revision: outbox.dig("payload", "revision")
      )
      enqueue_deliveries(outbox) if completed && @sender_enabled
    rescue StandardError
      @database.fail_webmention_outbox(outbox.fetch("id"))
      raise
    end

    private

    def site_shell
      @s3_client.get_object(bucket: @site_bucket, key: "index.html").body.read
    end

    def previous_route(payload, current_route:)
      source = payload["previous_source_url"]
      return nil if source.to_s.empty?

      route = URI.decode_www_form_component(URI.parse(source).path.sub(%r{\A/}, ""))
      route.empty? || route == current_route ? nil : route
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def invalidate(routes, outbox_id)
      paths = routes.map { |route| "/#{URI::DEFAULT_PARSER.escape(route)}" }
      @cloudfront_client.create_invalidation(
        distribution_id: @distribution_id,
        invalidation_batch: {
          paths: { quantity: paths.length, items: paths },
          caller_reference: "webmention-#{outbox_id}",
        }
      )
    end

    def render_page(page)
      rendered = MarkdownRenderer.new(pages: @database.list_pages).render(page.body, mode: "public")
      mentions = @database.approved_webmentions_for_page(page.id)
      <<~HTML
        <article class="page-view webmention-static-page">
          <header class="page-header"><h1>#{CGI.escapeHTML(page.display_title.to_s)}</h1></header>
          #{rendered.html.chomp}
          #{render_mentions(mentions)}
        </article>
      HTML
    end

    def render_mentions(mentions)
      return "" if mentions.empty?

      items = mentions.map do |mention|
        title = mention["title"].to_s.empty? ? mention.fetch("source_url") : mention.fetch("title")
        site = mention["site_name"].to_s
        <<~HTML.chomp
          <li><a href="#{CGI.escapeHTML(mention.fetch('source_url'))}">#{CGI.escapeHTML(title)}</a>#{site.empty? ? '' : "<small>#{CGI.escapeHTML(site)}</small>"}</li>
        HTML
      end.join("\n")
      <<~HTML
        <section class="external-mentions" aria-labelledby="external-mentions-heading">
          <h2 id="external-mentions-heading">外部からの言及</h2>
          <ul>#{items}</ul>
        </section>
      HTML
    end

    def enqueue_deliveries(outbox)
      payload = outbox.fetch("payload")
      current_source = payload.fetch("source_url")
      previous_source = payload["previous_source_url"] || current_source
      return if previous_source == current_source &&
                payload.fetch("previous_targets").sort == payload.fetch("current_targets").sort

      deliveries = payload.fetch("previous_targets").map { |target| [previous_source, target] }
      deliveries.concat(payload.fetch("current_targets").map { |target| [current_source, target] })
      deliveries.uniq.each do |source, target|
        delivery_id = SecureRandom.uuid
        @sqs_client.send_message(
          queue_url: @delivery_queue_url,
          message_body: JSON.generate(
            "type" => "deliver", "delivery_id" => delivery_id,
            "page_id" => outbox.fetch("page_id"), "source" => source, "target" => target
          ),
          message_group_id: Digest::SHA256.hexdigest("#{source}\0#{target}"),
          message_deduplication_id: delivery_id
        )
      end
    end
  end
end
