variable "name" {
  description = "Tiền tố tên tài nguyên"
  type        = string
}

variable "region" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.cidr)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "cidr phải là CIDR hợp lệ, prefix ≤ /16."
  }
}

variable "az_count" {
  type    = number
  default = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Cần 2–3 AZ để đạt high availability."
  }
}

variable "enable_nat" {
  type    = bool
  default = true
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "flow_logs_role_arn" {
  description = "ARN role cho VPC Flow Logs (Learner Lab: LabRole). Để trống = tắt."
  type        = string
  default     = ""
}
