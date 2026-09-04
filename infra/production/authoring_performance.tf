resource "aws_cloudwatch_log_group" "authoring_performance" {
  name              = "/weblog/lambda/authoring-performance-production"
  retention_in_days = 30
}

resource "aws_iam_role" "authoring_performance" {
  name               = "weblog-authoring-performance-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "authoring_performance_oauth_secret" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.oauth.arn]
  }
}

resource "aws_iam_role_policy" "authoring_performance_oauth_secret" {
  name   = "ReadOAuthSecret"
  role   = aws_iam_role.authoring_performance.id
  policy = data.aws_iam_policy_document.authoring_performance_oauth_secret.json
}

resource "aws_iam_role_policy_attachment" "authoring_performance_logs" {
  role       = aws_iam_role.authoring_performance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "authoring_performance" {
  function_name = "weblog-authoring-performance-production"
  package_type  = "Image"
  image_uri     = aws_lambda_function.authoring.image_uri
  role          = aws_iam_role.authoring_performance.arn
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 5

  image_config {
    command = ["performance_telemetry.WeblogAuthoring::PerformanceTelemetryLambdaHandler.call"]
  }

  environment {
    variables = {
      GITHUB_ALLOWED_USER_ID = "630181"
      OAUTH_SECRET_ID        = aws_secretsmanager_secret.oauth.name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.authoring_performance.name
  }

  depends_on = [
    aws_iam_role_policy.authoring_performance_oauth_secret,
    aws_iam_role_policy_attachment.authoring_performance_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_apigatewayv2_integration" "authoring_performance" {
  api_id                 = aws_apigatewayv2_api.authoring.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.authoring_performance.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "authoring_performance" {
  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = "POST /api/authoring/telemetry"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.authoring_performance.id}"
}

resource "aws_lambda_permission" "authoring_performance_api" {
  statement_id  = "AllowAuthoringPerformanceApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authoring_performance.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.authoring.execution_arn}/*/POST/api/authoring/telemetry"
}

resource "aws_cloudwatch_log_metric_filter" "authoring_restore_slow" {
  name           = "AuthoringRestoreOverFiveSeconds"
  pattern        = "{ $.event = \"authoring_performance_telemetry\" && $.restore_max_ms > 5000 }"
  log_group_name = aws_cloudwatch_log_group.authoring_performance.name

  metric_transformation {
    name      = "RestoreOverFiveSeconds"
    namespace = "Weblog/AuthoringPerformance"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "authoring_restore_slow" {
  alarm_name          = "weblog-authoring-restore-over-five-seconds"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RestoreOverFiveSeconds"
  namespace           = "Weblog/AuthoringPerformance"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "authoring_performance_errors" {
  alarm_name          = "weblog-authoring-performance-ingestion-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.authoring_performance.function_name
  }
}

resource "aws_cloudwatch_dashboard" "authoring_performance" {
  dashboard_name = "weblog-authoring-performance"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 24
        height = 8
        properties = {
          region = var.aws_region
          title  = "Authoring performance sessions"
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.authoring_performance.name}' | fields @timestamp, restore_max_ms, payload.metrics, payload.spans | filter event = 'authoring_performance_telemetry' | sort @timestamp desc | limit 100"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title  = "Restore failures"
          metrics = [[
            "Weblog/AuthoringPerformance",
            "RestoreOverFiveSeconds",
          ]]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title  = "Telemetry ingestion errors"
          metrics = [[
            "AWS/Lambda",
            "Errors",
            "FunctionName",
            aws_lambda_function.authoring_performance.function_name,
          ]]
          period = 300
          stat   = "Sum"
        }
      },
    ]
  })
}
