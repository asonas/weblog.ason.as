# frozen_string_literal: true

require_relative "webmention_document"
require_relative "webmention_fetcher"

module WeblogAuthoring
  class WebmentionSender
    class DeliveryError < StandardError; end

    def initialize(database:, fetcher: WebmentionFetcher.new)
      @database = database
      @fetcher = fetcher
    end

    def deliver(job)
      target = @fetcher.fetch(job.fetch("target"))
      unless target.status.between?(200, 299)
        raise DeliveryError, "target returned HTTP #{target.status}"
      end

      document = WebmentionDocument.new(target.body, base_url: target.url)
      endpoint = document.webmention_endpoint(link_header: target.link_header)
      unless endpoint
        @database.record_webmention_delivery(job:, status: "not_supported")
        return "not_supported"
      end

      status = @fetcher.post_form(
        endpoint, "source" => job.fetch("source"), "target" => job.fetch("target")
      )
      if status.between?(200, 299)
        @database.record_webmention_delivery(job:, status: "succeeded", http_status: status)
        "succeeded"
      else
        raise DeliveryError, "Webmention endpoint returned HTTP #{status}"
      end
    rescue WebmentionFetcher::FetchError => error
      @database.record_webmention_delivery(job:, status: "failed", error: error.result)
      raise if error.result == "temporary_failure"

      "failed"
    rescue DeliveryError => error
      @database.record_webmention_delivery(job:, status: "failed", error: error.message)
      raise
    end
  end
end
