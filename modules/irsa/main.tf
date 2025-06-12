locals {
  enabled = module.this.enabled

  bucket_name = module.this.id

  issuer_host       = "${local.bucket_name}.s3.${var.aws_region}.amazonaws.com"
  issuer_url        = local.enabled ? "https://${local.issuer_host}" : ""
  issuer_root_certs = one(data.tls_certificate.root_ca.*.certificates)
  issuer_thumbprint = try(local.issuer_root_certs[length(local.issuer_root_certs) - 1].sha1_fingerprint, "")

  provider_arn = local.enabled ? one(aws_iam_openid_connect_provider.this.*.arn) : ""
}

resource "aws_s3_bucket" "this" {
  count = local.enabled ? 1 : 0

  bucket        = local.bucket_name
  force_destroy = true
  tags          = module.this.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  count = local.enabled ? 1 : 0

  bucket                  = aws_s3_bucket.this[0].id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "this" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowReadOidcthis"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject"]
      Resource  = ["${aws_s3_bucket.this[0].arn}/*"]
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

data "tls_certificate" "root_ca" {
  count = local.enabled ? 1 : 0

  url = "https://${local.issuer_host}/"

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_iam_openid_connect_provider" "this" {
  count = local.enabled ? 1 : 0

  url             = local.issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [local.issuer_thumbprint]
  tags            = module.this.tags
}

resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

output "key" {
  value = {
    private_key = tls_private_key.this.private_key_pem
    public_key  = tls_private_key.this.public_key_pem
  }
}
