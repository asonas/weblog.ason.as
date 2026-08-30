# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "time"

module WeblogAuthoring
  class ScrapboxLineMetadataImporter
    def initialize(database:, export_path:)
      @database = database
      @export_path = Pathname(export_path)
    end

    def run
      @database.setup!
      pages = load_pages
      imported_lines_by_page = {}
      unmatched_titles = []
      skipped_titles = []

      pages.each do |raw_page|
        title = raw_page.fetch("title")
        page = @database.find_route(title)
        unless page
          unmatched_titles << title
          next
        end

        expected_line_count = body_line_count(page.body)
        lines = metadata_lines(raw_page, expected_line_count)
        unless lines && lines.length == expected_line_count
          skipped_titles << title
          next
        end

        @database.replace_scrapbox_line_metadata(
          page.id,
          body_hash: Digest::SHA256.hexdigest(page.body),
          lines:
        )
        imported_lines_by_page[page.id] = lines.length
      end

      {
        imported_pages: imported_lines_by_page.count { |_page_id, line_count| line_count.positive? },
        imported_lines: imported_lines_by_page.values.sum,
        unmatched_pages: unmatched_titles.length,
        skipped_pages: skipped_titles.length,
        unmatched_titles:,
        skipped_titles:,
      }
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise ArgumentError, "could not read Scrapbox export: #{@export_path}: #{error.message}"
    end

    private

    def load_pages
      payload = JSON.parse(@export_path.read(encoding: "UTF-8"))
      pages = payload.is_a?(Hash) ? payload["pages"] : nil
      raise ArgumentError, "Scrapbox export must contain pages: #{@export_path}" unless pages.is_a?(Array)

      pages
    end

    def metadata_lines(raw_page, expected_line_count)
      title = raw_page["title"]
      raw_lines = raw_page["lines"]
      return nil unless title.is_a?(String) && raw_lines.is_a?(Array)

      raw_lines = raw_lines.drop(1) if title_line?(line_text(raw_lines.first), title)
      raw_lines = raw_lines[...-1] while raw_lines.length > expected_line_count && line_text(raw_lines.last) == ""
      return nil unless raw_lines.all? { |line| line.is_a?(Hash) && line["text"].is_a?(String) }

      raw_lines.map do |line|
        {
          created_at: timestamp(line["created"]),
          updated_at: timestamp(line["updated"]),
          user_id: line["userId"].is_a?(String) ? line["userId"] : nil,
        }
      end
    end

    def line_text(line)
      return line if line.is_a?(String)
      return line["text"] if line.is_a?(Hash)

      nil
    end

    def title_line?(line, title)
      line == title || line&.sub(/\A[-*]\s+/, "") == title
    end

    def timestamp(value)
      return nil if value.nil?
      raise ArgumentError, "Scrapbox line timestamp must be numeric: #{value.inspect}" unless value.is_a?(Numeric)

      Time.at(value).utc
    end

    def body_line_count(body)
      body.empty? ? 0 : body.split("\n", -1).length
    end
  end
end
