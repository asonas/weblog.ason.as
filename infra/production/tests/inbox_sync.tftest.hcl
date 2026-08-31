mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_iam_policy_document.lambda_assume_role
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.inbox_sync_runtime
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.matrix_notifier_runtime
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

run "inbox_sync_alerting" {
  command = plan

  variables {
    inbox_alerting_enabled = true
    inbox_alert_email      = "alerts@example.com"
  }

  plan_options {
    target = [
      aws_cloudwatch_log_group.inbox_sync,
      aws_cloudwatch_log_metric_filter.inbox_source_success,
      aws_cloudwatch_metric_alarm.inbox_source_retryable_failure,
      aws_cloudwatch_metric_alarm.inbox_source_stale,
      aws_cloudwatch_metric_alarm.inbox_schedule_stale,
      aws_sns_topic.inbox_alerts,
      aws_lambda_function.matrix_notifier,
      aws_sns_topic_subscription.inbox_matrix,
      aws_sns_topic_subscription.inbox_email,
    ]
  }

  assert {
    condition     = aws_cloudwatch_log_group.inbox_sync.retention_in_days == 14
    error_message = "inbox sync structured logs must expire after fourteen days"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.inbox_source_retryable_failure["bluesky"].evaluation_periods == 3
    error_message = "retryable failures must alert after three consecutive periods"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.inbox_source_stale["raindrop"].datapoints_to_alarm == 3
    error_message = "a source must alert after three missing hourly successes"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.inbox_schedule_stale.actions_enabled
    error_message = "alarm actions must follow the explicit alerting switch"
  }

  assert {
    condition     = aws_lambda_function.matrix_notifier.environment[0].variables.MATRIX_SECRET_ID == aws_secretsmanager_secret.inbox_matrix.name
    error_message = "Matrix notifier must load its configuration from Secrets Manager"
  }

  assert {
    condition     = aws_sns_topic_subscription.inbox_email[0].endpoint == "alerts@example.com"
    error_message = "configured email must subscribe to inbox alerts"
  }
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
}

run "inbox_sync_runtime" {
  command = plan

  plan_options {
    target = [
      aws_lambda_function.inbox_sync,
      aws_cloudwatch_event_rule.inbox_sync,
    ]
  }

  assert {
    condition     = aws_lambda_function.inbox_sync.timeout == 300
    error_message = "inbox sync Lambda must have a five minute timeout"
  }

  assert {
    condition     = aws_lambda_function.inbox_sync.reserved_concurrent_executions == 1
    error_message = "inbox sync Lambda must run one invocation at a time"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.inbox_sync.schedule_expression == "rate(1 hour)"
    error_message = "inbox sources must be synchronized hourly"
  }

  assert {
    condition     = aws_lambda_function.inbox_sync.environment[0].variables.BLUESKY_OAUTH_FUNCTION_NAME == aws_lambda_function.bluesky_oauth.function_name
    error_message = "inbox sync Lambda must invoke the Bluesky OAuth Lambda"
  }
}
