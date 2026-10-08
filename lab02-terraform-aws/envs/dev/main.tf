locals {
  name = "shop-${var.env}"
}

# Learner Lab không cho tạo IAM role → dùng tài nguyên có sẵn.
data "aws_iam_instance_profile" "lab" {
  name = "LabInstanceProfile"
}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

resource "aws_ecr_repository" "app" {
  name                 = "shopmini"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # môi trường học

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Giữ 10 image gần nhất"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

module "network" {
  source             = "../../modules/network"
  name               = local.name
  region             = var.region
  cidr               = var.vpc_cidr
  az_count           = 2
  enable_nat         = true
  single_nat_gateway = true
  flow_logs_role_arn = var.enable_flow_logs ? data.aws_iam_role.lab.arn : ""
}

module "web" {
  source                = "../../modules/web-asg"
  name                  = local.name
  region                = var.region
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  private_subnet_ids    = module.network.private_subnet_ids
  container_image       = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  app_version           = var.image_tag
  instance_type         = var.instance_type
  instance_profile_name = data.aws_iam_instance_profile.lab.name
  min_size              = 2
  max_size              = 4
  desired_capacity      = 2
  allowed_cidr          = var.allowed_cidr
  alarm_topic_arn       = aws_sns_topic.alerts.arn
}
