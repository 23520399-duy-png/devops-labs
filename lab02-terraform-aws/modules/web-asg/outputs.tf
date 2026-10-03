output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_arn_suffix" { value = aws_lb.this.arn_suffix }
output "target_group_arn" { value = aws_lb_target_group.app.arn }
output "asg_name" { value = aws_autoscaling_group.app.name }
output "app_sg_id" { value = aws_security_group.app.id }
output "alb_sg_id" { value = aws_security_group.alb.id }
