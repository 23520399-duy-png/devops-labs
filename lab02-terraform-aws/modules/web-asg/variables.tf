variable "name" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }

variable "container_image" {
  description = "Image đầy đủ, vd 123456789012.dkr.ecr.us-east-1.amazonaws.com/shopmini:lab02"
  type        = string
}

variable "app_version" {
  type    = string
  default = "lab02"
}

variable "app_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  type    = string
  default = "/readyz"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
  validation {
    condition     = can(regex("^t3\\.(nano|micro|small|medium|large)$", var.instance_type))
    error_message = "Learner Lab chỉ hỗ trợ nano → large; lab này dùng họ t3."
  }
}

variable "instance_profile_name" {
  description = "Learner Lab: LabInstanceProfile"
  type        = string
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "cpu_target" {
  type    = number
  default = 50
}

variable "detailed_monitoring" {
  type    = bool
  default = false
}

variable "allowed_cidr" {
  description = "Ai được vào ALB (đặt IP của bạn/32 để an toàn hơn)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "alarm_topic_arn" {
  type    = string
  default = ""
}
