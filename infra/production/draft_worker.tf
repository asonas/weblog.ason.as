resource "aws_iam_role" "draft_worker_runtime" {
  name               = "weblog-draft-worker-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "draft_worker_basic_execution" {
  role       = aws_iam_role.draft_worker_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "draft_worker_runtime" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }
}

resource "aws_iam_role_policy" "draft_worker_runtime" {
  name   = "DraftWorkerRuntime"
  role   = aws_iam_role.draft_worker_runtime.id
  policy = data.aws_iam_policy_document.draft_worker_runtime.json
}

resource "aws_cloudwatch_log_group" "draft_worker" {
  name              = "/weblog/lambda/draft-worker-production"
  retention_in_days = 14
}

resource "aws_lambda_function" "draft_worker" {
  function_name                  = "weblog-draft-worker-production"
  package_type                   = "Image"
  image_uri                      = "${aws_ecr_repository.draft_worker.repository_url}:bootstrap"
  role                           = aws_iam_role.draft_worker_runtime.arn
  architectures                  = ["arm64"]
  memory_size                    = 1024
  timeout                        = 300
  reserved_concurrent_executions = 1

  environment {
    variables = {
      DSQL_HOST             = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      DRAFT_CUTOVER_ENABLED = "true"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.draft_worker.name
  }

  depends_on = [
    aws_iam_role_policy.draft_worker_runtime,
    aws_iam_role_policy_attachment.draft_worker_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_cloudwatch_event_rule" "draft_worker" {
  name                = "weblog-draft-worker-production"
  description         = "Verify and compact durable draft histories"
  schedule_expression = "rate(1 hour)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "draft_worker" {
  rule      = aws_cloudwatch_event_rule.draft_worker.name
  target_id = "draft-worker-lambda"
  arn       = aws_lambda_function.draft_worker.arn
}

resource "aws_lambda_permission" "draft_worker_event" {
  statement_id  = "AllowEventBridgeDraftWorker"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.draft_worker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.draft_worker.arn
}
