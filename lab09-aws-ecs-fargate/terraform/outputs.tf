output "alb_url" { value = "http://${aws_lb.this.dns_name}" }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "cluster" { value = aws_ecs_cluster.this.name }
output "service" { value = aws_ecs_service.app.name }
output "log_group" { value = aws_cloudwatch_log_group.app.name }
output "db_identifier" { value = aws_db_instance.this.identifier }
output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.ops.dashboard_name}"
}
