locals {
  name     = "shop-${var.env}"
  app_port = 8000
}

data "aws_iam_role" "lab" { name = "LabRole" } # Learner Lab: dùng cho execution role + task role

module "network" {
  source             = "../../lab02-terraform-aws/modules/network"
  name               = local.name
  region             = var.region
  cidr               = "10.40.0.0/16"
  az_count           = 2
  enable_nat         = true
  single_nat_gateway = true
}

# ------------------------------------------------------------------ ECR
resource "aws_ecr_repository" "app" {
  name                 = "shopmini-${var.env}"
  image_tag_mutability = "IMMUTABLE" # tag không ghi đè được → deploy tái lập
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

# ------------------------------------------------------------------ Security groups
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ALB"
  vpc_id      = module.network.vpc_id
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description     = "to tasks"
    from_port       = local.app_port
    to_port         = local.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "ECS tasks"
  vpc_id      = module.network.vpc_id
}

# Tất cả rule của SG task viết bằng resource riêng (không trộn inline rule → tránh drift)
resource "aws_vpc_security_group_egress_rule" "task_https" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS (ECR, Secrets Manager, CloudWatch Logs, SSM)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_db" {
  security_group_id            = aws_security_group.task.id
  description                  = "Postgres"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  description                  = "App port from ALB"
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.app_port
  to_port                      = local.app_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS Postgres"
  vpc_id      = module.network.vpc_id
  ingress {
    description     = "Postgres chỉ từ ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }
}
