# Values are initialized by operators; write-only bootstrap values keep them out of state.
resource "aws_ssm_parameter" "oauth" {
  name             = "/weblog-authoring-production/oauth"
  type             = "SecureString"
  tier             = "Standard"
  value_wo         = "{}"
  value_wo_version = 1
}

data "aws_iam_policy_document" "oauth_secret" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.oauth.arn]
  }
}

resource "aws_iam_role_policy" "oauth_secret" {
  name   = "ReadOAuthSecret"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.oauth_secret.json
}

resource "aws_ssm_parameter" "inbox_sources" {
  name             = "/weblog-authoring-production/inbox-sources"
  type             = "SecureString"
  tier             = "Standard"
  value_wo         = "{}"
  value_wo_version = 1
}

data "aws_ssoadmin_instances" "current" {}

data "aws_ssoadmin_permission_set" "authoring_development" {
  instance_arn = one(data.aws_ssoadmin_instances.current.arns)
  name         = "weblog-authoring-development"
}

resource "aws_ssm_parameter" "inbox_sources_development" {
  name             = "/weblog-authoring-development/inbox-sources"
  type             = "SecureString"
  tier             = "Standard"
  value_wo         = "{}"
  value_wo_version = 1

  tags = {
    Environment = "development"
  }
}

data "aws_iam_policy_document" "inbox_sources_development" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.inbox_sources_development.arn]
  }
}

resource "aws_iam_policy" "inbox_sources_development" {
  name   = "ReadInboxSourcesParameter"
  policy = data.aws_iam_policy_document.inbox_sources_development.json
}

resource "aws_ssoadmin_customer_managed_policy_attachment" "inbox_sources_development" {
  instance_arn       = one(data.aws_ssoadmin_instances.current.arns)
  permission_set_arn = data.aws_ssoadmin_permission_set.authoring_development.arn

  customer_managed_policy_reference {
    name = aws_iam_policy.inbox_sources_development.name
    path = aws_iam_policy.inbox_sources_development.path
  }
}

resource "aws_ssm_parameter" "inbox_matrix" {
  name             = "/weblog-authoring-production/inbox-matrix"
  type             = "SecureString"
  tier             = "Standard"
  value_wo         = "{}"
  value_wo_version = 1
}
