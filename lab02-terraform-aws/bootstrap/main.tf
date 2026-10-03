# Bootstrap: tạo S3 bucket chứa Terraform state (chạy MỘT lần, state của chính nó để local).
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "devops-labs", ManagedBy = "terraform", Lab = "02-bootstrap" } }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

data "aws_caller_identity" "me" {}

resource "random_id" "suffix" { byte_length = 3 }

resource "aws_s3_bucket" "tfstate" {
  bucket        = "tfstate-${data.aws_caller_identity.me.account_id}-${random_id.suffix.hex}"
  force_destroy = true # chỉ vì đây là môi trường học – production KHÔNG bật
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

output "state_bucket" { value = aws_s3_bucket.tfstate.bucket }
