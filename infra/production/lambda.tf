resource "aws_lambda_function" "authoring" {
  function_name = "weblog-authoring-production"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.authoring.repository_url}:bootstrap-10"
  role          = aws_iam_role.authoring_runtime.arn
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 15

  environment {
    variables = {
      DSQL_HOST              = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      FRONTEND_URL           = "https://weblog.ason.as"
      GITHUB_ALLOWED_USER_ID = "630181"
      GITHUB_REDIRECT_URI    = "https://weblog.ason.as/api/auth/github/callback"
      OAUTH_SECRET_ID        = aws_secretsmanager_secret.oauth.name
      ASSET_BUCKET           = aws_s3_bucket.site.id
      SITE_BUCKET            = aws_s3_bucket.site.id
      SEARCH_INDEX_QUEUE_URL = aws_sqs_queue.search_index.url
    }
  }

  depends_on = [
    aws_iam_role_policy.dsql_connect,
    aws_iam_role_policy.embed_cache,
    aws_iam_role_policy.feed_publish,
    aws_iam_role_policy.image_upload,
    aws_iam_role_policy.oauth_secret,
    aws_iam_role_policy.search_index_notify,
    aws_iam_role_policy.search_index_read,
    aws_iam_role_policy_attachment.lambda_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}
