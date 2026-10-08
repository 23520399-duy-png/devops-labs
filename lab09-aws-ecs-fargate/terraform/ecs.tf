resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled" # metric CPU/memory theo task/service trong CloudWatch
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = data.aws_iam_role.lab.arn # kéo image, ghi log, đọc secret
  task_role_arn            = data.aws_iam_role.lab.arn # quyền của app (Learner Lab: dùng chung LabRole)
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume { name = "tmp" } # Fargate không hỗ trợ tmpfs → dùng ephemeral volume cho /tmp

  container_definitions = jsonencode([{
    name                   = "api"
    image                  = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = local.app_port, protocol = "tcp" }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp" }]
    environment = [
      { name = "APP_VERSION", value = var.image_tag },
      { name = "DB_HOST", value = aws_db_instance.this.address },
      { name = "DB_NAME", value = "shop" },
      { name = "WORKERS", value = "1" },
      { name = "CHAOS_ENABLED", value = var.chaos_error_rate > 0 ? "true" : "false" },
      { name = "CHAOS_ERROR_RATE", value = tostring(var.chaos_error_rate) },
      { name = "FAIL_READINESS", value = tostring(var.fail_readiness) },
    ]
    # Secret KHÔNG nằm trong task definition – ECS lấy từ Secrets Manager lúc khởi động task
    secrets = [
      { name = "DB_USER", valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::" },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)\""]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
    stopTimeout = 25
  }])
}

resource "aws_lb" "this" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = module.network.public_subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name}-tg"
  port                 = local.app_port
  protocol             = "HTTP"
  target_type          = "ip" # Fargate (awsvpc) đăng ký theo IP
  vpc_id               = module.network.vpc_id
  deregistration_delay = 20
  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_service" "app" {
  name                              = "shopmini"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.app.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30
  enable_execute_command            = true # ECS Exec (qua SSM) để debug trong container
  propagate_tags                    = "SERVICE"
  wait_for_steady_state             = false

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true # deploy hỏng → tự quay về task definition trước
  }

  network_configuration {
    subnets          = module.network.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "api"
    container_port   = local.app_port
  }

  lifecycle {
    ignore_changes = [desired_count] # để Application Auto Scaling điều chỉnh
  }
  depends_on = [aws_lb_listener.http]
}

# ------------------------------------------------------------------ Auto Scaling
resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 6
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu60"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 30
  }
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "${local.name}-req-per-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = 300 # request/phút mỗi task
  }
}
