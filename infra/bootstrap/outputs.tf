output "terraform_state_bucket" {
  description = "S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.terraform_state.bucket
}
