# Stack "cluster": k3s (1 server + ASG agent) – có thể destroy/dựng lại bất cứ lúc nào.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
  backend "s3" {} # key = lab10/cluster.tfstate
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "devops-labs", Lab = "10", Stack = "cluster", ManagedBy = "terraform" } }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "my_ip" {
  description = "IP/32 của bạn – được gọi Kubernetes API :6443"
  type        = string
}

variable "eip_allocation_id" { type = string }
variable "eip_public_ip" { type = string }

variable "token_param" {
  type    = string
  default = "/shop/capstone/k3s-token"
}

variable "server_type" {
  type    = string
  default = "t3.medium"
}

variable "agent_type" {
  type    = string
  default = "t3.medium"
}

variable "agent_count" {
  type    = number
  default = 2
}

locals { name = "shop-capstone" }

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Không dùng NAT (tiết kiệm credit): node nằm ở public subnet, chặn inbound bằng SG, quản trị qua SSM.
module "network" {
  source     = "../../../lab02-terraform-aws/modules/network"
  name       = local.name
  region     = var.region
  cidr       = "10.50.0.0/16"
  az_count   = 2
  enable_nat = false
}

resource "aws_security_group" "nodes" {
  name        = "${local.name}-nodes"
  description = "k3s nodes"
  vpc_id      = module.network.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "node <-> node (flannel VXLAN, kubelet, k3s)"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "api" {
  security_group_id = aws_security_group.nodes.id
  description       = "Kubernetes API from admin IP"
  cidr_ipv4         = var.my_ip
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.nodes.id
  description       = "Ingress ${each.key}"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  description       = "all outbound (no NAT; public subnet)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Public subnet cần route ra IGW (module network đã tạo route table public).
resource "aws_instance" "server" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.server_type
  subnet_id                   = module.network.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  iam_instance_profile        = "LabInstanceProfile"
  associate_public_ip_address = true
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # pod (backup CronJob) cần gọi IMDS để lấy credential
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }
  user_data = templatefile("${path.module}/server.sh.tftpl", {
    region = var.region, token_param = var.token_param, eip = var.eip_public_ip
  })
  user_data_replace_on_change = true
  tags                        = { Name = "${local.name}-server", Role = "k3s-server" }
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = var.eip_allocation_id
}

resource "aws_launch_template" "agent" {
  name_prefix   = "${local.name}-agent-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.agent_type
  iam_instance_profile { name = "LabInstanceProfile" }
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.nodes.id]
  }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type = "gp3"
      volume_size = 30
      encrypted   = true
    }
  }
  user_data = base64encode(templatefile("${path.module}/agent.sh.tftpl", {
    region = var.region, token_param = var.token_param, server_ip = aws_instance.server.private_ip
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-agent", Role = "k3s-agent" }
  }
}

# Agent trong ASG: node chết → ASG tạo node mới → tự join cluster (self-healing ở tầng hạ tầng)
resource "aws_autoscaling_group" "agents" {
  name                = "${local.name}-agents"
  vpc_zone_identifier = module.network.public_subnet_ids
  min_size            = var.agent_count
  max_size            = var.agent_count + 1
  desired_capacity    = var.agent_count
  health_check_type   = "EC2"
  launch_template {
    id      = aws_launch_template.agent.id
    version = aws_launch_template.agent.latest_version
  }
  tag {
    key                 = "Name"
    value               = "${local.name}-agent"
    propagate_at_launch = true
  }
}

output "server_instance_id" { value = aws_instance.server.id }
output "api_endpoint" { value = "https://${var.eip_public_ip}:6443" }
output "agents_asg" { value = aws_autoscaling_group.agents.name }
