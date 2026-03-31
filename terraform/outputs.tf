output "host_inventory" {
  description = "Role, instance ID, and networking details for all hosts"
  value = {
    for name, vm in aws_instance.nodes :
    name => {
      role        = local.host_map[name].role
      bootstrap   = try(local.host_map[name].bootstrap, false)
      instance_id = vm.id
      private_ip  = vm.private_ip
      public_ip   = vm.public_ip
    }
  }
}

output "dhcp_servers" {
  description = "DHCP server endpoints configured for agent polling"
  value = {
    for name in local.dhcp_hosts :
    name => local.assigned_ips_by_host[name]
  }
}

output "agent_servers" {
  description = "Agent/client hosts and their IPs"
  value = {
    for name in local.agent_hosts :
    name => local.assigned_ips_by_host[name]
  }
}

output "phase_association_ids" {
  description = "SSM association IDs for observability"
  value = {
    rename_computer          = { for k, v in aws_ssm_association.rename_computer : k => v.association_id }
    configure_networking     = { for k, v in aws_ssm_association.configure_networking : k => v.association_id }
    install_windows_features = { for k, v in aws_ssm_association.install_windows_features : k => v.association_id }
    bootstrap_domain         = aws_ssm_association.bootstrap_domain.association_id
    configure_dns_forwarder  = aws_ssm_association.configure_dns_forwarder.association_id
    join_domain              = { for k, v in aws_ssm_association.join_domain : k => v.association_id }
    credential_setup         = aws_ssm_association.credential_setup.association_id
    agent_setup              = { for k, v in aws_ssm_association.agent_setup : k => v.association_id }
  }
}

output "bootstrap_host" {
  description = "Designated forest bootstrap host"
  value       = local.bootstrap_host
}

output "ssm_logs_s3_path" {
  description = "S3 path for SSM command output logs"
  value       = local.ssm_logs_enabled ? "s3://${local.ssm_log_bucket}/${local.ssm_log_prefix}/" : "disabled"
}

output "rdp_credentials_vault_paths" {
  description = "Vault KV paths where per-host RDP credentials are stored"
  value = {
    for host, secret in vault_kv_secret_v2.rdp_credentials :
    host => "${try(local.vault_cfg.mount, "secret")}/data/${secret.name}"
  }
}
