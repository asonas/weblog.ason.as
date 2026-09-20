variable "draft_cutover_enabled" {
  description = "Use the initialized cutover control for API and workers; requires separate activation approval."
  type        = bool
  default     = false
}

variable "draft_reader_routing_enabled" {
  description = "Route article HTML and Atom through the phase-controlled API after gated workers are deployed."
  type        = bool
  default     = false

  validation {
    condition     = !var.draft_reader_routing_enabled || var.draft_cutover_enabled
    error_message = "Reader routing requires the cutover runtime."
  }
}

variable "legacy_generators_paused" {
  description = "Pause legacy article/search generators after their pending publication has drained."
  type        = bool
  default     = false
}

variable "draft_maintenance_enabled" {
  description = "Enable scheduled compaction only after draft editing has reopened."
  type        = bool
  default     = false

  validation {
    condition     = !var.draft_maintenance_enabled || (var.draft_cutover_enabled && var.legacy_generators_paused && var.draft_reader_routing_enabled)
    error_message = "Draft maintenance requires completed cutover routing and retired legacy generators."
  }
}

locals {
  draft_runtime_environment = var.draft_cutover_enabled ? {
    DRAFT_CUTOVER_ENABLED           = "true"
    DRAFT_WORKER_FUNCTION_NAME      = aws_lambda_function.draft_worker.function_name
    DRAFT_PUBLICATION_FUNCTION_NAME = "weblog-search-indexer-production"
  } : {}
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
  count  = var.draft_cutover_enabled ? 1 : 0
  name   = "DraftRuntime"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.draft_runtime.json
}

data "aws_iam_policy_document" "draft_publication_worker" {
  source_policy_documents = [data.aws_iam_policy_document.draft_runtime.json]

  statement {
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.site.arn}/published/*",
      "${aws_s3_bucket.site.arn}/published-outputs/*",
    ]
  }
}

resource "aws_iam_role_policy" "draft_publication_worker" {
  count  = var.draft_cutover_enabled ? 1 : 0
  name   = "DraftPublication"
  role   = aws_iam_role.search_indexer_runtime.id
  policy = data.aws_iam_policy_document.draft_publication_worker.json
}

resource "aws_apigatewayv2_route" "draft_cutover" {
  for_each = var.draft_cutover_enabled ? toset([
    "ANY /api/authoring/drafts",
    "ANY /api/authoring/drafts/{path+}",
    "GET /",
    "HEAD /",
    "GET /{path+}",
    "HEAD /{path+}",
  ]) : toset([])

  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = each.value
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.authoring.id}"
}
