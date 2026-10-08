resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = "${local.name}-ops"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "alarm", x = 0, y = 0, width = 24, height = 3
        properties = {
          title = "Trạng thái alarm"
          alarms = [
            aws_cloudwatch_composite_alarm.user_impact.arn, aws_cloudwatch_metric_alarm.error_rate.arn,
            aws_cloudwatch_metric_alarm.latency_p95.arn, aws_cloudwatch_metric_alarm.unhealthy.arn,
            aws_cloudwatch_metric_alarm.rds_cpu.arn, aws_cloudwatch_metric_alarm.rds_storage.arn
          ]
        }
      },
      {
        type = "metric", x = 0, y = 3, width = 12, height = 6
        properties = {
          title = "Request & 5xx (ALB)", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 3, width = 12, height = 6
        properties = {
          title = "Latency p50/p95/p99", region = var.region, period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 9, width = 12, height = 6
        properties = {
          title = "ECS CPU / Memory (%) & số task", region = var.region, period = 60, stat = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.app.name],
            [".", "MemoryUtilization", ".", ".", ".", "."],
            ["ECS/ContainerInsights", "RunningTaskCount", ".", ".", ".", ".", { yAxis = "right" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 9, width = 12, height = 6
        properties = {
          title = "RDS", region = var.region, period = 60, stat = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.this.identifier],
            [".", "DatabaseConnections", ".", ".", { yAxis = "right" }]
          ]
        }
      },
      {
        type = "log", x = 0, y = 15, width = 24, height = 6
        properties = {
          title = "Top route lỗi (Logs Insights)", region = var.region
          query = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, path, status, duration_ms | filter status >= 500 | stats count(*) as errors by path | sort errors desc | limit 10"
          view  = "table"
        }
      }
    ]
  })
}
