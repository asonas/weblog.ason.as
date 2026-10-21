# frozen_string_literal: true

require "kramdown-parser-gfm"
require "kramdown"

module Kramdown
  module Parser
    class WeblogGFM < GFM
      def initialize(source, options)
        super
        @span_parsers << :bare_url
        @span_parsers << :spoiler
        @block_parsers.unshift(:spoiler_block)
      end

      def parse_spoiler
        saved = @src.save_pos
        @src.pos += 2
        element = Element.new(:spoiler, nil, nil, location: @src.current_line_number)
        if parse_spans(element, /\|\||\n\n/) && @src.scan(/\|\|/) && !element.children.empty?
          @tree.children << element
        else
          @src.revert_pos(saved)
          @src.pos += 2
          add_text(+"||")
        end
      end
      define_parser(:spoiler, /\|\|(?=\S)/, '\|\|')

      def parse_table
        if @src.check(/[^\n]*\|\|[^\n]*\n/) && !@src.check(/[^\n]*\n#{TABLE_SEP_LINE}/)
          return false
        end

        super
      end

      def parse_spoiler_block
        return false unless @src.check(/^\|\|[ \t]*\n([\s\S]+?)^\|\|[ \t]*(?:\n|\z)/)

        @src.scan(/^\|\|[ \t]*\n([\s\S]+?)^\|\|[ \t]*(?:\n|\z)/)
        body = @src[1]
        element = new_block_el(:spoiler_block)
        @tree.children << element
        parse_blocks(element, body)
        true
      end
      define_parser(:spoiler_block, /^\|\|[ \t]*\n/)

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
