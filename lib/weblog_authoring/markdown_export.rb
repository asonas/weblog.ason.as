# frozen_string_literal: true

require_relative "links"
require_relative "names"

module WeblogAuthoring
  class MarkdownExport
    EMBED_PATTERN = /^\[embed:(https?:\/\/[^\s\]]+)\]$/.freeze

    def initialize(site_url:, title: "weblog.ason.as")
      @site_url = site_url.to_s.sub(%r{/+\z}, "")
      @title = title
    end

    def article(page)
      "# #{page.display_title}\n\n#{portable(page.body.to_s).sub(/\A(?:[ \t]*\n)+/, "").rstrip}\n"
    end

    def home(pages)
      items = pages.reject(&:empty?).map do |page|
        "- [#{escape_label(page.display_title)}](#{page_url(page.route)}) (#{(page.updated_at || page.published_at || page.created_at).utc.strftime("%Y-%m-%d")})"
      end

      <<~MARKDOWN
        # #{@title}

        ## 新しい記事

        #{items.join("\n")}

        ## すべての記事

        - [Sitemap](#{@site_url}/sitemap.xml)
        - [Atom feed](#{@site_url}/feed.xml)
      MARKDOWN
    end

    private

    def portable(body)
      WeblogAuthoring.extract_wiki_links(body).reverse_each do |link|
        body = "#{body[0...link.start]}[#{escape_label(link.name)}](#{page_url(link.name)})#{body[link.end..] || ""}"
      rescue ArgumentError
        next
      end
      fence = nil
      body.each_line.map do |line|
        marker = FENCE_PATTERN.match(line)&.[](1)
        if marker && fence.nil?
          fence = marker
        elsif marker && marker[0] == fence[0] && marker.length >= fence.length
          fence = nil
        elsif fence.nil?
          next line.sub(EMBED_PATTERN) { "<#{Regexp.last_match(1)}>" }
        end
        line
      end.join
    end

    def page_url(route)
      "#{@site_url}/#{WeblogAuthoring.encoded_route(route)}"
    end

    def escape_label(text)
      text.to_s.gsub(/[\\\[\]]/) { "\\#{Regexp.last_match(0)}" }
    end
  end
end
