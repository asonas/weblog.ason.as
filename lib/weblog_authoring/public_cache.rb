# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "aws-sdk-cloudfront"
require "aws-sdk-s3"
require_relative "names"

module WeblogAuthoring
  class PublicCache
    class Pending < StandardError; end
    def self.paths(routes)
      raise ArgumentError, "Expected one article or its old and new routes" unless (1..2).cover?(routes.length)
      routes.uniq.flat_map do |route|
        path = "/#{WeblogAuthoring.encoded_route(route)}"
        # CloudFront does not support invalidating tilde paths.
        raise ArgumentError, "このURLはキャッシュ更新の対象にできません。期限による更新をお待ちください。" if path.include?("~") || path.bytesize > 3999
        [path, "#{path}/"]
      end.sort
    end

    def initialize(client:, distribution_id:)
      @client = client
      @distribution = distribution_id
    end

    def refresh(request)
      paths = JSON.parse(request.fetch("paths"))
      raise ArgumentError, "Invalid cache paths" unless paths == self.class.paths(JSON.parse(request.fetch("routes")))
      reference = Digest::SHA256.hexdigest(JSON.generate([@distribution, request.fetch("version_id"), paths]))
      result = @client.create_invalidation(distribution_id: @distribution,
        invalidation_batch: { caller_reference: "publication-#{reference}", paths: { quantity: paths.length, items: paths } })
      status = @client.get_invalidation(distribution_id: @distribution, id: result.invalidation.id).invalidation.status
      raise Pending, "キャッシュ更新中です。" unless status == "Completed"
      true
    end
  end

  class PublicCacheUsage
    KEY = "operations/public-cache-usage.json"

    def initialize(client:, s3_client:, bucket:, distribution_id:, clock: Time.method(:now))
      @client = client
      @s3 = s3_client
      @bucket = bucket
      @distribution = distribution_id
      @clock = clock
    end

    def read
      JSON.parse(@s3.get_object(bucket: @bucket, key: KEY).body.read)
    rescue Aws::S3::Errors::NoSuchKey
      { "checked_at" => nil, "used_paths" => nil, "remaining_paths" => nil, "scope" => "site", "site_used_paths" => nil }
    end

    def update
      now = @clock.call.utc
      month = now.strftime("%Y-%m")
      previous = read
      counts = previous["month"] == month ? previous.fetch("batches", {}) : {}
      distributions = @client.list_distributions.flat_map { |page| page.distribution_list.items }.map(&:id)
      raise "Site distribution is missing" unless distributions.include?(@distribution)
      distributions.each do |distribution|
        @client.list_invalidations(distribution_id: distribution).each do |page|
          items = page.invalidation_list.items
          items.each do |item|
            next unless item.create_time.utc.strftime("%Y-%m") == month
            key = "#{distribution}/#{item.id}"
            counts[key] ||= @client.get_invalidation(distribution_id: distribution, id: item.id).invalidation.invalidation_batch.paths.quantity
          end
          break if items.any? { |item| item.create_time.utc.strftime("%Y-%m") < month }
        end
      end
      used = counts.values.sum
      site_used = counts.select { |key, _count| key.start_with?("#{@distribution}/") }.values.sum
      # Deleted distributions and tenant distributions cannot be inferred here.
      result = { "month" => month, "checked_at" => now.iso8601, "scope" => "listed_distributions",
        "used_paths" => used, "site_used_paths" => site_used, "remaining_paths" => nil, "batches" => counts, }
      @s3.put_object(bucket: @bucket, key: KEY, body: JSON.generate(result), content_type: "application/json", cache_control: "no-store")
      result
    end
  end
end
