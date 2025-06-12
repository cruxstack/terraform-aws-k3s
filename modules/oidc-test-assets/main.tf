locals {
  enabled         = module.this.enabled
  aws_region_name = var.aws_region_name

  kube_namespace = module.kube_resource_label.id
  kube_name      = module.kube_resource_label.id

  oidc_issuer_url   = var.oidc_issuer_url
  oidc_issuer_host  = regex("^https://(.*)$", local.oidc_issuer_url)[0]
  oidc_provider_arn = var.oidc_provider_arn

  iam_role_arn = local.enabled ? aws_iam_role.this[0].arn : ""

  kube_manifest = <<-EOF
  apiVersion: v1
  kind: Namespace
  metadata:
    name: ${local.kube_namespace}
  ---
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: ${local.kube_name}
    namespace: ${local.kube_namespace}
    annotations:
      eks.amazonaws.com/role-arn: "${local.iam_role_arn}"
  ---
  apiVersion: v1
  kind: Pod
  metadata:
    name: ${local.kube_name}
    namespace: ${local.kube_namespace}
  spec:
    serviceAccountName: ${local.kube_name}
    automountServiceAccountToken: true
    restartPolicy: Never
    containers:
    - name: check
      image: public.ecr.aws/aws-cli/aws-cli:2.27.32
      command:
      - /bin/sh
      - -c
      - |
        echo testing irsa...
        aws sts get-caller-identity --output json
      env:
      - name: AWS_ROLE_ARN
        value: "${local.iam_role_arn}"
      - name: AWS_WEB_IDENTITY_TOKEN_FILE
        value: /var/run/secrets/kubernetes.io/serviceaccount/token
      - name: AWS_REGION        # nice for logging
        value: ${local.aws_region_name}
  EOF
}

# ================================================================ resources ===

module "kube_resource_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  label_order = ["name", "attributes"]
  context     = module.this.context
}

resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0
  name  = module.this.id

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${local.kube_namespace}:${local.kube_name}"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "this" {
  count = local.enabled ? 1 : 0

  name = module.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:GetCallerIdentity"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  count = local.enabled ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = aws_iam_policy.this[0].arn
}

