# frozen_string_literal: true

module WeblogAuthoring
  LINK_PATTERN = /\[\[([^\[\]]+)\]\]/.freeze
  FENCE_PATTERN = /^\s*(`{3,}|~{3,})/.freeze

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
