locals {
  webmention_runbook_url = "https://github.com/asonas/weblog.ason.as/blob/main/docs/runbooks/webmention.md"
  webmention_lambda_functions = {
    receiver  = aws_lambda_function.webmention_receiver.function_name
    worker    = aws_lambda_function.webmention_worker.function_name
    publisher = aws_lambda_function.webmention_publisher.function_name
    cleanup   = aws_lambda_function.webmention_cleanup.function_name
  }
}

resource "aws_sqs_queue" "webmention_dead_letter" {
  name                      = "weblog-webmention-dead-letter-production.fifo"
  fifo_queue                = true
  message_retention_seconds = 14 * 24 * 60 * 60
}

resource "aws_sqs_queue" "webmention" {
  name                        = "weblog-webmention-production.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  visibility_timeout_seconds  = 60
  message_retention_seconds   = 4 * 24 * 60 * 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.webmention_dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "webmention" {
  queue_url = aws_sqs_queue.webmention_dead_letter.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.webmention.arn]
  })
}

resource "aws_sqs_queue" "webmention_publish_dead_letter" {
  name                      = "weblog-webmention-publish-dead-letter-production.fifo"
  fifo_queue                = true
  message_retention_seconds = 14 * 24 * 60 * 60
}

resource "aws_sqs_queue" "webmention_publish" {
  name                       = "weblog-webmention-publish-production.fifo"
  fifo_queue                 = true
  visibility_timeout_seconds = 120
  message_retention_seconds  = 4 * 24 * 60 * 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.webmention_publish_dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_iam_role" "webmention_receiver_runtime" {
  name               = "weblog-webmention-receiver-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "webmention_receiver" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.webmention.arn]
  }

}

resource "aws_iam_role_policy" "webmention_receiver" {
  name   = "ReceiveWebmentions"
  role   = aws_iam_role.webmention_receiver_runtime.id
  policy = data.aws_iam_policy_document.webmention_receiver.json
}

resource "aws_iam_role_policy_attachment" "webmention_receiver_logs" {
  role       = aws_iam_role.webmention_receiver_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "authoring_webmention_notify" {
  statement {
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      aws_sqs_queue.webmention.arn,
      aws_sqs_queue.webmention_publish.arn,
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
      "sqs:StartMessageMoveTask",
    ]
    resources = [
      aws_sqs_queue.webmention_dead_letter.arn,
      aws_sqs_queue.webmention_publish_dead_letter.arn,
    ]
  }
}

resource "aws_iam_role_policy" "authoring_webmention_notify" {
  name   = "NotifyWebmentionVerification"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.authoring_webmention_notify.json
}

