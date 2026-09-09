# frozen_string_literal: true

require_relative "../test_helper"
require "rexml/document"
require "weblog_authoring/models"
require "weblog_authoring/webmention_site_publisher"

class WebmentionSitePublisherTest < Minitest::Test
  Body = Data.define(:body)

  class Database
    attr_reader :completed, :completed_revision, :failed

    def initialize(page:, outbox:)
      @page = page
      @outbox = outbox
    end

    def find(id)
      @page if id == @page.id
    end

    def list_pages
      [@page]
    end

    def approved_webmentions_for_page(_id)
      [{
        "id" => "mention-id", "source_url" => "https://mention.example/post",
        "title" => "Mention", "site_name" => "Mention Site", "first_verified_at" => nil,
      }]
    end

    def webmention_outbox(id)
      @outbox if id == @outbox.fetch("id")
    end

    def complete_webmention_outbox(id, revision: nil)
      @completed = id
      @completed_revision = revision
      true
    end

    def fail_webmention_outbox(id)
      @failed = id
    end
  end

  class Services
    attr_reader :puts, :deletes, :messages, :invalidations

    def initialize
      @puts = []
      @deletes = []
      @messages = []
      @invalidations = []
    end

    def get_object(bucket:, key:)
      raise "unexpected shell" unless bucket == "site" && key == "static/authoring/public.html"

      Body.new(StringIO.new('<html><head><title>weblog.ason.as</title><link rel="webmention" href="/api/webmentions" /></head><body><div id="authoring-root"></div></body></html>'))
    end

    def put_object(**request)
      puts << request
    end

    def delete_object(**request)
      deletes << request
    end

    def create_invalidation(**request)
      invalidations << request
    end

    def send_message(**request)
      messages << request
    end
  end

  def microformat_element(root, class_name)
    REXML::XPath.each(root, ".//*[@class]").find do |element|
      element.attributes.fetch("class").value.split.include?(class_name)
    end
  end

  def microformat_text(element)
    REXML::XPath.match(element, ".//text()").map(&:value).join
  end

  def test_encodes_apostrophes_in_cache_invalidation_paths
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "Don't use click here", page_date: nil, title: nil,
      status: "published", created_at: Time.now, updated_at: Time.now, published_at: Time.now,
      path: Pathname("content/pages/article.md"), body: "本文", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "source_url" => "https://weblog.ason.as/Don't%20use%20click%20here",
        "previous_targets" => [], "current_targets" => [],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue"
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])

    assert_equal ["/Don%27t%20use%20click%20here"],
      services.invalidations.fetch(0).dig(:invalidation_batch, :paths, :items)
  end

  def test_publishes_verifiable_html_before_queuing_the_target_union
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "記事", page_date: nil, title: nil,
      status: "published", created_at: Time.now, updated_at: Time.now, published_at: Time.now,
      path: Pathname("content/pages/article.md"), body: "[Target](https://target.example/post)", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "source_url" => "https://weblog.ason.as/%E8%A8%98%E4%BA%8B",
        "previous_source_url" => "https://weblog.ason.as/old-route",
        "previous_targets" => ["https://old.example/post"],
        "current_targets" => ["https://target.example/post"],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue"
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])
    html = services.puts.fetch(0).fetch(:body)
    head = REXML::Document.new(html[/<head>.*<\/head>/m]).root
    assert_equal "記事 | weblog.ason.as", head.elements["title"].text
    assert_equal "記事", head.elements["meta[@property='og:title']"].attributes["content"]
    assert_equal "Target", head.elements["meta[@name='description']"].attributes["content"]
    assert_equal "https://weblog.ason.as/%E8%A8%98%E4%BA%8B", head.elements["link[@rel='canonical']"].attributes["href"]
    assert_nil head.elements["meta[@property='og:image']"]
    assert_includes html, 'data-public-article="1"'
    assert_includes html, 'href="/editor/page-id"'
    article = REXML::Document.new(html[/<article\b.*<\/article>/m]).root
    jobs = services.messages.map { |message| JSON.parse(message.fetch(:message_body)) }
    targets = jobs.map { |job| job.fetch("target") }

    assert_includes article.attributes.fetch("class").value.split, "h-entry"
    assert_equal "記事", microformat_element(article, "p-name").text
    assert_includes microformat_text(microformat_element(article, "e-content")), "Target"
    assert_equal "https://weblog.ason.as/%E8%A8%98%E4%BA%8B",
                 microformat_element(article, "u-url").attributes.fetch("href").value
    author = microformat_element(article, "p-author")
    assert_includes author.attributes.fetch("class").value.split, "h-card"
    assert_equal "asonas", microformat_element(author, "p-name").text
    assert_includes html, '<a href="https://target.example/post">Target</a>'
    assert_includes html, '<link rel="webmention" href="/api/webmentions" />'
    assert_includes html, "外部からの言及"
    assert_equal ["https://old.example/post", "https://target.example/post"], targets
    assert_equal "https://weblog.ason.as/old-route", jobs.fetch(0).fetch("source")
    assert_equal "https://weblog.ason.as/%E8%A8%98%E4%BA%8B", jobs.fetch(1).fetch("source")
    assert_equal({ bucket: "site", key: "old-route" }, services.deletes.fetch(0))
    invalidated = services.invalidations.fetch(0).dig(:invalidation_batch, :paths, :items)
    assert_equal ["/%E8%A8%98%E4%BA%8B", "/old-route"], invalidated
    assert_equal "outbox-id", database.completed
    assert_nil database.failed
  end

  def test_publishes_when_desired_update_matches_at_database_precision
    updated_at = Time.iso8601("2026-09-05T14:07:20.000000000+00:00")
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "2026-09-05", page_date: nil, title: nil,
      status: "published", created_at: updated_at, updated_at:, published_at: updated_at,
      path: Pathname("content/pages/2026-09-05.md"),
      body: "[Webmention Rocks](https://webmention.rocks/test/1)", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "desired_updated_at" => "2026-09-05T23:07:20.570575534+09:00",
        "source_url" => "https://weblog.ason.as/2026-09-05",
        "previous_source_url" => nil, "previous_targets" => [],
        "current_targets" => ["https://webmention.rocks/test/1"],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue"
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])

    assert_equal 1, services.puts.length
    assert_equal 1, services.messages.length
    assert_equal "outbox-id", database.completed
  end

  def test_public_article_keeps_media_and_escaped_metadata_without_editor_data
    page = WeblogAuthoring::PageDocument.new(
      id: "public-media", page_type: "named", name: '画像 & "動画"', title: nil,
      status: "published", created_at: Time.now, updated_at: Time.now, published_at: Time.now,
      path: Pathname("content/pages/media.md"),
      body: "読むための本文。\n\n![写真](/assets/photo.webp)\n\n![次の写真](/assets/other.webp)\n\n:::video /assets/uploads/2026/09/abc.mp4 1080x1920 :::\n\nhttps://speakerdeck.com/asonas/example", links: []
    )
    outbox = { "id" => "media", "page_id" => page.id, "payload" => { "source_url" => "https://weblog.ason.as/Media" } }
    services = Services.new
    WeblogAuthoring::WebmentionSitePublisher.new(
      database: Database.new(page:, outbox:), s3_client: services, cloudfront_client: services,
      sqs_client: services, site_bucket: "site", distribution_id: "distribution",
      delivery_queue_url: "queue", sender_enabled: false
    ).publish(outbox)
    html = services.puts.fetch(0).fetch(:body)
    assert_includes html, '<meta property="og:title" content="画像 &amp; &quot;動画&quot;" />'
    assert_includes html, '<meta property="og:image" content="https://weblog.ason.as/assets/photo.webp" />'
    assert_includes html, 'fetchpriority="high"'
    assert_includes html, 'loading="eager"'
    assert_includes html, 'loading="lazy"'
    assert_includes html, 'class="article-reading-header article-reading-header--covered"'
    refute_includes html, 'class="article-image" style="aspect-ratio: 16 / 9"'
    universe = REXML::Document.new(html[/<div data-public-universe="[^"]*"><\/div>/]).root
    assert_equal page.route, JSON.parse(universe.attributes["data-public-universe"]).fetch("route")
    assert_includes html, 'width="1080" height="1920"'
    assert_includes html, 'href="https://speakerdeck.com/asonas/example"'
    assert_includes html, "読むための本文。"
    refute_includes html, "authoring-data"
  end

  def test_skips_an_outbox_for_an_older_page_update
    updated_at = Time.iso8601("2026-09-05T14:07:21+00:00")
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "2026-09-05", page_date: nil, title: nil,
      status: "published", created_at: updated_at, updated_at:, published_at: updated_at,
      path: Pathname("content/pages/2026-09-05.md"),
      body: "[Webmention Rocks](https://webmention.rocks/test/1)", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "desired_updated_at" => "2026-09-05T23:07:20.570575534+09:00",
        "source_url" => "https://weblog.ason.as/2026-09-05",
        "previous_source_url" => nil, "previous_targets" => [],
        "current_targets" => ["https://webmention.rocks/test/1"],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue"
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])

    assert_empty services.puts
    assert_empty services.messages
    assert_nil database.completed
  end

  def test_unpublished_page_removes_static_routes_and_queues_removal_deliveries
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "記事", page_date: nil, title: nil,
      status: "published", created_at: Time.now, updated_at: Time.now, published_at: Time.now,
      path: Pathname("content/pages/article.md"), body: "", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "source_url" => "https://weblog.ason.as/%E8%A8%98%E4%BA%8B",
        "previous_source_url" => "https://weblog.ason.as/old-route",
        "previous_targets" => ["https://old.example/post"], "current_targets" => [],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue"
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])

    assert_empty services.puts
    assert_equal(
      [{ bucket: "site", key: "記事" }, { bucket: "site", key: "old-route" }], services.deletes
    )
    jobs = services.messages.map { |message| JSON.parse(message.fetch(:message_body)) }
    assert_equal [{
      "type" => "deliver", "delivery_id" => jobs.fetch(0).fetch("delivery_id"),
      "page_id" => "page-id", "source" => "https://weblog.ason.as/old-route",
      "target" => "https://old.example/post",
    }], jobs
    invalidated = services.invalidations.fetch(0).dig(:invalidation_batch, :paths, :items)
    assert_equal ["/%E8%A8%98%E4%BA%8B", "/old-route"], invalidated
    assert_equal "outbox-id", database.completed
    assert_nil database.failed
  end

  def test_sender_can_remain_stopped_while_static_publishing_is_enabled
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "記事", page_date: nil, title: nil,
      status: "published", created_at: Time.now, updated_at: Time.now, published_at: Time.now,
      path: Pathname("content/pages/article.md"), body: "[Target](https://target.example/post)", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "source_url" => "https://weblog.ason.as/%E8%A8%98%E4%BA%8B",
        "previous_source_url" => nil, "previous_targets" => [],
        "current_targets" => ["https://target.example/post"],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue",
      sender_enabled: false
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])

    assert_equal 1, services.puts.length
    assert_empty services.messages
    assert_equal "outbox-id", database.completed
  end

  def test_body_only_refresh_with_the_same_targets_does_not_queue_deliveries
    page = WeblogAuthoring::PageDocument.new(
      id: "page-id", page_type: "named", name: "記事", page_date: nil, title: nil,
      status: "published", created_at: Time.now, updated_at: Time.now, published_at: Time.now,
      path: Pathname("content/pages/article.md"), body: "本文", links: []
    )
    outbox = {
      "id" => "outbox-id", "page_id" => page.id,
      "payload" => {
        "source_url" => "https://weblog.ason.as/%E8%A8%98%E4%BA%8B",
        "previous_source_url" => "https://weblog.ason.as/%E8%A8%98%E4%BA%8B",
        "previous_targets" => ["https://target.example/post"],
        "current_targets" => ["https://target.example/post"],
      },
    }
    database = Database.new(page:, outbox:)
    services = Services.new
    publisher = WeblogAuthoring::WebmentionSitePublisher.new(
      database:, s3_client: services, cloudfront_client: services, sqs_client: services,
      site_bucket: "site", distribution_id: "distribution", delivery_queue_url: "queue"
    )

    publisher.call("Records" => [{ "body" => JSON.generate("outbox_id" => "outbox-id") }])

    assert_empty services.messages
    assert_equal "outbox-id", database.completed
  end
end
