# Stack "persistent": những thứ PHẢI sống sót qua thảm họa (không destroy trong DR drill).
#   - S3 bucket backup (DB dump + sealed-secrets key), versioning + lifecycle
#   - Elastic IP cố định → domain shop.<EIP>.nip.io không đổi khi dựng lại cluster
#   - Token k3s trong SSM Parameter Store (SecureString)
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "s3" {} # key = lab10/persistent.tfstate
}

provider "aws" {
  region = "us-east-1"
  default_tags { tags = { Project = "devops-labs", Lab = "10", Stack = "persistent", ManagedBy = "terraform" } }
}

data "aws_caller_identity" "me" {}

resource "random_id" "sfx" { byte_length = 3 }

resource "aws_s3_bucket" "backup" {
  bucket        = "shop-backup-${data.aws_caller_identity.me.account_id}-${random_id.sfx.hex}"
  force_destroy = true # môi trường học
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    id     = "db-dumps"
    status = "Enabled"
    filter { prefix = "db/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 3 }
  }
}

resource "aws_eip" "ingress" {
  domain = "vpc"
  tags   = { Name = "shop-capstone-ingress" }
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "k3s_token" {
  name  = "/shop/capstone/k3s-token"
  type  = "SecureString"
  value = random_password.k3s_token.result
}

output "backup_bucket" { value = aws_s3_bucket.backup.bucket }
output "eip_allocation_id" { value = aws_eip.ingress.allocation_id }
output "eip_public_ip" { value = aws_eip.ingress.public_ip }
output "shop_host" { value = "shop.${aws_eip.ingress.public_ip}.nip.io" }
output "token_param" { value = aws_ssm_parameter.k3s_token.name }
