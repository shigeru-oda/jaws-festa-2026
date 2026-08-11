provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project   = "jaws-festa-2026-s3tables-demo"
      ManagedBy = "terraform"
      Purpose   = "conference-talk-verification"
    }
  }
}

data "aws_caller_identity" "current" {}
