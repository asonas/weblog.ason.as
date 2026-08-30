# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_worker"

class WebmentionWorkerTest < Minitest::Test
  Response = WeblogAuthoring::WebmentionFetcher::Response

  class Database
    attr_reader :verified, :deleted, :failed

    def record_verified_webmention(**values)
      @verified = values
    end

    def record_webmention_deletion(**values)
      @deleted = values
    end

    def record_webmention_failure(**values)
      @failed = values
    end
  end

  class Fetcher
    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def fetch(_url)
      raise @error if @error

      @response
    end
  end

  def setup
    @database = Database.new
    @job = {
      "job_id" => "job-id", "source" => "https://example.com/post",
      "target" => "https://weblog.ason.as/article", "received_at" => "2026-08-30T12:00:00Z",
    }
  end

  def test_records_a_verified_candidate
    response = Response.new(
      url: @job.fetch("source"), status: 200, content_type: "text/html",
      link_header: nil,
      body: '<title>Post</title><meta property="og:site_name" content="Example"><a href="https://weblog.ason.as/article">mention</a>',
      redirect_count: 0, duration_ms: 12
    )
    worker(response:).verify(@job)

    assert_equal "Post", @database.verified.fetch(:title)
    assert_equal "Example", @database.verified.fetch(:site_name)
    assert_nil @database.deleted
  end

  def test_records_link_removal_without_retrying
    response = Response.new(
      url: @job.fetch("source"), status: 200, content_type: "text/html", body: "<p>No link</p>",
      link_header: nil, redirect_count: 1, duration_ms: 20
    )
    worker(response:).verify(@job)

    assert_equal "link_missing", @database.deleted.fetch(:reason)
  end

  def test_records_and_reraises_temporary_failures_for_sqs_retry
    error = WeblogAuthoring::WebmentionFetcher::FetchError.new("timeout")

    assert_raises(WeblogAuthoring::WebmentionFetcher::FetchError) { worker(error:).verify(@job) }
    assert_equal "temporary_failure", @database.failed.fetch(:result)
  end

  def test_records_a_blocked_source_without_retrying
    error = WeblogAuthoring::WebmentionFetcher::FetchError.new("private address", result: "blocked_source")

    worker(error:).verify(@job)

    assert_equal "blocked_source", @database.failed.fetch(:result)
  end

  private

  def worker(response: nil, error: nil)
    WeblogAuthoring::WebmentionWorker.new(database: @database, fetcher: Fetcher.new(response:, error:))
  end
end
