# frozen_string_literal: true

require "cgi"
require "time"

require_relative "markdown"
require_relative "names"

module WeblogAuthoring
  class RssFeed
    DEFAULT_LIMIT = 30

    def initialize(site_url:, title: "weblog.ason.as", limit: DEFAULT_LIMIT)
      @site_url = site_url.to_s.sub(%r{/+\z}, "")
      @title = title
      @limit = limit
    end

    def render(pages)
      public_pages = Array(pages).select { |page| page.status == "published" }
      feed_pages = public_pages.reject(&:empty?).sort_by { |page| feed_time(page) }.reverse.first(@limit)
      renderer = MarkdownRenderer.new(pages: public_pages)

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
          <channel>
            <title>#{xml(@title)}</title>
            <link>#{xml(@site_url)}</link>
            <description>#{xml(@title)}</description>
            <language>ja</language>
            <atom:link href="#{xml("#{@site_url}/feed.xml")}" rel="self" type="application/rss+xml" />
        #{items_xml(feed_pages, renderer)}
          </channel>
        </rss>
      XML
    end

    private

    def items_xml(pages, renderer)
      pages.map do |page|
        url = page_url(page)
        description = absolute_internal_urls(renderer.render(page.body, mode: "public").html)
        <<~XML.chomp
            <item>
              <title>#{xml(page.display_title)}</title>
              <link>#{xml(url)}</link>
              <guid isPermaLink="true">#{xml(url)}</guid>
              <pubDate>#{feed_time(page).rfc2822}</pubDate>
              <description>#{xml(description)}</description>
            </item>
        XML
      end.join("\n")
    end

    def page_url(page)
      "#{@site_url}/#{WeblogAuthoring.encoded_route(page.route)}"
    end

    def feed_time(page)
      page.updated_at || page.published_at || page.created_at
    end

    def absolute_internal_urls(html)
      html.gsub(/(?<attribute>href|src)="\/(?!\/)/) do
        %(#{Regexp.last_match[:attribute]}="#{@site_url}/)
      end
    end

    def xml(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
