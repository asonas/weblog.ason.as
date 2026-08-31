resource "aws_secretsmanager_secret" "oauth" {
  name                    = "weblog-authoring-production/oauth"
  recovery_window_in_days = 7
}

data "aws_iam_policy_document" "oauth_secret" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.oauth.arn]
  }
}

resource "aws_iam_role_policy" "oauth_secret" {
  name   = "ReadOAuthSecret"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.oauth_secret.json
}

resource "aws_secretsmanager_secret" "inbox_sources" {
  name                    = "weblog-authoring-production/inbox-sources"
  recovery_window_in_days = 7
}

data "aws_iam_roles" "authoring_development" {
  name_regex  = "AWSReservedSSO_weblog-authoring-development_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

resource "aws_secretsmanager_secret" "inbox_sources_development" {
  name                    = "weblog-authoring-development/inbox-sources"
  recovery_window_in_days = 7

  tags = {
    Environment = "development"
  }
}

data "aws_iam_policy_document" "inbox_sources_development" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.inbox_sources_development.arn]

    principals {
      type        = "AWS"
      identifiers = data.aws_iam_roles.authoring_development.arns
    }
  }
}

resource "aws_secretsmanager_secret_policy" "inbox_sources_development" {
  secret_arn = aws_secretsmanager_secret.inbox_sources_development.arn
  policy     = data.aws_iam_policy_document.inbox_sources_development.json
}

resource "aws_secretsmanager_secret" "inbox_matrix" {
  name                    = "weblog-authoring-production/inbox-matrix"
  recovery_window_in_days = 7
}
