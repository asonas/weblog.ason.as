# frozen_string_literal: true

require "cgi"
require "digest"
require "uri"

module WeblogAuthoring
  class WebmentionDocument
    ATTRIBUTE_PATTERN = /([:\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i

    def initialize(html, base_url:)
      @html = html
      @base_url = base_url
    end

    def links_to?(target)
      anchor_urls.any? { |url| comparable_url(url) == comparable_url(URI.parse(target)) }
    end

    def anchor_urls
      base = document_base_url
      links.filter_map do |href|
        URI.join(base, href)
      rescue URI::InvalidURIError
        nil
      end
    end

    def title
      text = markup[/<title\b[^>]*>(.*?)<\/title\s*>/im, 1]
      normalize_text(text)
    end

    def site_name
      markup.scan(/<meta\b[^>]*>/im).each do |tag|
        attributes = attributes(tag)
        next unless attributes.fetch("property", "").casecmp("og:site_name").zero?

        return normalize_text(attributes["content"])
      end
      nil
    end

    def content_hash
      Digest::SHA256.hexdigest(@html)
    end

    def webmention_endpoint(link_header: nil)
      header_endpoint = endpoint_from_link_header(link_header)
      return header_endpoint if header_endpoint

      markup.scan(/<(?:link|a)\b[^>]*>/im).each do |tag|
        values = attributes(tag)
        next unless values.fetch("rel", "").split.any? { |rel| rel.casecmp("webmention").zero? }

        endpoint = resolve_url(values["href"])
        return endpoint if endpoint
      end
      nil
    end

    private

    def links
      markup.scan(/<a\b[^>]*>/im).filter_map { |tag| attributes(tag)["href"] }
    end

    def document_base_url
      tag = markup[/<base\b[^>]*>/im]
      href = tag && attributes(tag)["href"]
      href ? URI.join(@base_url, href) : @base_url
    rescue URI::InvalidURIError
      @base_url
    end

    def endpoint_from_link_header(value)
      value.to_s.split(/,(?=\s*<)/).each do |entry|
        match = /\A\s*<([^>]+)>\s*;(.*)\z/.match(entry)
        next unless match
        parameters = match[2].scan(/([\w-]+)=(?:"([^"]*)"|([^;\s]+))/).to_h do |name, quoted, plain|
          [name.downcase, quoted || plain]
        end
        next unless parameters.fetch("rel", "").split.any? { |rel| rel.casecmp("webmention").zero? }

        endpoint = resolve_url(match[1])
        return endpoint if endpoint
      end
      nil
    end

    def resolve_url(value)
      return nil if value.nil?

      URI.join(document_base_url, value).to_s
    rescue URI::InvalidURIError
      nil
    end

    def attributes(tag)
      tag.scan(ATTRIBUTE_PATTERN).to_h do |name, double_quoted, single_quoted, unquoted|
        [name.downcase, CGI.unescapeHTML(double_quoted || single_quoted || unquoted)]
      end
    end

    def normalize_text(value)
      text = CGI.unescapeHTML(value.to_s.gsub(/<[^>]*>/, " ")).split.join(" ")
      text.empty? ? nil : text
    end

    def markup
      @markup ||= @html.gsub(/<!--.*?-->/m, "")
    end

    def comparable_url(uri)
      copy = uri.normalize
      copy.scheme = copy.scheme&.downcase
      copy.host = copy.host&.downcase
      copy.fragment = nil
      copy.path = "/" if copy.path.empty?
      copy.path = copy.path.sub(%r{/+\z}, "") unless copy.path == "/"
      copy.port = nil if (copy.scheme == "http" && copy.port == 80) || (copy.scheme == "https" && copy.port == 443)
      copy.to_s
    end
  end
end
