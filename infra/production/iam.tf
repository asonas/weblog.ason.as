data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "authoring_runtime" {
  name               = "weblog-authoring-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "dsql_connect" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }
}

resource "aws_iam_role_policy" "dsql_connect" {
  name   = "AuroraDSQLConnect"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.dsql_connect.json
}

data "aws_iam_policy_document" "embed_cache" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["assets/embed-cache/*"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.site.arn}/assets/embed-cache/*"]
  }
}

resource "aws_iam_role_policy" "embed_cache" {
  name   = "EmbedCache"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.embed_cache.json
}

data "aws_iam_policy_document" "feed_publish" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.site.arn}/feed.xml"]
  }
}

resource "aws_iam_role_policy" "feed_publish" {
  name   = "PublishRssFeed"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.feed_publish.json
}

data "aws_iam_policy_document" "image_upload" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.site.arn}/assets/uploads/*"]
  }
}

resource "aws_iam_role_policy" "image_upload" {
  name   = "UploadImages"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.image_upload.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.authoring_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
