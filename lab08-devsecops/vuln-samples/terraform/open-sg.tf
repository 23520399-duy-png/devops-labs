# ❌ IaC sai cấu hình: SSH mở cho cả internet + bucket public
resource "aws_security_group_rule" "ssh_world" {
  type              = "ingress"
  security_group_id = aws_security_group.app.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_s3_bucket" "public_reports" {
  bucket = "shopmini-public-reports-demo"
}

resource "aws_s3_bucket_public_access_block" "public_reports" {
  bucket                  = aws_s3_bucket.public_reports.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
