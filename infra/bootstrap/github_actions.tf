data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_actions_subject = "repo:asonas@630181/weblog.ason.as@1335130954:ref:refs/heads/main"
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_actions_subject]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "WeblogGitHubDeploy"
  description        = "Deploy weblog.ason.as from the main branch GitHub Actions workflow."
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrAuthentication"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PublishLambdaImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      "arn:aws:ecr:ap-northeast-1:${data.aws_caller_identity.current.account_id}:repository/weblog-authoring-production",
    ]
  }

  statement {
    sid    = "DeployLambda"
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
    ]
    resources = [
      "arn:aws:lambda:ap-northeast-1:${data.aws_caller_identity.current.account_id}:function:weblog-authoring-production",
    ]
  }

  statement {
    sid    = "ReadDevelopmentAssets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::weblog-asonas-assets-dev-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::weblog-asonas-assets-dev-${data.aws_caller_identity.current.account_id}/assets/*",
    ]
  }

  statement {
    sid    = "PublishSite"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::weblog-asonas-site-production-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::weblog-asonas-site-production-${data.aws_caller_identity.current.account_id}/*",
    ]
  }

  statement {
    sid       = "InvalidateSite"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"]
  }

  statement {
    sid       = "MigrateDatabase"
    effect    = "Allow"
    actions   = ["dsql:DbConnectAdmin"]
    resources = ["arn:aws:dsql:ap-northeast-1:${data.aws_caller_identity.current.account_id}:cluster/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = ["weblog-ason-as-production"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "DeployWeblog"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

resource "aws_iam_role" "github_terraform" {
  name               = "WeblogGitHubTerraform"
  description        = "Apply weblog.ason.as production Terraform from the main branch workflow."
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

data "aws_iam_policy_document" "github_terraform" {
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::weblog-asonas-terraform-state",
      "arn:aws:s3:::weblog-asonas-terraform-state/production/*",
    ]
  }

  statement {
    sid    = "ManageProductionServices"
    effect = "Allow"
    actions = [
      "acm:*",
      "apigateway:*",
      "cloudfront:*",
      "dsql:*",
      "ecr:*",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:ListTagsForResource",
      "events:ListTargetsByRule",
      "events:PutRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource",
      "lambda:*",
      "logs:*",
      "route53:*",
      "s3:*",
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:RemoveRegionsFromReplication",
      "secretsmanager:ReplicateSecretToRegions",
      "secretsmanager:RestoreSecret",
      "secretsmanager:RotateSecret",
      "secretsmanager:StopReplicationToReplica",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "secretsmanager:UpdateSecretVersionStage",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageWeblogRoles"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/weblog-*"]
  }

  statement {
    sid    = "ReadGitHubIdentityProvider"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_terraform" {
  name   = "ApplyWeblogTerraform"
  role   = aws_iam_role.github_terraform.id
  policy = data.aws_iam_policy_document.github_terraform.json
}
