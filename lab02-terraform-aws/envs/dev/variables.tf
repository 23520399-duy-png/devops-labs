variable "region" {
  type    = string
  default = "us-east-1"
  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "Learner Lab chỉ hỗ trợ us-east-1 và us-west-2."
  }
}

variable "env" {
  type    = string
  default = "dev"
}

variable "owner" {
  type    = string
  default = "student"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "image_tag" {
  type    = string
  default = "lab02"
}

variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "enable_flow_logs" {
  type    = bool
  default = false
}
