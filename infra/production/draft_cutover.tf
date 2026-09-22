locals {
  draft_runtime_environment = {
    DRAFT_CUTOVER_ENABLED           = "true"
    DRAFT_WORKER_FUNCTION_NAME      = aws_lambda_function.draft_worker.function_name
    DRAFT_PUBLICATION_FUNCTION_NAME = "weblog-search-indexer-production"
  }
}

data "aws_iam_policy_document" "draft_runtime" {
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.draft_worker.arn,
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:weblog-search-indexer-production",
    ]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }
}

resource "aws_iam_role_policy" "draft_api_runtime" {
  count  = 1
  name   = "DraftRuntime"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.draft_runtime.json
}

data "aws_iam_policy_document" "draft_publication_worker" {
  source_policy_documents = [data.aws_iam_policy_document.draft_runtime.json]

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.webmention.arn]
  }

  statement {
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.site.arn}/published/*",
      "${aws_s3_bucket.site.arn}/published-outputs/*",
    ]
  }
}

resource "aws_iam_role_policy" "draft_publication_worker" {
  count  = 1
  name   = "DraftPublication"
  role   = aws_iam_role.search_indexer_runtime.id
  policy = data.aws_iam_policy_document.draft_publication_worker.json
}

resource "aws_apigatewayv2_route" "draft_cutover" {
  for_each = toset([
    "ANY /api/authoring/drafts",
    "ANY /api/authoring/drafts/{path+}",
    "GET /",
    "HEAD /",
    "GET /{path+}",
    "HEAD /{path+}",
  ])

  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = each.value
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.authoring.id}"
}
