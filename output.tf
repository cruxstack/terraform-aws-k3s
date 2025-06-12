# ============================================================ infastructure ===

output "kubeconfg_ssm_parameter" {
  value = module.this.enabled ? "${local.ssm_param_namespace}/server/kubeconfig" : ""
}

output "eip_public_ips" {
  value = local.eip_enabled ? aws_eip.this.*.public_ip : []
}

output "oidc_provider_arn" {
  description = "arn of the iam oidc provider"
  value       = local.oidc_provider_arn

}
output "oidc_issuer_url" {
  description = "oidc issuer url configured on the api server"
  value       = local.oidc_issuer_url
}

output "oidc_test_iam_role_arn" {
  value = module.oidc_test.iam_role_arn
}

output "oidc_test_kube_manifest" {
  value = module.oidc_test.kube_manifest
}

output "security_group_id" {
  value = module.security_group.id
}

output "security_group_name" {
  value = module.security_group.name
}

