terraform {
  required_version = "~> 1.15.0"

  backend "s3" {
    bucket       = "weblog-asonas-terraform-state"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
