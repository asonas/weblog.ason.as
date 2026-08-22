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
