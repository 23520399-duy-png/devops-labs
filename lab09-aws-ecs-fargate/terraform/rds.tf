resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = module.network.private_subnet_ids
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name}-pg"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"

  db_name                     = "shop"
  username                    = "shop"
  manage_master_user_password = true # RDS tạo + xoay vòng mật khẩu trong Secrets Manager

  allocated_storage     = 20
  max_allocated_storage = 50 # Storage Auto Scaling
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false # Learner Lab không hỗ trợ Multi-AZ (production: true)

  backup_retention_period      = 1
  backup_window                = "17:00-18:00" # 00:00–01:00 giờ VN
  maintenance_window           = "sun:18:30-sun:19:30"
  auto_minor_version_upgrade   = true
  deletion_protection          = false # môi trường học
  skip_final_snapshot          = true  # môi trường học – production: false + final_snapshot_identifier
  copy_tags_to_snapshot        = true
  monitoring_interval          = 0 # Enhanced Monitoring không được hỗ trợ trên Learner Lab
  performance_insights_enabled = false

  enabled_cloudwatch_logs_exports = ["postgresql"]
}
