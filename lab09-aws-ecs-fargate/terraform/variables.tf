variable "region" {
  type    = string
  default = "us-east-1"
}

variable "env" {
  type    = string
  default = "lab09"
}

variable "image_tag" {
  description = "Tag image trong ECR"
  type        = string
  default     = "lab09"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "chaos_error_rate" {
  description = "Giả lập bản phát hành lỗi mà health check KHÔNG phát hiện (Bài 5). 0 = tắt."
  type        = number
  default     = 0
}

variable "fail_readiness" {
  description = "Giả lập bản phát hành hỏng health check → circuit breaker (Bài 4)."
  type        = bool
  default     = false
}
