# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/models"
require "weblog_authoring/webmention_site_publisher"

class WebmentionSitePublisherTest < Minitest::Test
  Body = Data.define(:body)

  class Database
    attr_reader :completed, :failed

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

    def complete_webmention_outbox(id)
      @completed = id
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
      raise "unexpected shell" unless bucket == "site" && key == "index.html"

      Body.new(StringIO.new('<html><head><link rel="webmention" href="/api/webmentions"></head><body><div id="authoring-root"></div></body></html>'))
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
    jobs = services.messages.map { |message| JSON.parse(message.fetch(:message_body)) }
    targets = jobs.map { |job| job.fetch("target") }

    assert_includes html, '<a href="https://target.example/post">Target</a>'
    assert_includes html, '<link rel="webmention" href="/api/webmentions">'
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

  def test_unpublished_page_removes_static_routes_without_queuing_deliveries
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
    assert_empty services.messages
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
end
