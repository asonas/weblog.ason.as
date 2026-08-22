provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Application = "weblog.ason.as"
      Environment = "production"
      ManagedBy   = "Terraform"
    }
  }
}
