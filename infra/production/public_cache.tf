variable "public_cache_enabled" {
  description = "Enable publication-only invalidations and one-hour public HTML caching after schema and worker deployment."
  type        = bool
  default     = true
}

variable "public_cache_distribution_id" {
  description = "Existing site distribution ID, supplied separately to avoid a Lambda/API/CloudFront dependency cycle."
  type        = string
  default     = "E3BCWEKGAG5LSG"
}

data "aws_iam_policy_document" "public_cache_write" {
  statement {
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${var.public_cache_distribution_id}"]
  }
}

resource "aws_iam_role_policy" "public_cache_write" {
  name   = "PublicArticleCache"
  role   = aws_iam_role.search_indexer_runtime.id
  policy = data.aws_iam_policy_document.public_cache_write.json
}

data "aws_iam_policy_document" "public_cache_usage" {
  statement {
    actions   = ["cloudfront:ListDistributions"]
    resources = ["*"]
  }

  statement {
    actions   = ["cloudfront:ListInvalidations", "cloudfront:GetInvalidation"]
    resources = ["arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.site.arn}/operations/public-cache-usage.json"]
  }
}

resource "aws_iam_role_policy" "public_cache_usage" {
  name   = "PublicCacheUsage"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.public_cache_usage.json
}
