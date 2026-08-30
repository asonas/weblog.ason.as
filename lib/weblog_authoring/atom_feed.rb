# frozen_string_literal: true

require "cgi"
require "time"

require_relative "markdown"
require_relative "names"

module WeblogAuthoring
  class AtomFeed
    DEFAULT_LIMIT = 30

    def initialize(site_url:, title: "weblog.ason.as", limit: DEFAULT_LIMIT)
      @site_url = site_url.to_s.sub(%r{/+\z}, "")
      @title = title
      @limit = limit
    end

    def render(pages)
      public_pages = Array(pages).select { |page| page.status == "published" }
      feed_pages = public_pages.reject(&:empty?).sort_by { |page| updated_time(page) }.reverse.first(@limit)
      renderer = MarkdownRenderer.new(pages: public_pages)

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>#{xml("#{@site_url}/")}</id>
          <title>#{xml(@title)}</title>
          <updated>#{atom_time(feed_pages.first && updated_time(feed_pages.first))}</updated>
          <link rel="alternate" type="text/html" href="#{xml(@site_url)}" />
          <link rel="self" type="application/atom+xml" href="#{xml("#{@site_url}/feed.xml")}" />
          <author>
            <name>#{xml(@title)}</name>
          </author>
        #{entries_xml(feed_pages, renderer)}
        </feed>
      XML
    end

    private

    def entries_xml(pages, renderer)
      pages.map do |page|
        url = page_url(page)
        content = absolute_internal_urls(renderer.render(page.body, mode: "public").html)
        <<~XML.chomp
            <entry>
              <id>#{xml(url)}</id>
              <title>#{xml(page.display_title)}</title>
              <link rel="alternate" type="text/html" href="#{xml(url)}" />
              <published>#{atom_time(page.published_at || page.created_at)}</published>
              <updated>#{atom_time(updated_time(page))}</updated>
              <content type="html">#{xml(content)}</content>
            </entry>
        XML
      end.join("\n")
    end

    def page_url(page)
      "#{@site_url}/#{WeblogAuthoring.encoded_route(page.route)}"
    end

    def updated_time(page)
      page.updated_at || page.published_at || page.created_at
    end

    def atom_time(value)
      (value || Time.at(0).utc).iso8601
    end

    def absolute_internal_urls(html)
      html.gsub(/(?<attribute>href|src)="\/(?!\/)/) do
        %(#{Regexp.last_match[:attribute]}="#{@site_url}/) # steep:ignore NoMethod
      end
    end

    def xml(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
