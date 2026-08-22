output "terraform_state_bucket" {
  description = "S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "github_deploy_role_arn" {
  description = "IAM role assumed by the main branch deployment workflow."
  value       = aws_iam_role.github_deploy.arn
}

output "github_terraform_role_arn" {
  description = "IAM role assumed by the main branch Terraform workflow."
  value       = aws_iam_role.github_terraform.arn
}
