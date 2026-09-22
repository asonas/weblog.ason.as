mock_provider "aws" {
  override_during = plan
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
  mock_data "aws_ssoadmin_instances" {
    defaults = {
      arns = ["arn:aws:sso:::instance/ssoins-0123456789abcdef"]
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:ap-northeast-1:123456789012:weblog-alerts-test"
    }
  }
  mock_data "aws_ssoadmin_permission_set" {
    defaults = {
      arn = "arn:aws:sso:::permissionSet/ssoins-0123456789abcdef/ps-0123456789abcdef"
    }
  }
  override_resource {
    target = aws_cloudwatch_log_group.inbox_sync_legacy
  }
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "weblog.ason.as"
        resource_record_name  = "_validation.weblog.ason.as"
        resource_record_type  = "CNAME"
        resource_record_value = "validation.example.com"
      }]
    }
  }
  mock_resource "aws_acm_certificate_validation" {
    defaults = {
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "cutover_routes_published_reads_and_retires_legacy_generators" {
  command = plan

  variables {
    webmention_publisher_enabled = true
    webmention_sender_enabled    = true
  }

  assert {
    condition     = aws_cloudfront_distribution.weblog.default_cache_behavior[0].target_origin_id == "authoring-api" && aws_cloudfront_distribution.weblog.default_cache_behavior[0].cache_policy_id == data.aws_cloudfront_cache_policy.caching_disabled.id
    error_message = "Article routes must resolve the active published pointer without stale CDN bodies."
  }

  assert {
    condition     = !aws_lambda_event_source_mapping.webmention_publisher.enabled && !aws_lambda_event_source_mapping.search_indexer.enabled && aws_cloudwatch_event_rule.search_index_nightly.state == "DISABLED" && aws_cloudwatch_event_rule.webmention_outbox_dispatch.state == "DISABLED"
    error_message = "Legacy generators must be paused together before reopening editing."
  }

  assert {
    condition     = aws_lambda_function.webmention_publisher.environment[0].variables["WEBMENTION_SENDER_ENABLED"] == "false" && aws_lambda_function.search_indexer.reserved_concurrent_executions == 1 && aws_cloudwatch_event_rule.draft_worker.state == "ENABLED"
    error_message = "Cutover must retain disabled sending and bounded publication and maintenance workers."
  }
}
