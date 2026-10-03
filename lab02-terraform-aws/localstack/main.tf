# Luyện module network trên LocalStack:
#   docker compose up -d && terraform init && terraform apply -auto-approve
#   aws --endpoint-url http://localhost:4566 ec2 describe-subnets --query 'Subnets[].CidrBlock'
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  endpoints {
    ec2  = "http://localhost:4566"
    s3   = "http://localhost:4566"
    iam  = "http://localhost:4566"
    sts  = "http://localhost:4566"
    logs = "http://localhost:4566"
    ssm  = "http://localhost:4566"
  }
}

module "network" {
  source             = "../modules/network"
  name               = "ls-dev"
  region             = "us-east-1"
  cidr               = "10.20.0.0/16"
  az_count           = 2
  enable_nat         = true
  single_nat_gateway = false # thử 2 NAT rồi so sánh số route/NAT với single_nat_gateway = true
}

output "subnets" {
  value = {
    public  = module.network.public_subnet_ids
    private = module.network.private_subnet_ids
  }
}
