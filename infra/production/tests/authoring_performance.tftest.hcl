mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_iam_policy_document.lambda_assume_role
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

run "authoring_performance_telemetry" {
  command = plan

  plan_options {
    target = [
      aws_lambda_function.authoring_performance,
      aws_apigatewayv2_route.authoring_performance,
      aws_cloudwatch_log_group.authoring_performance,
      aws_cloudwatch_log_metric_filter.authoring_restore_slow,
      aws_cloudwatch_metric_alarm.authoring_restore_slow,
      aws_cloudwatch_metric_alarm.authoring_performance_errors,
      aws_cloudwatch_dashboard.authoring_performance,
    ]
  }

  assert {
    condition     = aws_cloudwatch_log_group.authoring_performance.retention_in_days == 30
    error_message = "Authoring performance telemetry must be retained for thirty days"
  }

  assert {
    condition     = aws_apigatewayv2_route.authoring_performance.route_key == "POST /api/authoring/telemetry"
    error_message = "Authoring performance telemetry must use its dedicated route"
  }

  assert {
    condition     = aws_lambda_function.authoring_performance.logging_config[0].log_group == aws_cloudwatch_log_group.authoring_performance.name
    error_message = "Authoring performance telemetry must use its dedicated log group"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.authoring_restore_slow.threshold == 1
    error_message = "A restore over five seconds must trigger the restore alarm"
  }
}
