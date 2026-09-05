# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require_relative "../../lib/weblog_authoring/publication_refresh_backfill"

class PublicationRefreshBackfillTest < Minitest::Test
  Page = Struct.new(:id, :route, :status, :body) do
    def empty?
      body.strip.empty?
    end
  end

  class Database
    attr_reader :requested_ids

    def initialize(pages)
      @pages = pages
      @requested_ids = []
    end

    def list_pages
      @pages
    end

    def request_publication_refresh(page_id)
      @requested_ids << page_id
    end
  end

  class S3Client
    Response = Struct.new(:body)

    def initialize(objects)
      @objects = objects
    end

    def get_object(bucket:, key:)
      raise "unexpected bucket: #{bucket}" unless bucket == "site"

      html = @objects[key]
      raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") unless html

      Response.new(StringIO.new(html))
    end
  end

  def setup
    @database = Database.new([
      Page.new("draft", "draft", "draft", "下書き"),
      Page.new("empty", "empty", "published", "  "),
      Page.new("missing", "missing", "published", "本文"),
      Page.new("later", "z-route", "published", "本文"),
      Page.new("first", "a-route", "published", "本文"),
    ])
    @s3_client = S3Client.new(
      "a-route" => '<script src="/static/authoring/assets/index-old.js"></script>',
      "z-route" => '<script src="/static/authoring/app.js"></script>',
    )
  end

  def test_dry_run_lists_only_pages_with_legacy_asset_references
    summary = WeblogAuthoring::PublicationRefreshBackfill.call(
      database: @database, s3_client: @s3_client, site_bucket: "site"
    )

    assert_equal "dry-run", summary.fetch("mode")
    assert_equal 3, summary.fetch("scanned_count")
    assert_equal 1, summary.fetch("count")
    assert_equal ["a-route"], (summary.fetch("pages").map { |page| page.fetch("route") })
    assert_empty @database.requested_ids
  end

  def test_apply_requests_each_candidate
    summary = WeblogAuthoring::PublicationRefreshBackfill.call(
      database: @database, s3_client: @s3_client, site_bucket: "site", dry_run: false
    )

    assert_equal "apply", summary.fetch("mode")
    assert_equal ["first"], @database.requested_ids
  end
end
