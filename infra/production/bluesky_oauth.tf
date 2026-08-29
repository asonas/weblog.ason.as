resource "aws_secretsmanager_secret" "bluesky_oauth" {
  name                    = "weblog-authoring-production/bluesky-oauth"
  recovery_window_in_days = 7
}

resource "aws_iam_role" "bluesky_oauth_runtime" {
  name               = "weblog-bluesky-oauth-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "bluesky_oauth_basic_execution" {
  role       = aws_iam_role.bluesky_oauth_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "bluesky_oauth_runtime" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.bluesky_oauth.arn]
  }
}

resource "aws_iam_role_policy" "bluesky_oauth_runtime" {
  name   = "BlueskyOAuthRuntime"
  role   = aws_iam_role.bluesky_oauth_runtime.id
  policy = data.aws_iam_policy_document.bluesky_oauth_runtime.json
}

resource "aws_lambda_function" "bluesky_oauth" {
  function_name = "weblog-bluesky-oauth-production"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.bluesky_oauth.repository_url}:bootstrap"
  role          = aws_iam_role.bluesky_oauth_runtime.arn
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30

  environment {
    variables = {
      DSQL_HOST               = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
      BLUESKY_OAUTH_SECRET_ID = aws_secretsmanager_secret.bluesky_oauth.name
    }
  }

  depends_on = [
    aws_iam_role_policy.bluesky_oauth_runtime,
    aws_iam_role_policy_attachment.bluesky_oauth_basic_execution,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

data "aws_iam_policy_document" "invoke_bluesky_oauth" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.bluesky_oauth.arn]
  }
}

resource "aws_iam_role_policy" "invoke_bluesky_oauth" {
  name   = "InvokeBlueskyOAuth"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.invoke_bluesky_oauth.json
}
