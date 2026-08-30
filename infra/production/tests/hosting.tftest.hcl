mock_provider "aws" {
  override_during = plan
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        {
          domain_name           = "weblog.ason.as"
          resource_record_name  = "_validation.weblog.ason.as"
          resource_record_type  = "CNAME"
          resource_record_value = "validation.example.com"
        },
      ]
    }
  }

  mock_resource "aws_acm_certificate_validation" {
    defaults = {
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "image_inbox_lifecycle" {
  command = plan

  plan_options {
    target = [aws_s3_bucket_lifecycle_configuration.site]
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[0].id == "expire-image-inbox" && aws_s3_bucket_lifecycle_configuration.site.rule[0].expiration[0].days == 14
    error_message = "assets/inbox objects must expire after 14 days"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[0].filter[0].prefix == "assets/inbox/"
    error_message = "the image inbox rule must only target assets/inbox"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[1].id == "expire-pending-inbox-adoptions" && aws_s3_bucket_lifecycle_configuration.site.rule[1].expiration[0].days == 14
    error_message = "pending public copies must expire after 14 days"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[1].filter[0].and[0].prefix == "assets/uploads/"
    error_message = "the pending adoption rule must only target public upload copies"
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.site.rule[1].filter[0].and[0].tags) == 1 && lookup(aws_s3_bucket_lifecycle_configuration.site.rule[1].filter[0].and[0].tags, "weblog-inbox-adoption", null) == "pending"
    error_message = "only pending public copies may expire"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[0].noncurrent_version_expiration[0].noncurrent_days == 1 && aws_s3_bucket_lifecycle_configuration.site.rule[1].noncurrent_version_expiration[0].noncurrent_days == 1
    error_message = "noncurrent inbox versions must expire after one day"
  }
}

run "dynamic_api_caching_disabled" {
  command = plan

  override_resource {
    target          = aws_acm_certificate_validation.weblog
    override_during = plan
    values = {
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }

  plan_options {
    target = [aws_cloudfront_distribution.weblog]
  }

  assert {
    condition     = one([for behavior in aws_cloudfront_distribution.weblog.ordered_cache_behavior : behavior if behavior.path_pattern == "/api/*"]).cache_policy_id == data.aws_cloudfront_cache_policy.caching_disabled.id
    error_message = "dynamic API responses must use the managed caching-disabled policy"
  }
}
