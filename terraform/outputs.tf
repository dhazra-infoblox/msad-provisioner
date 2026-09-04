output "host_inventory" {
  description = "Role, instance ID, and networking details for all hosts"
  value = {
    for name, vm in aws_instance.nodes :
    name => {
      role        = local.host_roles[name]
      bootstrap   = try(local.host_map[name].bootstrap, false)
      instance_id = vm.id
      private_ip  = vm.private_ip
      public_ip   = vm.public_ip
    }
  }
}

output "server_hosts" {
  description = "Server hosts (AD/DNS/DHCP) and their IPs — the endpoints the agent polls"
  value = {
    for name in local.server_hosts :
    name => local.effective_ip_by_host[name]
  }
}

output "client_hosts" {
  description = "Agent client hosts and their IPs"
  value = {
    for name in local.client_hosts :
    name => local.effective_ip_by_host[name]
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
    promote_dc               = { for k, v in aws_ssm_association.promote_dc : k => v.association_id }
    configure_promoted_dc    = { for k, v in aws_ssm_association.configure_promoted_dc : k => v.association_id }
    credential_setup = merge(
      { for k, v in aws_ssm_association.credential_setup_bootstrap : k => v.association_id },
      { for k, v in aws_ssm_association.credential_setup_members : k => v.association_id },
    )
    agent_setup = { for k, v in aws_ssm_association.agent_setup : k => v.association_id }
  }
}

output "domain_controllers" {
  description = "Hosts that end up as domain controllers: the bootstrap host plus every dc host"
  value = {
    for name in local.domain_controllers :
    name => {
      ip        = local.effective_ip_by_host[name]
      bootstrap = name == local.bootstrap_host
      promoted  = contains(local.promotable_dc_hosts, name)
    }
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

