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
      return "/#{page.route}" unless page.nil?
      return nil if mode == "public"

      "/#{name}"
    end

    def render_problems(problems)
      items = problems.map { |problem| "<li>#{CGI.escapeHTML(problem.to_s)}</li>" }.join
      "<section class=\"markdown-problems\"><h2>問題</h2><ul>#{items}</ul></section>"
    end

    def render_backlinks(backlinks, mode)
      return "" if backlinks.empty?

      items = backlinks.map do |backlink|
        "<li>#{internal_link(backlink.display_title, "/#{backlink.route}", mode)}</li>"
      end.join
      "<section class=\"backlinks\"><h2>リンク元</h2><ul>#{items}</ul></section>"
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

        return format_as_span_html("a", { "href" => href }, inner(el, indent)) if href.match?(ALLOWED_EXTERNAL_URI)

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
        return super if safe_html_element?(el)

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

      def highlighted_code(text, language)
        return nil if language.nil? || language.empty?

        lexer = Rouge::Lexer.find_fancy(language, text)
        return nil if lexer.nil? || lexer.tag == "plaintext"

        Rouge::Formatters::HTML.new.format(lexer.lex(text))
      rescue StandardError
        nil
      end

      def highlighted_block_html(highlighted, language, attr, indent)
        classes = [attr["class"], "language-#{language}", "highlighter-rouge"].compact.reject(&:empty?).join(" ")
        attr = attr.merge("class" => classes)
        code_attr = { "class" => "highlight" }

        "#{' ' * indent}<div#{html_attributes(attr)}><pre#{html_attributes(code_attr)}><code>#{highlighted}</code></pre></div>\n"
      end

      def fallback_codeblock_html(text, language, attr, indent)
        code_attr = {}
        code_attr["class"] = "language-#{language}" unless language.nil? || language.empty?
        escaped = CGI.escapeHTML(text)

        "#{' ' * indent}<pre#{html_attributes(attr)}><code#{html_attributes(code_attr)}>#{escaped}</code></pre>\n"
      end
    end
  end
end
