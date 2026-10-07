# Bucket names live in a single global namespace shared by every AWS account,
# so "session18-s3-demo" is almost certainly taken. A random suffix makes the
# name unique without hardcoding one.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  bucket = "${var.bucket_name}-${random_string.suffix.result}"

  common_tags = {
    Project     = "session18-terraform-iac"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# The bucket itself. Note how little this resource does on its own: in provider
# v4+ every behaviour (versioning, encryption, lifecycle, public access) is a
# SEPARATE resource. Older tutorials show them as inline blocks; those were
# removed, and copying them produces "Unsupported block type" errors.
resource "aws_s3_bucket" "demo" {
  bucket = local.bucket
  tags   = merge(local.common_tags, { Name = local.bucket })
}

# Versioning: an overwrite becomes a new version rather than destroying the old
# object, and a delete becomes a delete marker. This is the difference between
# "I can undo that" and "that data is gone".
resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# Encryption at rest. SSE-S3 (AES256) is free and now applied by default to new
# buckets, but declaring it means the state records it and drift is detected if
# someone turns it off.
resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all four public-access routes. This is the single setting behind most
# "company leaks data in open S3 bucket" headlines - it overrides any ACL or
# bucket policy that would otherwise make an object public.
resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning without expiry grows without bound, and every retained version is
# billed. This expires superseded versions and cleans up uploads that were
# started but never completed - those are invisible in the console and still cost money.
resource "aws_s3_bucket_lifecycle_configuration" "demo" {
  count = var.enable_lifecycle_rule ? 1 : 0

  bucket = aws_s3_bucket.demo.id

  # The lifecycle rule must not be written before versioning exists, or the API
  # rejects a noncurrent-version rule on an unversioned bucket. Terraform cannot
  # infer that from the arguments, so the dependency is declared.
  depends_on = [aws_s3_bucket_versioning.demo]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# An object, so the bucket is not empty and versioning can be demonstrated.
resource "aws_s3_object" "readme" {
  bucket       = aws_s3_bucket.demo.id
  key          = "hello.txt"
  content      = "Provisioned by Terraform for session 18.\nenvironment: ${var.environment}\n"
  content_type = "text/plain"

  tags = local.common_tags
}
