output "issuer_host" {
  value = local.issuer_host
}

output "issuer_url" {
  value = local.issuer_url
}

output "issuer_thumbprint" {
  value = local.issuer_thumbprint
}

output "key" {
  value = {
    private_key = local.enabled ? one(tls_private_key.this.*.private_key_pem) : ""
    public_key  = local.enabled ? one(tls_private_key.this.*.public_key_pem) : ""
  }
}

output "provider_arn" {
  value = one(aws_iam_openid_connect_provider.this.*.arn)
}

output "bucket_arn" {
  value = local.enabled ? one(aws_s3_bucket.this.*.arn) : ""
}

output "bucket_name" {
  value = local.enabled ? one(aws_s3_bucket.this.*.id) : ""
}
