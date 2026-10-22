# frozen_string_literal: true

require_relative "../test_helper"
require "aws-sdk-cloudfront"
require "aws-sdk-s3"
require "weblog_authoring/public_cache"

class PublicCacheTest < Minitest::Test
  def test_publication_request_is_bounded_encoded_and_idempotent_across_pending_completion
    client = Aws::CloudFront::Client.new(stub_responses: true)
    client.stub_responses(:create_invalidation, invalidation: { id: "invalidation", status: "InProgress", create_time: Time.now, invalidation_batch: { caller_reference: "ref", paths: { quantity: 2, items: ["/Where", "/Where/"] } } })
    client.stub_responses(:get_invalidation, [
      { invalidation: { id: "invalidation", status: "InProgress", create_time: Time.now, invalidation_batch: { caller_reference: "ref", paths: { quantity: 2 } } } },
      { invalidation: { id: "invalidation", status: "Completed", create_time: Time.now, invalidation_batch: { caller_reference: "ref", paths: { quantity: 2 } } } },
    ])
    service = WeblogAuthoring::PublicCache.new(client:, distribution_id: "site")
    request = { "version_id" => "version", "routes" => JSON.generate(["Where"]), "paths" => JSON.generate(["/Where", "/Where/"]) }
    assert_raises(WeblogAuthoring::PublicCache::Pending) { service.refresh(request) }
    assert service.refresh(request)
    calls = client.api_requests.select { |r| r[:operation_name] == :create_invalidation }.map { |r| r[:params] }
    assert_equal 1, calls.map { |r| r[:invalidation_batch][:caller_reference] }.uniq.length
    assert_equal ["/Where", "/Where/"], calls.first[:invalidation_batch][:paths][:items]
    assert_equal ["/New", "/New/", "/Old", "/Old/"], WeblogAuthoring::PublicCache.paths(%w[Old New])
    assert_equal ["/%E6%97%A5%E8%A8%98%20Where", "/%E6%97%A5%E8%A8%98%20Where/"], WeblogAuthoring::PublicCache.paths(["日記 Where"])
    assert_raises(ArgumentError) { WeblogAuthoring::PublicCache.paths(%w[a b c]) }
    assert_raises(ArgumentError) { WeblogAuthoring::PublicCache.paths(["a~b"]) }
    assert_raises(ArgumentError) { service.refresh(request.merge("paths" => '["/*"]')) }
  end

  def test_usage_counts_current_month_paths_and_reuses_saved_batches
    now = Time.utc(2026, 10, 22)
    client = Aws::CloudFront::Client.new(stub_responses: true)
    client.stub_responses(:list_distributions, distribution_list: { marker: "", max_items: 100, is_truncated: false, quantity: 1, items: [] })
    # Listing payloads are external API fixtures, unrelated to the counter implementation.
    client.stub_responses(:list_distributions, ->(_) { { distribution_list: { marker: "", max_items: 100, is_truncated: false, quantity: 1, items: [{ id: "site", arn: "arn:aws:cloudfront::123456789012:distribution/site", status: "Deployed", last_modified_time: now, domain_name: "example.cloudfront.net", aliases: { quantity: 0 }, origins: { quantity: 1, items: [{ id: "origin", domain_name: "example.com", origin_path: "", custom_headers: { quantity: 0 } }] }, default_cache_behavior: { target_origin_id: "origin", viewer_protocol_policy: "https-only", trusted_signers: { enabled: false, quantity: 0 }, forwarded_values: { query_string: false, cookies: { forward: "none" } }, min_ttl: 0 }, cache_behaviors: { quantity: 0 }, custom_error_responses: { quantity: 0 }, comment: "", price_class: "PriceClass_All", enabled: true, viewer_certificate: { cloud_front_default_certificate: true }, restrictions: { geo_restriction: { restriction_type: "none", quantity: 0 } }, web_acl_id: "", http_version: "http2", is_ipv6_enabled: true, staging: false }] } } })
    client.stub_responses(:list_invalidations, invalidation_list: { marker: "", max_items: 100, is_truncated: false, quantity: 2, items: [{ id: "new", create_time: now, status: "InProgress" }, { id: "old", create_time: Time.utc(2026, 9, 30), status: "Completed" }] })
    client.stub_responses(:get_invalidation, invalidation: { id: "new", create_time: now, status: "InProgress", invalidation_batch: { caller_reference: "ref", paths: { quantity: 4, items: %w[/a /a/ /b /b/] } } })
    s3 = Aws::S3::Client.new(stub_responses: true)
    saved = nil
    s3.stub_responses(:get_object, ->(_) { saved ? { body: saved } : "NoSuchKey" })
    s3.stub_responses(:put_object, ->(context) { saved = context.params.fetch(:body); {} })
    service = WeblogAuthoring::PublicCacheUsage.new(client:, s3_client: s3, bucket: "site", distribution_id: "site", clock: -> { now })
    assert_nil service.read.fetch("used_paths")
    assert_equal 4, service.update.fetch("used_paths")
    assert_nil service.update.fetch("remaining_paths")
    assert_equal(1, client.api_requests.count { |r| r[:operation_name] == :get_invalidation })
    client.stub_responses(:list_invalidations, "AccessDenied")
    assert_raises(Aws::CloudFront::Errors::AccessDenied) { service.update }
    assert_equal 4, service.read.fetch("used_paths")
  end
end
