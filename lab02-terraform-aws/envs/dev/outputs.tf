output "alb_url" { value = "http://${module.web.alb_dns_name}" }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "asg_name" { value = module.web.asg_name }
output "vpc_id" { value = module.network.vpc_id }
output "private_subnet_ids" { value = module.network.private_subnet_ids }
output "app_sg_id" { value = module.web.app_sg_id }
output "alb_sg_id" { value = module.web.alb_sg_id }
output "alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
