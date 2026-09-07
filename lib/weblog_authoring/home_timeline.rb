# frozen_string_literal: true

require "base64"
require "json"
require "time"

module WeblogAuthoring
  class HomeTimeline
    PAGE_SIZE = 12
    KEY_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/

    def self.key(page)
      if page.links.any? { |link| link.name == "日記" } && /\A\d{4}-\d{2}-\d{2}\z/.match?(page.route)
        "#{page.route}T00:00:00"
      else
        page.updated_at.getlocal(32_400).strftime("%Y-%m-%dT%H:%M:%S")
      end
    end

    def initialize(database)
      @database = database
    end

    def window(query)
      month = query["month"]
      raise ArgumentError, "monthはYYYY-MM形式で指定してください" if month && !/\A\d{4}-(0[1-9]|1[0-2])\z/.match?(month)
      before = decode(query["before"])
      after = decode(query["after"])
      raise ArgumentError, "beforeとafterは同時に指定できません" if before && after

      pages = @database.list_timeline_pages(limit: PAGE_SIZE + 1, before:, after:, month:)
      has_more = pages.length > PAGE_SIZE
      pages = after ? pages.last(PAGE_SIZE) : pages.first(PAGE_SIZE)
      has_newer = if after
                    has_more
                  elsif before && pages.any?
                    @database.list_timeline_pages(limit: 1, after: cursor(pages.first), month:).any?
                  else
                    false
                  end
      {
        "pages" => pages,
        "newer_cursor" => pages.empty? ? nil : encode(pages.first),
        "older_cursor" => pages.empty? ? nil : encode(pages.last),
        "has_newer" => has_newer,
        "has_older" => after && pages.any? ? @database.list_timeline_pages(limit: 1, before: cursor(pages.last), month:).any? : has_more,
      }
    end

    private

    def cursor(page)
      { key: self.class.key(page), id: page.id }
    end

    def encode(page)
      Base64.urlsafe_encode64(JSON.generate([self.class.key(page), page.id]), padding: false)
    end

    def decode(value)
      return nil if value.to_s.empty?

      pair = JSON.parse(Base64.urlsafe_decode64(value.to_s))
      unless pair.is_a?(Array) && pair.length == 2 && pair[0].is_a?(String) && KEY_PATTERN.match?(pair[0]) && pair[1].is_a?(String)
        raise ArgumentError, "カーソルが不正です"
      end
      { key: pair[0], id: pair[1] }
    rescue JSON::ParserError, ArgumentError
      raise ArgumentError, "カーソルが不正です"
    end
  end
end
