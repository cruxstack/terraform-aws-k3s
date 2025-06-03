# ============================================================ infastructure ===

output "k3s_kubeconfg_ssm_parameter" {
  value = module.this.enabled ? "${local.ssm_param_namespace}/server/kubeconfig" : ""
}
output "security_group_id" {
  value = module.security_group.id
}

output "security_group_name" {
  value = module.security_group.name
}

