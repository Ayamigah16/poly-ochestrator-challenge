variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Deployment environment (development | staging | production)"
  type        = string
  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging, or production"
  }
}

variable "image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "enabled_adapters" {
  description = "Comma-separated list of enabled AI adapters"
  type        = string
  default     = "mistral"
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MB"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Desired number of ECS tasks"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks for auto scaling"
  type        = number
  default     = 10
}

variable "postgres_image" {
  description = "PostgreSQL container image"
  type        = string
  default     = "postgres:15-alpine"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "app_secret_key" {
  description = "Django/FastAPI secret key"
  type        = string
  sensitive   = true
}

variable "mistral_api_key" {
  description = "Mistral AI API key"
  type        = string
  sensitive   = true
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener. Request a free cert at https://console.aws.amazon.com/acm/"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:acm:", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be a valid ACM ARN (arn:aws:acm:...)."
  }
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket name for ALB access logs (leave empty to disable logging)"
  type        = string
  default     = ""
}
