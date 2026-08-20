# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/markdown"

class TestMarkdown < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-01-01T00:00:00+09:00")

  def test_local_render_supports_gfm_extensions_and_highlighted_wiki_links
    renderer = WeblogAuthoring::MarkdownRenderer.new(pages: [named_page("page-a")])
    rendered = renderer.render(
      <<~MARKDOWN,
        | A | B |
        | --- | --- |
        | 1 | 2 |

        - [x] done

        ~~old~~

        ```ruby
        puts 1
        ```

        [[page-a]]
      MARKDOWN
      mode: "local"
    )

    assert_equal ["page-a"], rendered.links.map(&:name)
    assert_includes rendered.html, "<table>"
    assert_includes rendered.html, 'type="checkbox"'
    assert_includes rendered.html, "<del>old</del>"
    assert_includes rendered.html, 'class="language-ruby highlighter-rouge"'
    assert_includes rendered.html, '<span class="nb">puts</span>'
    assert_includes rendered.html, 'href="/page-a"'
    assert_includes rendered.html, 'target="_blank"'
    assert_includes rendered.html, 'rel="noopener noreferrer"'
  end

  def test_unknown_code_language_falls_back_to_escaped_code_block
    renderer = WeblogAuthoring::MarkdownRenderer.new

    rendered = renderer.render("```unknown\n<hi>\n```\n", mode: "local")

    assert_includes rendered.html, "<pre><code class=\"language-unknown\">"
    assert_includes rendered.html, "&lt;hi&gt;"
    refute_includes rendered.html, "highlighter-rouge"
    assert_includes rendered.problems, "syntax highlighting fallback: unknown"
  end

  def test_raw_html_images_and_unsafe_links_are_not_emitted
    renderer = WeblogAuthoring::MarkdownRenderer.new

    rendered = renderer.render(
      <<~MARKDOWN,
        <script>alert(1)</script>

        ![alt](x.png)

        [attachment](./report.pdf)

        [bad](javascript:alert(1))
      MARKDOWN
      mode: "local"
    )

    refute_includes rendered.html, "<script>"
    assert_includes rendered.html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes rendered.html, "<img"
    refute_includes rendered.html, 'href="./report.pdf"'
    refute_includes rendered.html, 'href="javascript:alert(1)"'
    assert_includes rendered.html, "[image omitted: alt]"
    assert_includes rendered.problems, "image omitted: x.png"
    assert_includes rendered.problems, "link omitted: ./report.pdf"
    assert_includes rendered.problems, "link omitted: javascript:alert(1)"
  end

  def test_attribute_injection_is_stripped_across_block_inline_table_and_code_paths
    renderer = WeblogAuthoring::MarkdownRenderer.new

    rendered = renderer.render(
      <<~MARKDOWN,
        hello
        {: onclick="alert(1)"}

        [safe](https://example.com){: title="A \\"quote\\" & more" onclick="alert(2)"}

        | A |
        | --- |
        | 1 |
        {: onclick="alert(3)"}

        ```ruby
        puts 1
        ```
        {: onclick="alert(4)"}
      MARKDOWN
      mode: "local"
    )

    refute_includes rendered.html, "onclick="
    assert_includes rendered.html, "<p>hello</p>"
    assert_includes rendered.html, 'href="https://example.com"'
    assert_includes rendered.html, 'title="A &quot;quote&quot; &amp; more"'
    assert_includes rendered.html, "<table>"
    assert_includes rendered.html, 'class="language-ruby highlighter-rouge"'
    assert_includes rendered.problems, "attribute omitted from <p>: onclick"
    assert_includes rendered.problems, "attribute omitted from <a>: onclick"
    assert_includes rendered.problems, "attribute omitted from <table>: onclick"
    assert_includes rendered.problems, "attribute omitted from <div>: onclick"
  end

  def test_aligned_table_keeps_safe_alignment_style
    renderer = WeblogAuthoring::MarkdownRenderer.new

    rendered = renderer.render(
      <<~MARKDOWN,
        | Left | Right |
        | :-- | --: |
        | a | b |
      MARKDOWN
      mode: "local"
    )

    assert_includes rendered.html, 'style="text-align: left"'
    assert_includes rendered.html, 'style="text-align: right"'
    refute_includes rendered.html, "onclick="
    assert_empty rendered.problems
  end

  def test_public_render_keeps_saved_links_same_tab_and_omits_unsaved_targets
    renderer = WeblogAuthoring::MarkdownRenderer.new(pages: [named_page("page-a")])

    rendered = renderer.render("[[page-a]] [[draft page]]", mode: "public")

    assert_includes rendered.html, 'href="/page-a"'
    refute_includes rendered.html, 'target="_blank"'
    refute_includes rendered.html, 'href="/draft page"'
    assert_includes rendered.html, "draft page"
    assert_includes rendered.problems, "wiki link omitted in public output: draft page"
  end

  def test_public_render_encodes_named_routes_for_wikilinks_and_backlinks
    named = named_page("Page-A")
    date = date_page("2026-01-01")
    renderer = WeblogAuthoring::MarkdownRenderer.new(pages: [named, date])

    rendered = renderer.render("[[Page-A]]", mode: "public")
    local_rendered = renderer.render("[[Page-A]]", mode: "local")
    page_html = renderer.render_page(named_page("page-b"), backlinks: [named, date], mode: "public")

    assert_includes rendered.html, 'href="/%50age-%41"'
    refute_includes rendered.html, 'href="/Page-A"'
    assert_includes local_rendered.html, 'href="/Page-A"'
    assert_includes page_html, 'href="/%50age-%41"'
    assert_includes page_html, 'href="/2026-01-01"'
    refute_includes page_html, 'target="_blank"'
  end

  def test_wiki_links_escape_html_in_text_and_href
    tricky = named_page('quote " & name')
    renderer = WeblogAuthoring::MarkdownRenderer.new(pages: [tricky])

    rendered = renderer.render('[[quote " & name]]', mode: "local")

    assert_includes rendered.html, 'href="/quote &quot; &amp; name"'
    assert_includes rendered.html, 'quote &quot; &amp; name</a>'
  end

  def test_render_page_shows_empty_message_and_backlinks
    page = named_page("page-a", body: "")
    backlink = named_page("page-b")
    renderer = WeblogAuthoring::MarkdownRenderer.new(pages: [page, backlink])

    html = renderer.render_page(page, backlinks: [backlink], mode: "local")

    assert_includes html, "<article"
    assert_includes html, "まだ内容がありません"
    assert_includes html, "リンク元"
    assert_includes html, 'href="/page-b"'
    assert_includes html, 'target="_blank"'
  end

  private

  def named_page(name, body: "本文")
    WeblogAuthoring::PageDocument.new(
      id: "page-#{name}",
      page_type: "named",
      name:,
      page_date: nil,
      title: nil,
      status: "draft",
      created_at: FIXED_TIME,
      updated_at: FIXED_TIME,
      published_at: nil,
      path: Pathname("/tmp/#{name}.md"),
      body:,
      links: []
    )
  end

  def date_page(date_string)
    page_date = Date.iso8601(date_string)
    WeblogAuthoring::PageDocument.new(
      id: "date-#{date_string}",
      page_type: "date",
      name: nil,
      page_date:,
      title: nil,
      status: "published",
      created_at: FIXED_TIME,
      updated_at: FIXED_TIME,
      published_at: FIXED_TIME,
      path: Pathname("/tmp/#{date_string}.md"),
      body: "本文",
      links: []
    )
  end
end
