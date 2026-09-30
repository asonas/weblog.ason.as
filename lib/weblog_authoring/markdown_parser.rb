# frozen_string_literal: true

require "kramdown-parser-gfm"

module Kramdown
  module Parser
    class WeblogGFM < GFM
      def initialize(source, options)
        super
        @span_parsers << :bare_url
      end

      def parse_bare_url
        if @tree.children.last&.type == :text && @tree.children.last.value.end_with?("[embed:")
          text = @src.matched
          @src.pos += text.bytesize
          add_text(text)
          return
        end
        if [@tree, *@stack.map(&:first)].compact.any? { |node| %i[a img].include?(node.type) }
          add_text(@src.getch)
          return
        end

        url = @src.matched.sub(/[.,:;!?]+\z/, "")
        url = url.chop.sub(/[.,:;!?]+\z/, "") while url.end_with?(")") && url.count(")") > url.count("(")
        element = Element.new(:a, nil, { "href" => url }, location: @src.current_line_number)
        add_text(url, element)
        @tree.children << element
        @src.pos += url.bytesize
      end

      define_parser(:bare_url, %r{https?://[^\s<>\[\]`"'。、！？「」『』（）]+}, 'https?://')
    end
  end
end
