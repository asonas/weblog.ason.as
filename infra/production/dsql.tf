resource "aws_dsql_cluster" "weblog" {
  deletion_protection_enabled = true
  kms_encryption_key          = "AWS_OWNED_KMS_KEY"

  tags = {
    Name = "weblog-ason-as-production"
  }
}
