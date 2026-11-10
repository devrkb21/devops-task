variable "aws_region" {
  description = "AWS region to deploy into. Must match the bootstrap region (ECR lives there)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used in resource names and tags. Must match bootstrap."
  type        = string
  default     = "devops-task"
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be \"staging\" or \"production\"."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible."
  type        = string
  default     = "t3.micro"
}

variable "architecture" {
  description = "CPU architecture of the AMI: x86_64 (t3) or arm64 (Graviton, t4g). The image is multi-arch."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "app_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 8080
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the application port. Narrow this for staging."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  description = "How long CloudWatch keeps container logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a retention period CloudWatch Logs supports."
  }
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository created by terraform/bootstrap."
  type        = string
  default     = "devops-task"
}

variable "initial_image_tag" {
  description = "Image tag to start on first boot. Leave empty to let the CI pipeline do the first deploy."
  type        = string
  default     = ""
}
