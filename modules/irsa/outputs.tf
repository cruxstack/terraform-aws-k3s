output "issuer_url" {
  value = local.issuer_url
}

output "issuer_thumbprint" {
  value = local.issuer_thumbprint
}

output "oidc_provider_arn" {
  value = one(aws_iam_openid_connect_provider.this.*.arn)
}

output "bucket_arn" {
  value = local.enabled ? one(aws_s3_bucket.this.*.arn) : ""
}

output "bucket_name" {
  value = local.enabled ? one(aws_s3_bucket.this.*.id) : ""
}
