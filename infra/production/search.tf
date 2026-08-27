resource "aws_sqs_queue" "search_index_dead_letter" {
  name                        = "weblog-search-index-dead-letter-production.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600
}

resource "aws_sqs_queue" "search_index" {
  name                        = "weblog-search-index-production.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  delay_seconds               = 300
  visibility_timeout_seconds  = 1800
  message_retention_seconds   = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.search_index_dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_cloudwatch_event_rule" "search_index_nightly" {
  name                = "weblog-search-index-nightly-production"
  description         = "Recover any missed weblog search index updates"
  schedule_expression = "cron(0 18 * * ? *)"
}

resource "aws_cloudwatch_event_target" "search_index_nightly" {
  rule      = aws_cloudwatch_event_rule.search_index_nightly.name
  target_id = "search-index-queue"
  arn       = aws_sqs_queue.search_index.arn

  sqs_target {
    message_group_id = "search-index"
  }
}

data "aws_iam_policy_document" "search_index_event_queue" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.search_index.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.search_index_nightly.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "search_index_event" {
  queue_url = aws_sqs_queue.search_index.id
  policy    = data.aws_iam_policy_document.search_index_event_queue.json
}

resource "aws_iam_role" "search_indexer_runtime" {
  name               = "weblog-search-indexer-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "search_indexer_basic_execution" {
  role       = aws_iam_role.search_indexer_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "search_indexer_runtime" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["search/*"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.site.arn}/search/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.search_index.arn]
  }
}

resource "aws_iam_role_policy" "search_indexer_runtime" {
  name   = "SearchIndexerRuntime"
  role   = aws_iam_role.search_indexer_runtime.id
  policy = data.aws_iam_policy_document.search_indexer_runtime.json
}

data "aws_iam_policy_document" "search_index_notify" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.search_index.arn]
  }
}

resource "aws_iam_role_policy" "search_index_notify" {
  name   = "NotifySearchIndexer"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.search_index_notify.json
}

resource "aws_lambda_function" "search_indexer" {
  function_name = "weblog-search-indexer-production"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.search_indexer.repository_url}:bootstrap"
  role          = aws_iam_role.search_indexer_runtime.arn
  architectures = ["arm64"]
  memory_size   = 1024
  timeout       = 300

  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = {
      DSQL_HOST   = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      SITE_BUCKET = aws_s3_bucket.site.id
    }
  }

  depends_on = [
    aws_iam_role_policy.search_indexer_runtime,
    aws_iam_role_policy_attachment.search_indexer_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_event_source_mapping" "search_indexer" {
  event_source_arn = aws_sqs_queue.search_index.arn
  function_name    = aws_lambda_function.search_indexer.arn
  batch_size       = 1
}

resource "aws_cloudwatch_metric_alarm" "search_index_dead_letters" {
  alarm_name          = "weblog-search-index-dead-letters-production"
  alarm_description   = "Search index updates exhausted their retries"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.search_index_dead_letter.name
  }
}

resource "aws_cloudwatch_metric_alarm" "search_index_queue_age" {
  alarm_name          = "weblog-search-index-queue-age-production"
  alarm_description   = "Search index updates have not completed within 15 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.search_index.name
  }
}

resource "aws_cloudwatch_metric_alarm" "search_index_generation_errors" {
  alarm_name          = "weblog-search-index-generation-errors-production"
  alarm_description   = "Search index generation failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.search_indexer.function_name
  }
}
