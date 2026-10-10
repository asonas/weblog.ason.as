resource "aws_s3_bucket" "representative_article_logs" {
  bucket = "weblog-representative-article-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "representative_article_logs" {
  bucket                  = aws_s3_bucket.representative_article_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "representative_article_logs" {
  bucket = aws_s3_bucket.representative_article_logs.id

  rule {
    id     = "expire-comparison-logs"
    status = "Enabled"

    filter {
      prefix = "AWSLogs/"
    }

    expiration {
      days = 30
    }
  }
}

resource "aws_cloudwatch_log_delivery_source" "representative_articles" {
  provider     = aws.us_east_1
  name         = "weblog-representative-articles"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.weblog.arn
}

data "aws_iam_policy_document" "representative_article_logs" {
  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.representative_article_logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_log_delivery_source.representative_articles.arn]
    }
  }

  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.representative_article_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_log_delivery_source.representative_articles.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "representative_article_logs" {
  bucket = aws_s3_bucket.representative_article_logs.id
  policy = data.aws_iam_policy_document.representative_article_logs.json
}

resource "aws_cloudwatch_log_delivery_destination" "representative_articles" {
  provider      = aws.us_east_1
  name          = "weblog-representative-articles"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.representative_article_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "representative_articles" {
  provider                 = aws.us_east_1
  delivery_source_name     = aws_cloudwatch_log_delivery_source.representative_articles.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.representative_articles.arn
  record_fields = [
    "date",
    "time",
    "cs-method",
    "cs-uri-stem",
    "cs(User-Agent)",
    "c-ip",
    "sc-status",
    "x-edge-result-type",
    "x-edge-request-id",
    "sc-bytes",
    "time-taken",
    "time-to-first-byte",
  ]

  depends_on = [
    aws_s3_bucket_policy.representative_article_logs,
    aws_s3_bucket_public_access_block.representative_article_logs,
    aws_s3_bucket_lifecycle_configuration.representative_article_logs,
  ]
}
