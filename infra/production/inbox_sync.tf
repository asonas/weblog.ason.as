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
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.inbox_sources.arn]
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
      DSQL_HOST               = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      INBOX_SOURCES_SECRET_ID = aws_secretsmanager_secret.inbox_sources.name
    }
  }

  depends_on = [
    aws_iam_role_policy.inbox_sync_runtime,
    aws_iam_role_policy_attachment.inbox_sync_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
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
