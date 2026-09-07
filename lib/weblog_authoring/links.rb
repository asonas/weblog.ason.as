# frozen_string_literal: true

require "digest"

module WeblogAuthoring
  LINK_PATTERN = /\[\[([^\[\]]+)\]\]/.freeze
  EXTERNAL_URL_PATTERN = %r{https?://[^\s<>\[\]\\"')]+}.freeze
  FENCE_PATTERN = /^\s*(`{3,}|~{3,})/.freeze
  INLINE_CODE_PATTERN = /(`+).*?\1/.freeze

  module_function

  def extract_wiki_links(body)
    links = []

    each_segment(body) do |line, offset, fenced|
      next if fenced

      line.to_enum(:scan, LINK_PATTERN).each do
        match = Regexp.last_match
        name = match[1].strip
        next if name.empty?

        links << WikiLink.new(name:, start: offset + match.begin(0), end: offset + match.end(0))
      end
    end

    links.freeze
  end

  def replace_wiki_links(body, old_name:, new_name:)
    replacements = extract_wiki_links(body).select { |link| link.name == old_name }

    replacements.reverse_each do |link|
      body = "#{body[0...link.start]}[[#{new_name}]]#{body[link.end..] || ''}"
    end

    body
  end

  def extract_external_urls(body)
    urls = []

    each_segment(body) do |line, _offset, fenced|
      next if fenced

      line.gsub(INLINE_CODE_PATTERN, "").scan(EXTERNAL_URL_PATTERN) do |url|
        normalized = url.gsub(/\\(?=[^\w\s]|_)/, "").sub(/[.,;:!?]+\z/, "")
        urls << normalized unless urls.include?(normalized)
      end
    end

    urls.freeze
  end

  def page_name_entries(pages)
    entries = []
    names = {}
    activity_by_name = {}
    order_by_name = {}

    pages.each do |page|
      name = page.route
      next if names.key?(name)

      names[name] = true
      activity_by_name[name] = page.updated_at
      order_by_name[name] = order_by_name.length
      entries << { "id" => page.id, "name" => name, "materialized" => true }
    end

    pages.each do |page|
      page.links.each do |link|
        current_activity = activity_by_name[link.name]
        if page.updated_at && (current_activity.nil? || page.updated_at > current_activity)
          activity_by_name[link.name] = page.updated_at
        end
        next if names.key?(link.name)

        names[link.name] = true
        order_by_name[link.name] = order_by_name.length
        entries << {
          "id" => "hub-#{Digest::SHA256.hexdigest(link.name)[0, 32]}",
          "name" => link.name,
          "materialized" => false,
        }
      end
    end

    entries.sort do |left, right|
      left_name = left.fetch("name")
      right_name = right.fetch("name")
      left_activity = activity_by_name[left_name]
      right_activity = activity_by_name[right_name]
      activity_order = if left_activity && right_activity
                         right_activity <=> left_activity
                       elsif left_activity
                         -1
                       elsif right_activity
                         1
                       else
                         0
                       end
      activity_order.zero? ? order_by_name.fetch(left_name) <=> order_by_name.fetch(right_name) : activity_order
    end.freeze
  end

  def each_segment(body)
    return enum_for(:each_segment, body) unless block_given?

    offset = 0
    fence = nil

    body.each_line do |line|
      match = FENCE_PATTERN.match(line)
      was_fenced = !fence.nil?

      if match
        marker = match[1]
        marker_type = marker[0]
        marker_length = marker.length
        if fence.nil?
          fence = [marker_type, marker_length]
        elsif marker_type == fence[0] && marker_length >= fence[1]
          fence = nil
        end
      end

      yield line, offset, was_fenced || !match.nil?
      offset += line.length
    end
  end
  private_class_method :each_segment
end
