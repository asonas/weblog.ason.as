# frozen_string_literal: true

require "cgi"
require "time"

require_relative "names"

module WeblogAuthoring
  class Sitemap
    def initialize(site_url:)
      @site_url = site_url.to_s.sub(%r{/+\z}, "")
    end

    def render(entries)
      urls = entries.filter_map do |entry|
        location = "#{@site_url}/#{WeblogAuthoring.encoded_route(entry.fetch("route"))}"
        "  <url><loc>#{CGI.escapeHTML(location)}</loc><lastmod>#{Time.iso8601(entry.fetch("updated_at")).utc.iso8601}</lastmod></url>"
      rescue ArgumentError
        nil
      end

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>#{CGI.escapeHTML("#{@site_url}/")}</loc></url>
        #{urls.join("\n")}
        </urlset>
      XML
    end
  end
end
