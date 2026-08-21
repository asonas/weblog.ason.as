# frozen_string_literal: true

require "cgi"
require "kramdown"
require "kramdown-parser-gfm"
require "rouge"

require_relative "links"
require_relative "models"
require_relative "names"

module WeblogAuthoring
  RenderedMarkdown = Struct.new(:html, :links, :problems, keyword_init: true) do
    def initialize(html:, links:, problems:)
      super(html:, links: Array(links).freeze, problems: Array(problems).freeze)
      freeze
    end
  end

  class MarkdownRenderer
    WIKI_SENTINEL_PREFIX = "weblog-authoring-wiki://".freeze
    INTERNAL_REL = "noopener noreferrer".freeze
    MODES = %w[local public].freeze
    CONTEXT_KEY = :weblog_authoring_markdown_context

    def initialize(pages: [])
      @pages_by_name = {}

      Array(pages).each do |page|
        next unless page.is_a?(PageDocument)
        next unless page.page_type == "named"
        next if page.name.nil?

        @pages_by_name[page.name] = page
      end
    end

    def render(body, mode:)
      validate_mode!(mode)

      source = body.to_s
      links = WeblogAuthoring.extract_wiki_links(source)
      prepared_body, wiki_targets, preparation_problems = prepare_wiki_links(source, links, mode)
      document = Kramdown::Document.new(
        prepared_body,
        input: "GFM",
        parse_block_html: false,
        parse_span_html: false,
        smart_quotes: %w[apos apos quot quot]
      )

      html, converter_warnings = SafeHtmlConverter.with_context(mode:, wiki_targets:) do
        SafeHtmlConverter.convert(document.root, document.options)
      end

      document_warnings = document.respond_to?(:warnings) ? Array(document.warnings) : []
      problems = preparation_problems + document_warnings + Array(converter_warnings)
      RenderedMarkdown.new(html:, links:, problems:)
    rescue Kramdown::Error => error
      RenderedMarkdown.new(
        html: "<pre><code>#{CGI.escapeHTML(source)}</code></pre>\n",
        links:,
        problems: [error.message]
      )
    end

    def render_page(page, backlinks:, mode:)
      validate_mode!(mode)

      rendered = render(page.body, mode:)
      sections = []
      sections << "<header class=\"page-header\"><h1>#{CGI.escapeHTML(page.display_title.to_s)}</h1></header>"
      sections << render_problems(rendered.problems) unless rendered.problems.empty?
      sections << if page.empty?
                    "<p>まだ内容がありません</p>"
                  else
                    rendered.html.chomp
                  end

      backlinks_html = render_backlinks(Array(backlinks), mode)
      sections << backlinks_html unless backlinks_html.empty?

      "<article class=\"page-view\">\n#{indent_html(sections.join("\n"), 2)}\n</article>\n"
    end

    private

    def validate_mode!(mode)
      return if MODES.include?(mode)

      raise ArgumentError, "unknown render mode: #{mode.inspect}"
    end

    def prepare_wiki_links(body, links, mode)
      prepared = body.dup
      wiki_targets = {}
      problems = []
      replacements = []

      links.each_with_index do |link, index|
        begin
          name = WeblogAuthoring.validate_page_name(link.name)
        rescue ArgumentError => error
          problems << "wiki link omitted: #{error.message}"
          replacements << [link.start, link.end, escape_markdown_text(link.name)]
          next
        end

        route = wiki_route_for(name, mode)
        if route.nil?
          problems << "wiki link omitted in public output: #{name}"
          replacements << [link.start, link.end, escape_markdown_text(name)]
          next
        end

        token = "#{WIKI_SENTINEL_PREFIX}#{index}"
        wiki_targets[token] = { "route" => route, "label" => name }
        replacements << [link.start, link.end, "[#{escape_markdown_link_label(name)}](#{token})"]
      end

      replacements.reverse_each do |start_offset, end_offset, replacement|
        prepared = "#{prepared[0...start_offset]}#{replacement}#{prepared[end_offset..] || ''}"
      end

      [prepared, wiki_targets.freeze, problems.freeze]
    end

    def wiki_route_for(name, mode)
      page = @pages_by_name[name]
      return route_href(page.route) unless page.nil?
      return nil if mode == "public"

      "/#{WeblogAuthoring.encoded_route(name)}"
    end

    def render_problems(problems)
      items = problems.map { |problem| "<li>#{CGI.escapeHTML(problem.to_s)}</li>" }.join
      "<section class=\"markdown-problems\"><h2>問題</h2><ul>#{items}</ul></section>"
    end

    def render_backlinks(backlinks, mode)
      return "" if backlinks.empty?

      items = backlinks.map do |backlink|
        "<li>#{internal_link(backlink.display_title, route_href(backlink.route), mode)}</li>"
      end.join
      "<section class=\"backlinks\"><h2>リンク元</h2><ul>#{items}</ul></section>"
    end

    def route_href(route)
      "/#{WeblogAuthoring.encoded_route(route)}"
    end

    def internal_link(text, href, mode)
      attributes = { "href" => href }
      if mode == "local"
        attributes["target"] = "_blank"
        attributes["rel"] = INTERNAL_REL
      end

      "<a#{html_attributes(attributes)}>#{CGI.escapeHTML(text.to_s)}</a>"
    end

    def html_attributes(attributes)
      attributes.each_with_object(+"") do |(name, value), html|
        next if value.nil? || value.to_s.empty?

        html << " #{name}=\"#{CGI.escapeHTML(value.to_s)}\""
      end
    end

    def indent_html(html, spaces)
      prefix = " " * spaces
      html.each_line.map { |line| "#{prefix}#{line.chomp}" }.join("\n")
    end

    def escape_markdown_link_label(text)
      escape_markdown_text(text).gsub("(", "\\(").gsub(")", "\\)")
    end

    def escape_markdown_text(text)
      text.to_s.gsub(/([\\`\[\]()*_{}#+\-!.<>])/, '\\\\\1')
    end

    class SafeHtmlConverter < Kramdown::Converter::Html
      ALLOWED_EXTERNAL_URI = /\A(?:https?:\/\/|mailto:)[^\s]+\z/.freeze
      SAFE_INLINE_HTML = %w[del].freeze
      SAFE_INPUT_ATTRIBUTES = {
        "type" => "checkbox",
        "class" => "task-list-item-checkbox",
        "disabled" => "disabled"
      }.freeze
      SHARED_ATTRIBUTES = %w[class id].freeze
      TAG_ATTRIBUTE_WHITELIST = Hash.new(SHARED_ATTRIBUTES).merge(
        "a" => (SHARED_ATTRIBUTES + %w[href rel target title]).freeze,
        "hr" => SHARED_ATTRIBUTES.freeze,
        "input" => %w[checked class disabled type].freeze,
        "li" => SHARED_ATTRIBUTES.freeze,
        "ol" => (SHARED_ATTRIBUTES + %w[start]).freeze,
        "table" => SHARED_ATTRIBUTES.freeze,
        "td" => (SHARED_ATTRIBUTES + %w[style]).freeze,
        "th" => (SHARED_ATTRIBUTES + %w[style]).freeze
      ).freeze
      SAFE_TEXT_ALIGN_STYLE = /\Atext-align:\s*(left|right|center)\z/.freeze
      SAFE_LIST_START = /\A[1-9]\d*\z/.freeze

      class << self
        def with_context(context)
          previous = Thread.current[MarkdownRenderer::CONTEXT_KEY]
          Thread.current[MarkdownRenderer::CONTEXT_KEY] = context
          yield
        ensure
          Thread.current[MarkdownRenderer::CONTEXT_KEY] = previous
        end

        def context
          Thread.current[MarkdownRenderer::CONTEXT_KEY] || {}
        end
      end

      def convert_p(el, indent)
        if el.options[:transparent]
          inner(el, indent)
        else
          format_as_block_html("p", el.attr, inner(el, indent), indent)
        end
      end

      def convert_a(el, indent)
        href = el.attr["href"].to_s
        if (target = self.class.context.fetch(:wiki_targets, {})[href])
          attributes = { "href" => target.fetch("route") }
          if self.class.context[:mode] == "local"
            attributes["target"] = "_blank"
            attributes["rel"] = MarkdownRenderer::INTERNAL_REL
          end

          return format_as_span_html("a", attributes, CGI.escapeHTML(target.fetch("label")))
        end

        return format_as_span_html("a", el.attr, inner(el, indent)) if href.match?(ALLOWED_EXTERNAL_URI)

        warning("link omitted: #{href}") unless href.empty?
        inner(el, indent)
      end

      def convert_img(el, _indent)
        warning("image omitted: #{el.attr['src']}")

        alt = el.attr["alt"].to_s
        CGI.escapeHTML(alt.empty? ? "[image omitted]" : "[image omitted: #{alt}]")
      end

      def convert_raw(el, indent)
        warning("raw HTML escaped")

        escaped = CGI.escapeHTML(el.value.to_s)
        el.options[:category] == :block ? "#{' ' * indent}#{escaped}\n" : escaped
      end

      def convert_html_element(el, indent)
        return render_safe_html_element(el) if safe_html_element?(el)

        warning("raw HTML escaped: #{el.value}")

        escaped = CGI.escapeHTML(serialized_html_element(el))
        el.options[:category] == :block ? "#{' ' * indent}#{escaped}\n" : escaped
      end

      def convert_xml_comment(el, indent)
        convert_raw(el, indent)
      end
      alias convert_xml_pi convert_xml_comment
      alias convert_comment convert_xml_comment

      def convert_codeblock(el, indent)
        attr = el.attr.dup
        language = extract_code_language!(attr) || el.options[:lang]
        highlighted = highlighted_code(el.value.to_s, language)

        return highlighted_block_html(highlighted, language, attr, indent) unless highlighted.nil?

        warning("syntax highlighting fallback: #{language}") unless language.nil? || language.empty?
        fallback_codeblock_html(el.value.to_s, language, attr, indent)
      end

      def convert_codespan(el, _indent)
        format_as_span_html("code", el.attr, CGI.escapeHTML(el.value.to_s))
      end

      def convert_hr(el, indent)
        "#{' ' * indent}<hr#{sanitized_html_attributes('hr', el.attr)} />\n"
      end

      def convert_li(el, indent)
        output = ' ' * indent << "<#{el.type}" << sanitized_html_attributes(el.type.to_s, el.attr) << ">"
        res = inner(el, indent)
        if el.children.empty? || (el.children.first.type == :p && el.children.first.options[:transparent])
          output << res << (res.match?(/\n\Z/) ? ' ' * indent : '')
        else
          output << "\n" << res << ' ' * indent
        end
        output << "</#{el.type}>\n"
      end
      alias convert_dd convert_li

      def format_as_span_html(name, attr, body)
        "<#{name}#{sanitized_html_attributes(name, attr)}>#{body}</#{name}>"
      end

      def format_as_block_html(name, attr, body, indent)
        "#{' ' * indent}<#{name}#{sanitized_html_attributes(name, attr)}>#{body}</#{name}>\n"
      end

      def format_as_indented_block_html(name, attr, body, indent)
        "#{' ' * indent}<#{name}#{sanitized_html_attributes(name, attr)}>\n#{body}#{' ' * indent}</#{name}>\n"
      end

      private

      def safe_html_element?(el)
        return true if SAFE_INLINE_HTML.include?(el.value) && el.attr.empty?
        return false unless el.value == "input"
        return false unless el.options[:is_closed]

        allowed_attributes = SAFE_INPUT_ATTRIBUTES.dup
        checked = el.attr["checked"] == "checked"
        attributes = el.attr.dup
        attributes.delete("checked") if checked

        attributes == allowed_attributes
      end

      def serialized_html_element(el)
        opening = +"<#{el.value}"
        el.attr.each do |name, value|
          opening << %( #{name}="#{value}")
        end

        if el.options[:is_closed] && el.children.empty?
          "#{opening} />"
        else
          inner_markup = el.children.map { |child| serialized_child_markup(child) }.join
          "#{opening}>#{inner_markup}</#{el.value}>"
        end
      end

      def serialized_child_markup(child)
        case child.type
        when :raw, :text
          child.value.to_s
        when :html_element
          serialized_html_element(child)
        else
          child.children.map { |inner_child| serialized_child_markup(inner_child) }.join
        end
      end

      def render_safe_html_element(el)
        case el.value
        when "del"
          format_as_span_html("del", el.attr, inner(el, indent_for_inline_html))
        when "input"
          "<input#{sanitized_html_attributes('input', el.attr)} />"
        else
          raise ArgumentError, "unsupported safe html element: #{el.value}"
        end
      end

      def indent_for_inline_html
        0
      end

      def sanitized_html_attributes(tag_name, attributes)
        sanitized = sanitize_attributes(tag_name.to_s, attributes)
        html_attributes(sanitized)
      end

      def sanitize_attributes(tag_name, attributes)
        return {} if attributes.nil? || attributes.empty?

        allowed_names = TAG_ATTRIBUTE_WHITELIST.fetch(tag_name, SHARED_ATTRIBUTES)
        sanitized = {}

        attributes.each do |name, value|
          next if value.nil? || value.to_s.empty?

          if !allowed_names.include?(name)
            warning("attribute omitted from <#{tag_name}>: #{name}")
            next
          end

          sanitized_value = sanitize_attribute_value(tag_name, name, value.to_s)
          if sanitized_value.nil?
            warning("attribute omitted from <#{tag_name}>: #{name}")
            next
          end

          sanitized[name] = sanitized_value
        end

        sanitized
      end

      def sanitize_attribute_value(tag_name, name, value)
        case name
        when "href"
          sanitize_href(value)
        when "rel"
          value == MarkdownRenderer::INTERNAL_REL ? value : nil
        when "target"
          value == "_blank" ? value : nil
        when "type"
          tag_name == "input" && value == "checkbox" ? value : nil
        when "disabled"
          tag_name == "input" && value == "disabled" ? value : nil
        when "checked"
          tag_name == "input" && value == "checked" ? value : nil
        when "style"
          sanitize_style(tag_name, value)
        when "start"
          tag_name == "ol" && value.match?(SAFE_LIST_START) ? value : nil
        else
          value
        end
      end

      def sanitize_href(value)
        return value if value.start_with?("/")
        return value if value.match?(ALLOWED_EXTERNAL_URI)

        nil
      end

      def sanitize_style(tag_name, value)
        return nil unless %w[td th].include?(tag_name)
        return value if value.match?(SAFE_TEXT_ALIGN_STYLE)

        nil
      end

      def highlighted_code(text, language)
        return nil if language.nil? || language.empty?

        lexer = Rouge::Lexer.find_fancy(language, text)
        return nil if lexer.nil? || lexer.tag == "plaintext"

        Rouge::Formatters::HTML.new.format(lexer.lex(text))
      rescue ArgumentError, EncodingError, Rouge::Guesser::Ambiguous, Rouge::RegexLexer::InvalidRegex
        nil
      end

      def highlighted_block_html(highlighted, language, attr, indent)
        classes = [attr["class"], "language-#{language}", "highlighter-rouge"].compact.reject(&:empty?).join(" ")
        attr = attr.merge("class" => classes)
        code_attr = { "class" => "highlight" }

        "#{' ' * indent}<div#{sanitized_html_attributes('div', attr)}><pre#{sanitized_html_attributes('pre', code_attr)}><code>#{highlighted}</code></pre></div>\n"
      end

      def fallback_codeblock_html(text, language, attr, indent)
        code_attr = {}
        code_attr["class"] = "language-#{language}" unless language.nil? || language.empty?
        escaped = CGI.escapeHTML(text)

        "#{' ' * indent}<pre#{sanitized_html_attributes('pre', attr)}><code#{sanitized_html_attributes('code', code_attr)}>#{escaped}</code></pre>\n"
      end
    end
  end
end
