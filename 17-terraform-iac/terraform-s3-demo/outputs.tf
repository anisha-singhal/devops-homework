output "bucket_name" {
  description = "Generated bucket name, including the random suffix."
  value       = aws_s3_bucket.demo.id
}

output "bucket_arn" {
  description = "ARN - what an IAM policy would reference to grant access."
  value       = aws_s3_bucket.demo.arn
}

output "bucket_region" {
  description = "Region the bucket actually lives in."
  value       = aws_s3_bucket.demo.region
}

output "versioning_status" {
  description = "Enabled or Suspended, read back from the versioning resource rather than from the input variable - so it reports what exists, not what was asked for."
  value       = aws_s3_bucket_versioning.demo.versioning_configuration[0].status
}

output "object_key" {
  description = "Key of the uploaded object."
  value       = aws_s3_object.readme.key
}

output "object_etag" {
  description = "ETag of the uploaded object. For a single-part upload this is the MD5 of the content, so it changes whenever the content does."
  value       = aws_s3_object.readme.etag
}
