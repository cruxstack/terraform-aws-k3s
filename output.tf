# ============================================================ infastructure ===

output "k3s_kubeconfg_ssm_parameter" {
  value = module.this.enabled ? "${local.ssm_param_namespace}/server/kubeconfig" : ""
}

output "eip_public_ips" {
  value = local.eip_enabled ? aws_eip.this.*.public_ip : []
}

output "irsa_oidc_provider_arn" {
  description = "arn of the iam oidc provider"
  value       = local.irsa_oidc_provider_arn

}
output "irsa_issuer_url" {
  description = "oidc issuer url configured on the api server"
  value       = local.irsa_issuer_url
}

output "irsa_smoke_role_arn" {
  value = module.irsa_smoke_test.smoke_role_arn
}

output "irsa_smoke_kube_manifest" {
  value = module.irsa_smoke_test.smoke_kube_manifest
}

output "security_group_id" {
  value = module.security_group.id
}

output "security_group_name" {
  value = module.security_group.name
}

