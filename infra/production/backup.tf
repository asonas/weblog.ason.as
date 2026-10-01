resource "aws_backup_vault" "article_migration" {
  name          = "weblog-article-migration-production"
  force_destroy = false
}

data "aws_iam_policy_document" "article_backup_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "article_backup" {
  name               = "WeblogArticleMigrationBackup"
  description        = "DSQL migration backup and restore for infra/production."
  assume_role_policy = data.aws_iam_policy_document.article_backup_trust.json
}

data "aws_iam_policy_document" "article_backup" {
  statement {
    actions = [
      "dsql:StartBackupJob",
      "dsql:GetBackupJob",
      "dsql:StopBackupJob",
      "dsql:GetCluster",
      "dsql:ListTagsForResource",
    ]
    resources = [aws_dsql_cluster.weblog.arn]
  }

  statement {
    actions   = ["dsql:ListClusters"]
    resources = ["*"]
  }

  statement {
    actions = [
      "dsql:StartRestoreJob",
      "dsql:GetRestoreJob",
      "dsql:StopRestoreJob",
      "dsql:TagResource",
      "dsql:CreateCluster",
      "dsql:UpdateCluster",
      "dsql:GetCluster",
    ]
    resources = ["arn:aws:dsql:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/*"]
  }

  statement {
    actions   = ["backup:TagResource"]
    resources = ["arn:aws:backup:${var.aws_region}:${data.aws_caller_identity.current.account_id}:recovery-point:*"]
  }

  statement {
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:ReEncryptTo",
      "kms:ReEncryptFrom",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["dsql.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "article_backup" {
  name   = "DSQLMigrationBackup"
  role   = aws_iam_role.article_backup.id
  policy = data.aws_iam_policy_document.article_backup.json
}

output "article_migration_backup_vault" {
  value = aws_backup_vault.article_migration.name
}

output "article_migration_backup_role_arn" {
  value = aws_iam_role.article_backup.arn
}
