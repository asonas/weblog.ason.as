# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/rss_feed"

class RssFeedTest < Minitest::Test
  def test_renders_recent_non_empty_published_pages_with_body_html
    article = page(
      name: "記事 & 一覧",
      body: "本文 **です** [[関連]]",
      updated_at: Time.iso8601("2026-08-23T12:00:00+09:00")
    )
    related = page(name: "関連", body: "関連本文", updated_at: Time.iso8601("2026-08-22T12:00:00+09:00"))
    empty_hub = page(name: "空", body: "", updated_at: Time.iso8601("2026-08-24T12:00:00+09:00"))
    draft = page(name: "下書き", body: "非公開", status: "draft")

    feed = WeblogAuthoring::RssFeed.new(site_url: "https://weblog.ason.as").render(
      [empty_hub, draft, related, article]
    )

    assert_includes feed, "<title>記事 &amp; 一覧</title>"
    assert_includes feed, "本文 &lt;strong&gt;です&lt;/strong&gt;"
    assert_includes feed, "href=&quot;https://weblog.ason.as/%E9%96%A2%E9%80%A3&quot;"
    assert_includes feed, "<link>https://weblog.ason.as/%E8%A8%98%E4%BA%8B%20%26%20%E4%B8%80%E8%A6%A7</link>"
    refute_includes feed, "空"
    refute_includes feed, "下書き"
  end

  private

  def page(name:, body:, updated_at: Time.iso8601("2026-08-21T12:00:00+09:00"), status: "published")
    WeblogAuthoring::PageDocument.new(
      id: name,
      page_type: "named",
      name:,
      page_date: nil,
      title: nil,
      status:,
      created_at: updated_at,
      updated_at:,
      published_at: status == "published" ? updated_at : nil,
      path: Pathname("content/#{name}.md"),
      body:,
      links: WeblogAuthoring.extract_wiki_links(body)
    )
  end
end
