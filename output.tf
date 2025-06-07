# ============================================================ infastructure ===

output "k3s_kubeconfg_ssm_parameter" {
  value = module.this.enabled ? "${local.ssm_param_namespace}/server/kubeconfig" : ""
}

output "eip_public_ips" {
  value = local.eip_enabled ? aws_eip.this.*.public_ip : []
}

output "security_group_id" {
  value = module.security_group.id
}

output "security_group_name" {
  value = module.security_group.name
}

