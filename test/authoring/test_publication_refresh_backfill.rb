# frozen_string_literal: true

require "minitest/autorun"

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

  def setup
    @database = Database.new([
      Page.new("draft", "draft", "draft", "下書き"),
      Page.new("empty", "empty", "published", "  "),
      Page.new("later", "z-route", "published", "本文"),
      Page.new("first", "a-route", "published", "本文"),
    ])
  end

  def test_dry_run_lists_only_published_non_empty_pages
    summary = WeblogAuthoring::PublicationRefreshBackfill.call(database: @database)

    assert_equal "dry-run", summary.fetch("mode")
    assert_equal 2, summary.fetch("count")
    assert_equal %w[a-route z-route], (summary.fetch("pages").map { |page| page.fetch("route") })
    assert_empty @database.requested_ids
  end

  def test_apply_requests_each_candidate
    summary = WeblogAuthoring::PublicationRefreshBackfill.call(database: @database, dry_run: false)

    assert_equal "apply", summary.fetch("mode")
    assert_equal %w[first later], @database.requested_ids
  end
end
