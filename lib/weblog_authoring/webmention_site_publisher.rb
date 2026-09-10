# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "securerandom"
require "time"
require "uri"

require_relative "markdown"
require_relative "cover_image"
require_relative "cover_variants"

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
      return if desired_updated_at && page.updated_at.to_i != Time.iso8601(desired_updated_at).to_i

      old_route = previous_route(outbox.fetch("payload"), current_route: page.route)
      unless page.status == "published" && !page.empty?
        routes = [page.route, old_route].compact.uniq
        routes.each { |route| @s3_client.delete_object(bucket: @site_bucket, key: route) }
        invalidate(routes, outbox.fetch("id"), revision: outbox.dig("payload", "revision"))
        completed = @database.complete_webmention_outbox(
          outbox.fetch("id"), revision: outbox.dig("payload", "revision")
        )
        enqueue_deliveries(outbox) if completed && @sender_enabled
        return
      end

      shell = site_shell
      CoverVariants.new(s3_client: @s3_client, bucket: @site_bucket).create(CoverImage.resolve(page))
      body = render_page(page, source_url: outbox.fetch("payload").fetch("source_url"))
      html = shell.sub('<div id="authoring-root"></div>') { %(<div id="authoring-root">#{body}</div>) }
      raise "site shell does not contain authoring-root" if html == shell
      html = html.sub(/<title>.*?<\/title>/m, "")
        .sub("</head>", "#{page_metadata(page, outbox.fetch('payload').fetch('source_url'))}</head>")

      @s3_client.put_object(
        bucket: @site_bucket, key: page.route, body: html,
        content_type: "text/html; charset=utf-8", cache_control: "public, max-age=0, must-revalidate"
      )
      @s3_client.delete_object(bucket: @site_bucket, key: old_route) if old_route
      hubs = publish_linked_hubs(page)
      invalidate([page.route, old_route, *hubs].compact.uniq, outbox.fetch("id"), revision: outbox.dig("payload", "revision"))
      completed = @database.complete_webmention_outbox(
        outbox.fetch("id"), revision: outbox.dig("payload", "revision")
      )
      enqueue_deliveries(outbox) if completed && @sender_enabled
    rescue StandardError
      @database.fail_webmention_outbox(outbox.fetch("id"))
      raise
    end

    private

    def publish_linked_hubs(page)
      saved_routes = @database.list_pages.reject(&:empty?).map(&:route)
      names = WeblogAuthoring.extract_wiki_links(page.body).filter_map do |link|
        WeblogAuthoring.validate_page_name(link.name)
      rescue ArgumentError
        nil
      end.uniq - saved_routes
      return [] if names.empty?

      shell = @s3_client.get_object(bucket: @site_bucket, key: "index.html").body.read
      names.each do |name|
        @s3_client.put_object(
          bucket: @site_bucket, key: name, body: shell,
          content_type: "text/html; charset=utf-8", cache_control: "public, max-age=0, must-revalidate",
          if_none_match: "*"
        )
      rescue Aws::S3::Errors::PreconditionFailed
        # A saved article or an existing hub must not be overwritten.
        next
      end
      names
    end

    def site_shell
      @s3_client.get_object(bucket: @site_bucket, key: "static/authoring/public.html").body.read
    end

    def previous_route(payload, current_route:)
      source = payload["previous_source_url"]
      return nil if source.to_s.empty?

      route = URI.decode_www_form_component(URI.parse(source).path.sub(%r{\A/}, ""))
      route.empty? || route == current_route ? nil : route
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def invalidate(routes, outbox_id, revision:)
      paths = routes.map { |route| "/#{URI::DEFAULT_PARSER.escape(route).gsub("'", "%27").gsub("/", "%2F")}" }
      reference = Digest::SHA256.hexdigest(JSON.generate([outbox_id, revision, paths]))
      @cloudfront_client.create_invalidation(
        distribution_id: @distribution_id,
        invalidation_batch: {
          paths: { quantity: paths.length, items: paths },
          caller_reference: "webmention-#{reference}",
        }
      )
    end

    def render_page(page, source_url:)
      dimensions = {}
      rendered = MarkdownRenderer.new(pages: @database.list_pages).render(
        page.body, mode: "public", progressive: true,
        image_dimensions: ->(src) { dimensions.fetch(src) { dimensions[src] = @database.find_image_dimensions(src) } }
      )
      mentions = @database.approved_webmentions_for_page(page.id)
      escaped_source_url = CGI.escapeHTML(source_url)
      author_url = CGI.escapeHTML(URI.join(source_url, "/").to_s)
      editing_href = CGI.escapeHTML("/editor/#{WeblogAuthoring.encoded_route(page.id)}")
      cover = CoverImage.resolve(page)
      cover_html = cover ? %(<img src="#{CGI.escapeHTML(cover)}" alt="" fetchpriority="high" />) : ""
      <<~HTML
        <article class="article-workspace article-workspace--reading webmention-static-page h-entry" data-public-article="1" data-editing-href="#{editing_href}">
          <header class="article-reading-header#{cover ? ' article-reading-header--covered' : ''}">
            #{cover_html}
            <h1 class="p-name">#{CGI.escapeHTML(page.display_title.to_s)}</h1>
            <a class="u-url" href="#{escaped_source_url}" hidden="">記事のパーマリンク</a>
            <span class="p-author h-card" hidden=""><a class="p-name u-url" href="#{author_url}">asonas</a></span>
          </header>
          <div class="editor-canvas"><div class="e-content ProseMirror public-article-body">
            #{rendered.html.chomp}
          </div>
          </div>
          #{render_mentions(mentions)}
          <div data-public-universe="#{CGI.escapeHTML(JSON.generate({ route: page.route, id: page.id, wiki: rendered.links.map(&:name).uniq, urls: WeblogAuthoring.extract_external_urls(page.body.to_s) }))}"></div>
        </article>
      HTML
    end

    def page_metadata(page, source_url)
      title = CGI.escapeHTML(page.display_title.to_s)
      rendered = MarkdownRenderer.new.render(page.body, mode: "public")
      description = CGI.escapeHTML(CGI.unescapeHTML(rendered.html.gsub(/<[^>]*>/, " ")).gsub(/\s+/, " ").strip[0, 160])
      url = CGI.escapeHTML(source_url)
      cover = CoverImage.resolve(page)
      image = cover ? %(<meta property="og:image" content="#{CGI.escapeHTML(URI.join(source_url, cover).to_s)}" />) : ""
      <<~HTML
        <title>#{title} | weblog.ason.as</title>
        <meta name="description" content="#{description}" />
        <link rel="canonical" href="#{url}" />
        <meta property="og:type" content="article" />
        <meta property="og:site_name" content="weblog.ason.as" />
        <meta property="og:title" content="#{title}" />
        <meta property="og:description" content="#{description}" />
        <meta property="og:url" content="#{url}" />
        #{image}
        <meta name="twitter:card" content="#{cover ? 'summary_large_image' : 'summary'}" />
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
