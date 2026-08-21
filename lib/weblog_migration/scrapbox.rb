# frozen_string_literal: true

require "json"
require "pathname"
require "time"
require "uri"

module WeblogMigration
  module Scrapbox
    SCRAPBOX_LINK = /\[([^\[\]]+)\]/.freeze
    EXTERNAL_URL = %r{https?://[^\s<>\[\]\\"']+}.freeze

    module_function

    def load_export(path)
      path = Pathname(path)
      payload = JSON.parse(path.read(encoding: "UTF-8"))
      unless payload.is_a?(Hash)
        raise ArgumentError, "Scrapbox export must be an object: #{path}"
      end

      project_name = payload["projectName"] || payload["name"]
      raw_pages = payload["pages"]
      unless project_name.is_a?(String) && raw_pages.is_a?(Array)
        raise ArgumentError, "Scrapbox export is missing projectName or pages: #{path}"
      end

      pages = raw_pages.map { |raw_page| parse_page(project_name, raw_page, path) }
      ScrapboxProject.new(name: project_name, pages:)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise ArgumentError, "could not read Scrapbox export: #{path}: #{error.message}"
    end

    def parse_page(project_name, raw_page, path)
      raise ArgumentError, "Scrapbox page must be an object: #{path}" unless raw_page.is_a?(Hash)

      title = raw_page["title"]
      raw_lines = raw_page.fetch("lines", [])
      unless title.is_a?(String) && raw_lines.is_a?(Array)
        raise ArgumentError, "Scrapbox page is missing title or lines: #{path}"
      end

      lines = raw_lines.map { |line| line_text(line, path) }
      links, external_urls = extract_references(lines)
      assets = extract_assets(raw_page["assets"], path)
      source_url = "https://scrapbox.io/#{escape_component(project_name)}/#{escape_component(title)}"

      ScrapboxPage.new(
        project: project_name,
        title:,
        lines:,
        created_at: timestamp(raw_page["created"]),
        updated_at: timestamp(raw_page["updated"]),
        links:,
        asset_references: assets,
        external_urls:,
        source_url:
      )
    end

    def line_text(line, path)
      return line if line.is_a?(String)
      return line["text"] if line.is_a?(Hash) && line["text"].is_a?(String)

      raise ArgumentError, "Scrapbox page line must contain text: #{path}"
    end

    def extract_references(lines)
      links = []
      external_urls = []
      lines.each do |line|
        line.scan(SCRAPBOX_LINK) do |match|
          target = match.first.strip
          next if target.match?(EXTERNAL_URL)
          links << target.delete_prefix("/") if !target.empty? && !links.include?(target.delete_prefix("/"))
        end
        line.scan(EXTERNAL_URL) do |match|
          url = clean_url(match)
          external_urls << url if !url.empty? && !external_urls.include?(url)
        end
      end
      [links, external_urls]
    end

    def clean_url(value)
      value.sub(/[.,;:!?\)\]}]+\z/, "")
    end

    def extract_assets(raw_assets, path)
      return [] if raw_assets.nil?
      unless raw_assets.is_a?(Array) && raw_assets.all? { |asset| asset.is_a?(String) }
        raise ArgumentError, "Scrapbox page assets must be a list of strings: #{path}"
      end
      raw_assets.uniq
    end

    def timestamp(value)
      return nil if value.nil?
      unless value.is_a?(Numeric)
        raise ArgumentError, "Scrapbox timestamp must be numeric: #{value.inspect}"
      end
      Time.at(value).utc
    end

    def escape_component(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end
  end
end
