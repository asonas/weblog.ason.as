mock_provider "aws" {
  override_during = plan

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:ap-northeast-1:123456789012:weblog-alerts-test"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.lambda_assume_role
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.webmention_receiver
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.webmention_cleanup
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
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

run "webmention_receiver_guardrails" {
  command = plan

  plan_options {
    target = [
      aws_lambda_function.webmention_receiver,
      aws_apigatewayv2_stage.authoring,
      aws_sqs_queue.webmention,
    ]
  }

  assert {
    condition     = aws_sqs_queue.webmention.fifo_queue
    error_message = "Webmention verification must use a FIFO queue"
  }

  assert {
    condition     = aws_lambda_function.webmention_receiver.reserved_concurrent_executions == 2
    error_message = "Webmention receiver concurrency must be bounded"
  }

  assert {
    condition = one([
      for settings in aws_apigatewayv2_stage.authoring.route_settings : settings.throttling_rate_limit
      if settings.route_key == "POST /api/webmentions"
    ]) == 2
    error_message = "Webmention receiver route must be throttled to two requests per second"
  }
}

run "webmention_cleanup_starts_in_dry_run" {
  command = plan

  plan_options {
    target = [
      aws_lambda_function.webmention_cleanup,
      aws_cloudwatch_event_rule.webmention_cleanup,
    ]
  }

  assert {
    condition     = aws_lambda_function.webmention_cleanup.environment[0].variables.WEBMENTION_CLEANUP_DRY_RUN == "true"
    error_message = "Initial Webmention cleanup must remain in dry-run mode"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.webmention_cleanup.schedule_expression == "cron(15 18 * * ? *)"
    error_message = "Webmention cleanup must run daily"
  }
}

run "webmention_rollout_starts_stopped_and_keeps_sender_independent" {
  command = plan

  plan_options {
    target = [
      aws_lambda_function.webmention_receiver,
      aws_lambda_function.webmention_publisher,
      aws_lambda_event_source_mapping.webmention_worker,
      aws_lambda_event_source_mapping.webmention_publisher,
      aws_cloudwatch_event_rule.webmention_reverification,
      aws_cloudwatch_event_rule.webmention_outbox_dispatch,
    ]
  }

  assert {
    condition     = aws_lambda_function.webmention_receiver.environment[0].variables.WEBMENTION_RECEIVER_ENABLED == "false"
    error_message = "The public receiver must start stopped for staged rollout"
  }

  assert {
    condition     = !aws_lambda_event_source_mapping.webmention_worker.enabled
    error_message = "Verification consumption must start stopped independently"
  }

  assert {
    condition     = !aws_lambda_event_source_mapping.webmention_publisher.enabled
    error_message = "Static publishing must start stopped independently"
  }

  assert {
    condition     = aws_lambda_function.webmention_publisher.environment[0].variables.WEBMENTION_SENDER_ENABLED == "false"
    error_message = "Outbound delivery must remain stopped when static publishing is enabled first"
  }
}

run "webmention_alerts_use_the_matrix_notification_path" {
  command = plan

  variables {
    webmention_alerting_enabled = true
  }

  plan_options {
    target = [
      aws_cloudwatch_metric_alarm.webmention_dead_letters,
      aws_cloudwatch_metric_alarm.webmention_publish_dead_letters,
      aws_cloudwatch_metric_alarm.webmention_publish_queue_age_critical,
      aws_cloudwatch_metric_alarm.webmention_lambda_errors,
      aws_cloudwatch_metric_alarm.webmention_receiver_throttles,
    ]
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.webmention_dead_letters.actions_enabled
    error_message = "Webmention alerts must be independently enabled"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.webmention_dead_letters.alarm_actions) == 1 && contains(aws_cloudwatch_metric_alarm.webmention_dead_letters.alarm_actions, aws_sns_topic.inbox_alerts.arn)
    error_message = "Webmention alerts must use the existing Matrix notification topic"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.webmention_publish_dead_letters.dimensions.QueueName == aws_sqs_queue.webmention_publish_dead_letter.name
    error_message = "Static publish dead letters must be monitored"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.webmention_lambda_errors["publisher"].dimensions.FunctionName == aws_lambda_function.webmention_publisher.function_name
    error_message = "The Webmention publisher Lambda must have an error alarm"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.webmention_receiver_throttles.metric_name == "Throttles"
    error_message = "Public receiver throttling must be monitored"
  }
}
