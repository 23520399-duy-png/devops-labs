# 3 EC2 làm "fleet" cho Ansible: 2 Ubuntu 24.04 + 1 Amazon Linux 2023, trong default VPC.
#   terraform init && terraform apply -var my_ip=$(curl -s https://checkip.amazonaws.com)/32
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags { tags = { Project = "devops-labs", Lab = "03", ManagedBy = "terraform" } }
}

variable "my_ip" {
  description = "IP công khai của bạn dạng x.x.x.x/32 – chỉ IP này được SSH"
  type        = string
}

variable "key_name" {
  type    = string
  default = "vockey" # key pair có sẵn trong Learner Lab
}

data "aws_vpc" "default" { default = true }

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "fleet" {
  name        = "lab03-fleet"
  description = "SSH and app from my IP only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }
  ingress {
    description = "node_exporter"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }
  ingress {
    description = "app"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }
  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  hosts = {
    web-1 = { ami = data.aws_ssm_parameter.ubuntu.value, os = "ubuntu" }
    web-2 = { ami = data.aws_ssm_parameter.ubuntu.value, os = "ubuntu" }
    web-3 = { ami = data.aws_ssm_parameter.al2023.value, os = "al2023" }
  }
}

resource "aws_instance" "fleet" {
  for_each               = local.hosts
  ami                    = each.value.ami
  instance_type          = "t3.micro"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.fleet.id]
  iam_instance_profile   = "LabInstanceProfile"

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = 12
    encrypted   = true
  }
  tags = { Name = each.key, Role = "web", Os = each.value.os }
}

output "hosts" {
  value = { for k, v in aws_instance.fleet : k => v.public_ip }
}
