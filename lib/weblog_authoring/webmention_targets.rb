# frozen_string_literal: true

require "uri"

require_relative "markdown"
require_relative "webmention_document"

module WeblogAuthoring
  class WebmentionTargets
    def initialize(site_url:)
      @site_uri = URI.parse(site_url)
    end

    def extract(body, source_url:)
      html = MarkdownRenderer.new.render(body, mode: "public").html
      document = WebmentionDocument.new(html, base_url: source_url)
      document.anchor_urls.filter_map do |uri|
        next unless %w[http https].include?(uri.scheme&.downcase)
        next if same_site?(uri)

        uri.fragment = nil
        uri.to_s
      end.uniq
    end

    private

    def same_site?(uri)
      uri.host&.casecmp(@site_uri.host.to_s)&.zero? && uri.port == @site_uri.port
    end
  end
end
