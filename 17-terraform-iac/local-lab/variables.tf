variable "environment" {
  description = "Environment name, used in resource names and tags"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "replica_count" {
  description = "How many nginx containers to run"
  type        = number
  default     = 2

  validation {
    condition     = var.replica_count >= 1 && var.replica_count <= 5
    error_message = "replica_count must be between 1 and 5."
  }
}

variable "nginx_version" {
  description = "Tag of the nginx image to run"
  type        = string
  default     = "1.27-alpine"
}

variable "base_port" {
  description = "First host port; replicas increment from here"
  type        = number
  default     = 8101
}
