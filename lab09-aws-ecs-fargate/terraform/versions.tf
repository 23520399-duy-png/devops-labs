terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
  backend "s3" {} # terraform init -backend-config=backend.hcl (dùng lại bucket của Lab 02, key khác)
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "devops-labs", Lab = "09", ManagedBy = "terraform", Env = var.env }
  }
}
