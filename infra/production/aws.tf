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

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Application = "weblog.ason.as"
      Environment = "production"
      ManagedBy   = "Terraform"
    }
  }
}