resource "aws_lambda_function" "webmention_receiver" {
  function_name                  = "weblog-webmention-receiver-production"
  package_type                   = "Image"
  image_uri                      = aws_lambda_function.authoring.image_uri
  role                           = aws_iam_role.webmention_receiver_runtime.arn
  architectures                  = ["arm64"]
  memory_size                    = 256
  timeout                        = 5
  reserved_concurrent_executions = 2

  image_config {
    command = ["webmention_receiver.WeblogAuthoring::WebmentionReceiverHandler.call"]
  }

  environment {
    variables = {
      DSQL_HOST                   = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      SITE_URL                    = "https://weblog.ason.as"
      WEBMENTION_QUEUE_URL        = aws_sqs_queue.webmention.url
      WEBMENTION_RECEIVER_ENABLED = tostring(var.webmention_receiver_enabled)
    }
  }

  depends_on = [
    aws_iam_role_policy.webmention_receiver,
    aws_iam_role_policy_attachment.webmention_receiver_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_cloudwatch_log_group" "webmention_receiver" {
  name              = "/aws/lambda/${aws_lambda_function.webmention_receiver.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_metric_filter" "webmention_receiver_results" {
  name           = "WebmentionReceiverResults"
  pattern        = "{ $.event = \"webmention_receiver_result\" }"
  log_group_name = aws_cloudwatch_log_group.webmention_receiver.name

  metric_transformation {
    name      = "ReceiverResults"
    namespace = "Weblog/Webmention"
    value     = "1"
    dimensions = {
      Result = "$.result"
      Status = "$.status"
    }
  }
}

resource "aws_iam_role" "webmention_worker_runtime" {
  name               = "weblog-webmention-worker-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "webmention_worker" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.webmention.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.webmention.arn]
  }
}

resource "aws_iam_role_policy" "webmention_worker" {
  name   = "VerifyWebmentions"
  role   = aws_iam_role.webmention_worker_runtime.id
  policy = data.aws_iam_policy_document.webmention_worker.json
}

resource "aws_iam_role_policy_attachment" "webmention_worker_logs" {
  role       = aws_iam_role.webmention_worker_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "webmention_worker" {
  function_name = "weblog-webmention-worker-production"
  package_type  = "Image"
  image_uri     = aws_lambda_function.authoring.image_uri
  role          = aws_iam_role.webmention_worker_runtime.arn
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 30

  image_config {
    command = ["webmention_worker.WeblogAuthoring::WebmentionWorkerHandler.call"]
  }

  environment {
    variables = {
      DSQL_HOST                      = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      WEBMENTION_QUEUE_URL           = aws_sqs_queue.webmention.url
      WEBMENTION_REVERIFY_AFTER_DAYS = "7"
      WEBMENTION_REVERIFY_BATCH_SIZE = "100"
    }
  }

  depends_on = [
    aws_iam_role_policy.webmention_worker,
    aws_iam_role_policy_attachment.webmention_worker_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_event_source_mapping" "webmention_worker" {
  event_source_arn = aws_sqs_queue.webmention.arn
  function_name    = aws_lambda_function.webmention_worker.arn
  batch_size       = 1
  enabled          = var.webmention_verification_enabled
}

resource "aws_cloudwatch_log_group" "webmention_worker" {
  name              = "/aws/lambda/${aws_lambda_function.webmention_worker.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_metric_filter" "webmention_worker_results" {
  name           = "WebmentionWorkerResults"
  pattern        = "{ $.event = \"webmention_worker_result\" }"
  log_group_name = aws_cloudwatch_log_group.webmention_worker.name

  metric_transformation {
    name      = "WorkerResults"
    namespace = "Weblog/Webmention"
    value     = "1"
    dimensions = {
      JobType = "$.job_type"
      Result  = "$.result"
    }
  }
}

resource "aws_cloudwatch_event_rule" "webmention_reverification" {
  name                = "weblog-webmention-reverification-production"
  schedule_expression = "cron(30 18 * * ? *)"
  state               = var.webmention_verification_enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "webmention_reverification" {
  rule = aws_cloudwatch_event_rule.webmention_reverification.name
  arn  = aws_lambda_function.webmention_worker.arn
}

resource "aws_lambda_permission" "webmention_reverification" {
  statement_id  = "AllowDailyWebmentionReverification"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webmention_worker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.webmention_reverification.arn
}

resource "aws_iam_role" "webmention_publisher_runtime" {
  name               = "weblog-webmention-publisher-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "webmention_publisher" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.weblog.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.webmention_publish.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.webmention.arn]
  }
}

resource "aws_iam_role_policy" "webmention_publisher" {
  name   = "PublishWebmentionSources"
  role   = aws_iam_role.webmention_publisher_runtime.id
  policy = data.aws_iam_policy_document.webmention_publisher.json
}

resource "aws_iam_role_policy_attachment" "webmention_publisher_logs" {
  role       = aws_iam_role.webmention_publisher_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "webmention_publisher" {
  function_name = "weblog-webmention-publisher-production"
  package_type  = "Image"
  image_uri     = aws_lambda_function.authoring.image_uri
  role          = aws_iam_role.webmention_publisher_runtime.arn
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 60

  image_config {
    command = ["webmention_site_publisher.WeblogAuthoring::WebmentionSitePublisherHandler.call"]
  }

  environment {
    variables = {
      CLOUDFRONT_DISTRIBUTION_ID = aws_cloudfront_distribution.weblog.id
      DSQL_HOST                  = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      SITE_BUCKET                = aws_s3_bucket.site.id
      WEBMENTION_QUEUE_URL       = aws_sqs_queue.webmention.url
      WEBMENTION_SENDER_ENABLED  = tostring(var.webmention_sender_enabled)
    }
  }

  depends_on = [
    aws_iam_role_policy.webmention_publisher,
    aws_iam_role_policy_attachment.webmention_publisher_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_event_source_mapping" "webmention_publisher" {
  event_source_arn = aws_sqs_queue.webmention_publish.arn
  function_name    = aws_lambda_function.webmention_publisher.arn
  batch_size       = 1
  enabled          = var.webmention_publisher_enabled
}

resource "aws_cloudwatch_log_group" "webmention_publisher" {
  name              = "/aws/lambda/${aws_lambda_function.webmention_publisher.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_event_rule" "webmention_outbox_dispatch" {
  name                = "weblog-webmention-outbox-dispatch-production"
  schedule_expression = "rate(5 minutes)"
  state               = var.webmention_publisher_enabled ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "webmention_outbox_dispatch" {
  rule = aws_cloudwatch_event_rule.webmention_outbox_dispatch.name
  arn  = aws_lambda_function.webmention_publisher.arn
}

resource "aws_lambda_permission" "webmention_outbox_dispatch" {
  statement_id  = "AllowWebmentionOutboxDispatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webmention_publisher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.webmention_outbox_dispatch.arn
}

resource "aws_iam_role" "webmention_cleanup_runtime" {
  name               = "weblog-webmention-cleanup-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "webmention_cleanup" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }
}

resource "aws_iam_role_policy" "webmention_cleanup" {
  name   = "CleanupWebmentionData"
  role   = aws_iam_role.webmention_cleanup_runtime.id
  policy = data.aws_iam_policy_document.webmention_cleanup.json
}

resource "aws_iam_role_policy_attachment" "webmention_cleanup_logs" {
  role       = aws_iam_role.webmention_cleanup_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "webmention_cleanup" {
  function_name = "weblog-webmention-cleanup-production"
  package_type  = "Image"
  image_uri     = aws_lambda_function.authoring.image_uri
  role          = aws_iam_role.webmention_cleanup_runtime.arn
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 60

  image_config {
    command = ["webmention_cleanup.WeblogAuthoring::WebmentionCleanupHandler.call"]
  }

  environment {
    variables = {
      DSQL_HOST                     = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      WEBMENTION_CLEANUP_BATCH_SIZE = "500"
      WEBMENTION_CLEANUP_DRY_RUN    = "true"
    }
  }

  depends_on = [
    aws_iam_role_policy.webmention_cleanup,
    aws_iam_role_policy_attachment.webmention_cleanup_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_cloudwatch_log_group" "webmention_cleanup" {
  name              = "/aws/lambda/${aws_lambda_function.webmention_cleanup.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_event_rule" "webmention_cleanup" {
  name                = "weblog-webmention-cleanup-production"
  schedule_expression = "cron(15 18 * * ? *)"
}

resource "aws_cloudwatch_event_target" "webmention_cleanup" {
  rule = aws_cloudwatch_event_rule.webmention_cleanup.name
  arn  = aws_lambda_function.webmention_cleanup.arn
}

resource "aws_lambda_permission" "webmention_cleanup" {
  statement_id  = "AllowDailyWebmentionCleanup"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webmention_cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.webmention_cleanup.arn
}

resource "aws_cloudwatch_metric_alarm" "webmention_dead_letters" {
  alarm_name          = "weblog-webmention-dead-letters-production"
  alarm_description   = "A Webmention exhausted its verification or delivery retries. Runbook: ${local.webmention_runbook_url}#dead-letters"
  actions_enabled     = var.webmention_alerting_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention_dead_letter.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_publish_dead_letters" {
  alarm_name          = "weblog-webmention-publish-dead-letters-production"
  alarm_description   = "A static publish job exhausted its retries. Runbook: ${local.webmention_runbook_url}#dead-letters"
  actions_enabled     = var.webmention_alerting_enabled && var.webmention_publisher_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention_publish_dead_letter.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_queue_age_warning" {
  alarm_name          = "weblog-webmention-queue-age-warning-production"
  alarm_description   = "A Webmention has waited more than five minutes. Runbook: ${local.webmention_runbook_url}#queue-backlog"
  actions_enabled     = var.webmention_alerting_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 300
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_queue_age_critical" {
  alarm_name          = "weblog-webmention-queue-age-critical-production"
  alarm_description   = "A Webmention has waited more than thirty minutes. Runbook: ${local.webmention_runbook_url}#queue-backlog"
  actions_enabled     = var.webmention_alerting_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1800
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_queue_depth_warning" {
  alarm_name          = "weblog-webmention-queue-depth-warning-production"
  alarm_description   = "More than one hundred Webmentions are waiting. Runbook: ${local.webmention_runbook_url}#queue-backlog"
  actions_enabled     = var.webmention_alerting_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_queue_depth_critical" {
  alarm_name          = "weblog-webmention-queue-depth-critical-production"
  alarm_description   = "More than one thousand Webmentions are waiting. Runbook: ${local.webmention_runbook_url}#queue-backlog"
  actions_enabled     = var.webmention_alerting_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1000
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_publish_queue_age_critical" {
  alarm_name          = "weblog-webmention-publish-queue-age-critical-production"
  alarm_description   = "A static publish job has waited more than thirty minutes. Runbook: ${local.webmention_runbook_url}#queue-backlog"
  actions_enabled     = var.webmention_alerting_enabled && var.webmention_publisher_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1800
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.webmention_publish.name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_lambda_errors" {
  for_each = local.webmention_lambda_functions

  alarm_name          = "weblog-webmention-${each.key}-errors-production"
  alarm_description   = "The Webmention ${each.key} Lambda failed. Runbook: ${local.webmention_runbook_url}#lambda-errors"
  actions_enabled     = var.webmention_alerting_enabled && (each.key != "publisher" || var.webmention_publisher_enabled)
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "webmention_receiver_throttles" {
  alarm_name          = "weblog-webmention-receiver-throttles-production"
  alarm_description   = "The public Webmention receiver was throttled. Runbook: ${local.webmention_runbook_url}#receiver-throttles"
  actions_enabled     = var.webmention_alerting_enabled
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.webmention_receiver.function_name
  }
  alarm_actions = [aws_sns_topic.inbox_alerts.arn]
  ok_actions    = [aws_sns_topic.inbox_alerts.arn]
}
