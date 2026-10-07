# Values for this run. terraform.tfvars is loaded automatically - no -var-file needed.
# Real projects keep secrets out of here and pass them with TF_VAR_* or a secret
# manager, because this file is committed.

aws_region                         = "ap-south-1"
bucket_name                        = "session18-s3-demo"
environment                        = "dev"
enable_versioning                  = true
noncurrent_version_expiration_days = 30
enable_lifecycle_rule              = false
