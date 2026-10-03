terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
  # Partial backend config: giá trị nằm trong backend.hcl (không hard-code tên bucket vào code)
  # terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "devops-labs"
      Lab       = "02"
      Env       = var.env
      ManagedBy = "terraform"
      Owner     = var.owner
    }
  }
}
