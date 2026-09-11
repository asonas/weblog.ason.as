resource "aws_iam_role" "inbox_sync_runtime" {
  name               = "weblog-inbox-sync-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "inbox_sync_basic_execution" {
  role       = aws_iam_role.inbox_sync_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "inbox_sync_runtime" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.inbox_sources.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.bluesky_oauth.arn]
  }
}

resource "aws_iam_role_policy" "inbox_sync_runtime" {
  name   = "InboxSyncRuntime"
  role   = aws_iam_role.inbox_sync_runtime.id
  policy = data.aws_iam_policy_document.inbox_sync_runtime.json
}

resource "aws_lambda_function" "inbox_sync" {
  function_name                  = "weblog-inbox-sync-production"
  package_type                   = "Image"
  image_uri                      = "${aws_ecr_repository.inbox_sync.repository_url}:bootstrap"
  role                           = aws_iam_role.inbox_sync_runtime.arn
  architectures                  = ["arm64"]
  memory_size                    = 512
  timeout                        = 300
  reserved_concurrent_executions = 1

  environment {
    variables = {
      DSQL_HOST                   = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      INBOX_SOURCES_SECRET_ID     = trimprefix(aws_ssm_parameter.inbox_sources.name, "/")
      BLUESKY_OAUTH_FUNCTION_NAME = aws_lambda_function.bluesky_oauth.function_name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.inbox_sync.name
  }

  depends_on = [
    aws_iam_role_policy.inbox_sync_runtime,
    aws_iam_role_policy_attachment.inbox_sync_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_cloudwatch_log_group" "inbox_sync" {
  name              = "/weblog/lambda/inbox-sync-production"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "inbox_sync_legacy" {
  name              = "/aws/lambda/weblog-inbox-sync-production"
  retention_in_days = 14
}

import {
  to = aws_cloudwatch_log_group.inbox_sync_legacy
  id = "/aws/lambda/weblog-inbox-sync-production"
}

resource "aws_cloudwatch_log_metric_filter" "inbox_source_success" {
  name           = "InboxSourceSuccess"
  pattern        = "{ $.event = \"inbox_sync_source_result\" && $.status = \"succeeded\" }"
  log_group_name = aws_cloudwatch_log_group.inbox_sync.name

  metric_transformation {
    name      = "SourceSuccess"
    namespace = "Weblog/InboxSync"
    value     = "1"
    dimensions = {
      Source = "$.source"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "inbox_source_retryable_failure" {
  name           = "InboxSourceRetryableFailure"
  pattern        = "{ $.event = \"inbox_sync_source_result\" && $.status = \"failed\" && $.alert_policy = \"after_three\" }"
  log_group_name = aws_cloudwatch_log_group.inbox_sync.name

  metric_transformation {
    name      = "SourceRetryableFailure"
    namespace = "Weblog/InboxSync"
    value     = "1"
    dimensions = {
      Source = "$.source"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "inbox_source_immediate_failure" {
  name           = "InboxSourceImmediateFailure"
  pattern        = "{ $.event = \"inbox_sync_source_result\" && $.status = \"failed\" && $.alert_policy = \"immediate\" }"
  log_group_name = aws_cloudwatch_log_group.inbox_sync.name

  metric_transformation {
    name      = "SourceImmediateFailure"
    namespace = "Weblog/InboxSync"
    value     = "1"
    dimensions = {
      Source = "$.source"
    }
  }
}

resource "aws_cloudwatch_event_rule" "inbox_sync" {
  name                = "weblog-inbox-sync-production"
  description         = "Synchronize external weblog inbox sources"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "inbox_sync" {
  rule      = aws_cloudwatch_event_rule.inbox_sync.name
  target_id = "inbox-sync-lambda"
  arn       = aws_lambda_function.inbox_sync.arn
}

resource "aws_lambda_permission" "inbox_sync_event" {
  statement_id  = "AllowEventBridgeInboxSync"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inbox_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.inbox_sync.arn
}

resource "aws_sns_topic" "inbox_alerts" {
  name = "weblog-inbox-sync-alerts-production"
}

resource "aws_iam_role" "matrix_notifier_runtime" {
  name               = "weblog-matrix-notifier-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "matrix_notifier_basic_execution" {
  role       = aws_iam_role.matrix_notifier_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "matrix_notifier_runtime" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.inbox_matrix.arn]
  }
}

resource "aws_iam_role_policy" "matrix_notifier_runtime" {
  name   = "ReadMatrixSecret"
  role   = aws_iam_role.matrix_notifier_runtime.id
  policy = data.aws_iam_policy_document.matrix_notifier_runtime.json
}

resource "aws_cloudwatch_log_group" "matrix_notifier" {
  name              = "/weblog/lambda/matrix-notifier-production"
  retention_in_days = 14
}

resource "aws_lambda_function" "matrix_notifier" {
  function_name = "weblog-matrix-notifier-production"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.inbox_sync.repository_url}:bootstrap"
  role          = aws_iam_role.matrix_notifier_runtime.arn
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 30

  image_config {
    command = ["matrix_notifier.WeblogAuthoring::MatrixNotifierLambdaHandler.call"]
  }

  environment {
    variables = {
      MATRIX_SECRET_ID = trimprefix(aws_ssm_parameter.inbox_matrix.name, "/")
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.matrix_notifier.name
  }

  depends_on = [
    aws_iam_role_policy.matrix_notifier_runtime,
    aws_iam_role_policy_attachment.matrix_notifier_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_permission" "matrix_notifier_sns" {
  statement_id  = "AllowInboxAlertsSns"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.matrix_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.inbox_alerts.arn
}

resource "aws_sns_topic_subscription" "inbox_matrix" {
  topic_arn = aws_sns_topic.inbox_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.matrix_notifier.arn

  depends_on = [aws_lambda_permission.matrix_notifier_sns]
}

resource "aws_sns_topic_subscription" "inbox_email" {
  count = trimspace(var.inbox_alert_email) == "" ? 0 : 1

  topic_arn = aws_sns_topic.inbox_alerts.arn
  protocol  = "email"
  endpoint  = trimspace(var.inbox_alert_email)
}

data "aws_iam_policy_document" "invoke_inbox_sync" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.inbox_sync.arn]
  }
}

resource "aws_iam_role_policy" "invoke_inbox_sync" {
  name   = "InvokeInboxSync"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.invoke_inbox_sync.json
}
