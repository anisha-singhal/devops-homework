terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Pointed at LocalStack rather than a real AWS account. Same provider, same
# resource schema, same API calls - answered by a container on localhost:4566
# instead of s3.ap-south-1.amazonaws.com. Nothing is billed, and the whole
# init -> plan -> apply -> show -> output -> destroy cycle runs for real.
#
# To target real AWS, delete the four skip_* lines and the endpoints block,
# then export AWS credentials. Nothing else in this project changes.
provider "aws" {
  region = var.aws_region

  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  # LocalStack serves every bucket from one endpoint, so addressing has to be
  # path-style (localhost:4566/bucket) rather than virtual-hosted
  # (bucket.localhost:4566), which would need per-bucket DNS.
  s3_use_path_style = true

  endpoints {
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}
