# ------------------------------------------------------------------ SNS
resource "aws_sns_topic" "alerts" { name = "${local.name}-alerts" }

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Cho EventBridge publish vào topic
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
      }
    ]
  })
}

locals {
  lb = aws_lb.this.arn_suffix
  tg = aws_lb_target_group.app.arn_suffix
}

# ------------------------------------------------------------------ Alarms (triệu chứng người dùng)
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${local.name}-5xx-rate"
  alarm_description   = "Tỷ lệ 5xx (ALB + target) > 5% trong 3/3 phút"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "IF(req > 0, 100 * (t5xx + e5xx) / req, 0)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "t5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = local.lb }
    }
  }
  metric_query {
    id = "e5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = local.lb }
    }
  }
  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = local.lb }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${local.name}-latency-p95"
  alarm_description   = "p95 TargetResponseTime > 500ms trong 5 phút"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0.5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = local.lb }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Composite: chỉ "gọi người" khi người dùng bị ảnh hưởng (lỗi HOẶC chậm), giảm noise
resource "aws_cloudwatch_composite_alarm" "user_impact" {
  alarm_name        = "${local.name}-USER-IMPACT"
  alarm_description = "Người dùng bị ảnh hưởng: lỗi hoặc chậm"
  alarm_rule        = "ALARM(\"${aws_cloudwatch_metric_alarm.error_rate.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.latency_p95.alarm_name}\")"
  alarm_actions     = [aws_sns_topic.alerts.arn]
  ok_actions        = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------------ Alarms (nguyên nhân / tài nguyên)
resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "${local.name}-unhealthy-targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = local.lb, TargetGroup = local.tg }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${local.name}-rds-free-storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------------ Log-based metric (log JSON của app)
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.name}-app-errors"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.level = \"ERROR\" || $.status >= 500 }"
  metric_transformation {
    name          = "AppErrorLogs"
    namespace     = "Shopmini"
    value         = "1"
    default_value = "0"
  }
}

# ------------------------------------------------------------------ EventBridge: sự kiện ECS → SNS
resource "aws_cloudwatch_event_rule" "ecs_deploy_failed" {
  name        = "${local.name}-ecs-deployment-failed"
  description = "Deployment ECS thất bại / circuit breaker rollback"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]
    resources     = [aws_ecs_service.app.id]
    detail        = { eventName = ["SERVICE_DEPLOYMENT_FAILED", "SERVICE_DEPLOYMENT_ROLLBACK_COMPLETED"] }
  })
}

resource "aws_cloudwatch_event_target" "ecs_deploy_failed" {
  rule = aws_cloudwatch_event_rule.ecs_deploy_failed.name
  arn  = aws_sns_topic.alerts.arn
  input_transformer {
    input_paths    = { evt = "$.detail.eventName", reason = "$.detail.reason", time = "$.time" }
    input_template = "\"[shopmini] <evt> lúc <time>: <reason>\""
  }
}

resource "aws_cloudwatch_event_rule" "task_stopped" {
  name        = "${local.name}-task-stopped-unexpected"
  description = "Task essential container thoát bất thường (không phải scale-in/deploy)"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn    = [aws_ecs_cluster.this.arn]
      lastStatus    = ["STOPPED"]
      stoppedReason = [{ "anything-but" = { prefix = "Scaling activity" } }]
      stopCode      = ["EssentialContainerExited", "TaskFailedToStart"]
    }
  })
}

resource "aws_cloudwatch_event_target" "task_stopped" {
  rule = aws_cloudwatch_event_rule.task_stopped.name
  arn  = aws_sns_topic.alerts.arn
  input_transformer {
    input_paths    = { task = "$.detail.taskArn", reason = "$.detail.stoppedReason" }
    input_template = "\"[shopmini] Task dừng bất thường: <task> – <reason>\""
  }
}
