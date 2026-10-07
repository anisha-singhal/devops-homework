variable "aws_region" {
  description = "Region the bucket is created in. S3 bucket names are global, but the bucket itself lives in one region."
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "Base name for the bucket. A random suffix is appended, because bucket names share one global namespace across every AWS account on earth."
  type        = string
  default     = "session18-s3-demo"

  validation {
    # S3 bucket naming rules: 3-63 chars, lowercase letters, digits, hyphens,
    # must start and end alphanumeric. Terraform catches this at plan time
    # rather than letting the API reject it halfway through an apply.
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters, lowercase alphanumeric or hyphen, and start and end alphanumeric."
  }
}

variable "environment" {
  description = "Environment tag applied to every resource."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "enable_versioning" {
  description = "Keep every version of an object instead of overwriting in place."
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "How long superseded object versions are kept before deletion. Versioning without expiry grows forever, and you pay for every version."
  type        = number
  default     = 30
}

variable "enable_lifecycle_rule" {
  description = <<-DESC
    Whether to create the lifecycle configuration.

    Defaults to false because this project runs against LocalStack, whose S3
    implementation cannot satisfy the AWS provider's post-write consistency
    check for this one resource - see the README section "The lifecycle rule
    that would not converge". Set to true when pointing at real AWS.
  DESC
  type        = bool
  default     = false
}
