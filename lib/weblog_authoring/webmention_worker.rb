# frozen_string_literal: true

require "json"

require_relative "webmention_document"
require_relative "webmention_fetcher"
require_relative "webmention_sender"

module WeblogAuthoring
  class WebmentionWorker
    def initialize(database:, fetcher: WebmentionFetcher.new, sender: nil, logger: $stdout)
      @database = database
      @fetcher = fetcher
      @sender = sender || WebmentionSender.new(database:, fetcher:)
      @logger = logger
    end

    def call(event)
      event.fetch("Records").each do |record|
        job = JSON.parse(record.fetch("body"))
        result = job["type"] == "deliver" ? @sender.deliver(job) : verify(job)
        log(job, result)
      rescue StandardError => error
        log(job, error.respond_to?(:result) ? error.result : "failed")
        raise
      end
    end

    def verify(job)
      response = @fetcher.fetch(job.fetch("source"))
      if [404, 410].include?(response.status)
        @database.record_webmention_deletion(job:, response:, reason: "source_gone")
        return "source_gone"
      end
      unless response.status.between?(200, 299)
        raise WebmentionFetcher::FetchError, "source returned HTTP #{response.status}"
      end

      document = WebmentionDocument.new(response.body, base_url: response.url)
      if document.links_to?(job.fetch("target"))
        @database.record_verified_webmention(
          job:, response:, title: document.title, site_name: document.site_name,
          content_hash: document.content_hash
        )
        "verified"
      else
        @database.record_webmention_deletion(job:, response:, reason: "link_missing")
        "link_missing"
      end
    rescue WebmentionFetcher::FetchError => error
      @database.record_webmention_failure(job:, result: error.result, message: error.message)
      raise if error.result == "temporary_failure"

      error.result
    end

    private

    def log(job, result)
      @logger.puts(JSON.generate(
        "event" => "webmention_worker_result", "job_id" => job.fetch("job_id", job["delivery_id"]),
        "job_type" => job.fetch("type", "verify"), "result" => result
      ))
    end
  end
end
