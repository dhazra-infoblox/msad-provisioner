terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

locals {
  config      = yamldecode(file(var.config_file))
  aws_config  = local.config.aws
  domain      = local.config.domain
  network     = local.config.network
  credentials = local.config.credentials
  vault_cfg   = try(local.config.vault, {})
  hosts       = local.config.hosts

  vault_enabled    = try(local.vault_cfg.enabled, false)
  rdp_key_path     = trimspace(var.key_pair_pem_path)
  rdp_store_enabled = try(local.vault_cfg.store_rdp_credentials, false) && local.rdp_key_path != ""
  rdp_vault_prefix  = try(local.vault_cfg.rdp_credentials_path_prefix, "msad/rdp")

  allowed_roles      = ["dhcp_server", "agent_client", "domain_controller"]
  host_map           = { for h in local.hosts : h.name => h }
  ordered_host_names = sort(keys(local.host_map))

  bootstrap_hosts = [for h in local.hosts : h.name if try(h.bootstrap, false)]
  bootstrap_host  = length(local.bootstrap_hosts) == 1 ? local.bootstrap_hosts[0] : ""

  dhcp_hosts  = [for h in local.hosts : h.name if h.role == "dhcp_server"]
  agent_hosts = [for h in local.hosts : h.name if h.role == "agent_client"]

  subnet_prefix_len = tonumber(split("/", data.aws_subnet.selected.cidr_block)[1])
  host_space        = pow(2, 32 - local.subnet_prefix_len)
  ip_start_offset   = try(local.network.ip_start_offset, 10)

  candidate_ips = [
    for i in range(local.ip_start_offset, local.host_space - 2) : cidrhost(data.aws_subnet.selected.cidr_block, i)
  ]

  used_ips = distinct(flatten([
    for eni in data.aws_network_interface.subnet_eni : eni.private_ips
  ]))

  available_ips = [for ip in local.candidate_ips : ip if !contains(local.used_ips, ip)]

  assigned_ips_by_host = {
    for idx, name in local.ordered_host_names : name => local.available_ips[idx]
  }

  gateway_ip  = try(local.network.gateway, cidrhost(data.aws_subnet.selected.cidr_block, 1))
  primary_dns = try(local.assigned_ips_by_host[local.bootstrap_host], cidrhost(data.aws_subnet.selected.cidr_block, 2))
  dns_servers = length(try(local.network.dns_servers, [])) > 0 ? local.network.dns_servers : [local.primary_dns]
  vpc_dns     = cidrhost(data.aws_vpc.selected.cidr_block, 2)

  common_tags = merge(var.default_tags, try(local.aws_config.tags, {}), {
    environment = try(local.aws_config.environment, "dev")
  })

  domain_admin_password = var.admin_password
  safe_mode_password    = var.safe_mode_password
  service_user_password = var.service_password

  use_existing_instance_profile = try(local.aws_config.instance_profile_name, "") != ""
  ssm_instance_profile_name = local.use_existing_instance_profile ? local.aws_config.instance_profile_name : aws_iam_instance_profile.ssm_instance_profile[0].name
}

provider "aws" {
  region  = local.aws_config.region
  profile = local.aws_config.profile
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  id = local.aws_config.vpc_id
}

data "aws_subnet" "selected" {
  id = local.aws_config.subnet_id
}

data "aws_network_interfaces" "subnet" {
  filter {
    name   = "subnet-id"
    values = [local.aws_config.subnet_id]
  }
}

data "aws_network_interface" "subnet_eni" {
  for_each = toset(data.aws_network_interfaces.subnet.ids)
  id       = each.key
}

check "has_hosts" {
  assert {
    condition     = length(local.hosts) > 0
    error_message = "config.hosts must include at least one host."
  }
}

check "valid_host_roles" {
  assert {
    condition     = alltrue([for h in local.hosts : contains(local.allowed_roles, h.role)])
    error_message = "All host roles must be one of: dhcp_server, agent_client, domain_controller."
  }
}

check "single_bootstrap" {
  assert {
    condition     = length(local.bootstrap_hosts) == 1
    error_message = "Exactly one host must set bootstrap: true for forest creation."
  }
}

check "ip_capacity" {
  assert {
    condition     = length(local.available_ips) >= length(local.ordered_host_names)
    error_message = "Not enough available IP addresses in selected subnet for declared hosts."
  }
}

check "rdp_store_requires_vault" {
  assert {
    condition     = !local.rdp_store_enabled || local.vault_enabled
    error_message = "vault.store_rdp_credentials requires vault.enabled=true."
  }
}

check "rdp_key_path_set" {
  assert {
    condition     = !local.rdp_store_enabled || trimspace(local.rdp_key_path) != ""
    error_message = "Set aws.key_pair_private_key_path to decrypt Windows password_data before storing in Vault."
  }
}

check "rdp_key_file_exists" {
  assert {
    condition     = !local.rdp_store_enabled || fileexists(local.rdp_key_path)
    error_message = "aws.key_pair_private_key_path does not exist or is not readable."
  }
}

check "rdp_vault_prefix_set" {
  assert {
    condition     = !local.rdp_store_enabled || trimspace(local.rdp_vault_prefix) != ""
    error_message = "Set vault.rdp_credentials_path_prefix when storing RDP credentials in Vault."
  }
}

# ---------------------------------------------------------------------------
# S3 path for SSM command output logs (existing bucket)
# ---------------------------------------------------------------------------

locals {
  ssm_log_bucket = try(local.config.ssm_logs.s3_bucket, "")
  ssm_log_prefix = try(local.config.ssm_logs.s3_prefix, "ssm-logs")
  ssm_logs_enabled = local.ssm_log_bucket != ""
}

resource "aws_iam_role" "ssm_instance_role" {
  count = local.use_existing_instance_profile ? 0 : 1

  name = "${try(local.aws_config.name_prefix, "msad")}-ssm-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_managed_core" {
  count      = local.use_existing_instance_profile ? 0 : 1
  role       = aws_iam_role.ssm_instance_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_instance_profile" {
  count = local.use_existing_instance_profile ? 0 : 1

  name = "${try(local.aws_config.name_prefix, "msad")}-instance-profile"
  role = aws_iam_role.ssm_instance_role[0].name
}

data "aws_iam_instance_profile" "existing" {
  count = local.use_existing_instance_profile ? 1 : 0
  name  = local.aws_config.instance_profile_name
}

locals {
  ssm_role_name = local.use_existing_instance_profile ? data.aws_iam_instance_profile.existing[0].role_name : aws_iam_role.ssm_instance_role[0].name
}

resource "aws_iam_role_policy" "ssm_s3_logs" {
  count = local.ssm_logs_enabled && !local.use_existing_instance_profile ? 1 : 0

  name = "${try(local.aws_config.name_prefix, "msad")}-ssm-s3-logs"
  role = local.ssm_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetBucketLocation"
      ]
      Resource = [
        "arn:aws:s3:::${local.ssm_log_bucket}",
        "arn:aws:s3:::${local.ssm_log_bucket}/${local.ssm_log_prefix}/*"
      ]
    }]
  })
}

resource "aws_instance" "nodes" {
  for_each = local.host_map

  ami                    = lookup(each.value, "ami_id", local.aws_config.default_ami_id)
  instance_type          = lookup(each.value, "instance_type", local.aws_config.default_instance_type)
  subnet_id              = local.aws_config.subnet_id
  vpc_security_group_ids = local.aws_config.security_group_ids
  iam_instance_profile   = local.ssm_instance_profile_name
  key_name               = try(local.aws_config.key_name, null)

  private_ip              = local.assigned_ips_by_host[each.key]
  associate_public_ip_address = try(local.aws_config.associate_public_ip, false)
  get_password_data       = true

  root_block_device {
    volume_size = lookup(each.value, "disk_gb", 60)
    volume_type = "gp3"
    encrypted   = try(local.aws_config.root_volume_encrypted, true)
    kms_key_id  = try(local.aws_config.root_volume_kms_key_id, null)
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = try(local.aws_config.imds_http_tokens, "optional")
    instance_metadata_tags      = try(local.aws_config.imds_instance_metadata_tags, "disabled")
    http_put_response_hop_limit = 1
  }

  tags = merge(local.common_tags, {
    Name      = each.key
    HostRole  = each.value.role
    Bootstrap = tostring(try(each.value.bootstrap, false))
  })
}

resource "aws_ssm_document" "configure_networking" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-configure-networking"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Disable DHCP and set static networking"
    parameters = {
      StaticIp = { type = "String" }
      PrefixLength = { type = "String" }
      Gateway  = { type = "String" }
      DnsList  = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "ConfigureStaticIp"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "# Wait for CIM/WMI to be ready after reboot",
          "$timeout = 180; $elapsed = 0; $adapter = $null",
          "while ($elapsed -lt $timeout) { try { $adapter = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1; if ($adapter) { break } } catch { Write-Host \"Waiting for CIM/NetAdapter... ($elapsed s)\" }; Start-Sleep -Seconds 10; $elapsed += 10 }",
          "if (-not $adapter) { throw 'No active network adapter found after waiting' }",
          "$ifIndex = $adapter.IfIndex",
          "Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue",
          "$existingTarget = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '{{ StaticIp }}' }",
          "if (-not $existingTarget) { New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress '{{ StaticIp }}' -PrefixLength {{ PrefixLength }} -DefaultGateway '{{ Gateway }}' -AddressFamily IPv4 -ErrorAction Stop | Out-Null; Write-Host \"Set static IP {{ StaticIp }}/{{ PrefixLength }} gw {{ Gateway }}\" } else { Write-Host 'Static IP already configured' }",
          "$oldDhcp = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '{{ StaticIp }}' -and $_.PrefixOrigin -eq 'Dhcp' }",
          "if ($oldDhcp) { $oldDhcp | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }",
          "$dns = '{{ DnsList }}'.Split(',')",
          "Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dns",
          "if (-not (Get-NetRoute -DestinationPrefix '169.254.169.254/32' -ErrorAction SilentlyContinue)) { New-NetRoute -DestinationPrefix '169.254.169.254/32' -InterfaceIndex $ifIndex -NextHop '{{ Gateway }}' -RouteMetric 10 -ErrorAction SilentlyContinue }",
          "Set-NetConnectionProfile -InterfaceIndex $ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "configure_networking" {
  for_each = aws_instance.nodes

  name = aws_ssm_document.configure_networking.name

  targets {
    key    = "InstanceIds"
    values = [each.value.id]
  }

  parameters = {
    StaticIp     = local.assigned_ips_by_host[each.key]
    PrefixLength = tostring(local.subnet_prefix_len)
    Gateway      = local.gateway_ip
    DnsList      = join(",", distinct(concat(local.dns_servers, [local.vpc_dns])))
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/configure-networking/${each.key}"
    }
  }

  # Rename (with reboot) runs first while DHCP is active; then we set static
  # networking so no subsequent reboot can reset DNS settings.
  wait_for_success_timeout_seconds = 600

  depends_on = [time_sleep.wait_for_rename_reboot]
}

resource "time_sleep" "wait_for_rename_reboot" {
  create_duration = "90s"

  depends_on = [aws_ssm_association.rename_computer]
}

# ---------------------------------------------------------------------------
# Phase: Rename computer to match host config name
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "rename_computer" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-rename-computer"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Rename computer to configured hostname"
    parameters = {
      Hostname = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "RenameComputer"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "$current = $env:COMPUTERNAME",
          "if ($current -ne '{{ Hostname }}') { Rename-Computer -NewName '{{ Hostname }}' -Force -Restart } else { Write-Host 'Hostname already set' }"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "rename_computer" {
  for_each = aws_instance.nodes

  name = aws_ssm_document.rename_computer.name

  targets {
    key    = "InstanceIds"
    values = [each.value.id]
  }

  parameters = {
    Hostname = upper(each.key)
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/rename-computer/${each.key}"
    }
  }

  # Runs first on DHCP (SSM/DNS still work). Reboot happens here.
  wait_for_success_timeout_seconds = 300
}

resource "aws_ssm_document" "install_windows_features" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-install-features"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install role-specific Windows features"
    parameters = {
      HostRole = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "InstallFeatures"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "# Wait for CBS (component store) to be ready after a reboot",
          "$timeout = 600; $elapsed = 0",
          "while ($elapsed -lt $timeout) { $cbs = Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue; if ($cbs) { if ($cbs.Status -ne 'Running') { Start-Service TrustedInstaller -ErrorAction SilentlyContinue }; if ($cbs.Status -eq 'Running') { break } }; Start-Sleep -Seconds 10; $elapsed += 10; Write-Host \"Waiting for TrustedInstaller... ($elapsed s)\" }",
          "if ($elapsed -ge $timeout) { throw 'TrustedInstaller did not start within timeout' }",
          "$role = '{{ HostRole }}'",
          "if ($role -eq 'dhcp_server' -or $role -eq 'domain_controller') { Install-WindowsFeature -Name DHCP,DNS,RSAT-DHCP,RSAT-DNS-Server,RSAT-AD-Tools -IncludeManagementTools }",
          "if ($role -eq 'agent_client') { Install-WindowsFeature -Name RSAT-AD-PowerShell,RSAT-AD-Tools,RSAT-DNS-Server,RSAT-DHCP -IncludeManagementTools }",
          "if ($role -eq 'domain_controller') { Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools }"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "install_windows_features" {
  for_each = aws_instance.nodes

  name = aws_ssm_document.install_windows_features.name

  targets {
    key    = "InstanceIds"
    values = [each.value.id]
  }

  parameters = {
    HostRole = local.host_map[each.key].role
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/install-features/${each.key}"
    }
  }

  wait_for_success_timeout_seconds = 1800

  depends_on = [aws_ssm_association.configure_networking]
}

resource "aws_ssm_document" "bootstrap_domain" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-bootstrap-domain"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Create forest/domain on bootstrap host"
    parameters = {
      DomainFqdn     = { type = "String" }
      DomainNetbios  = { type = "String" }
      SafeModePass   = { type = "String" }
      AdminPass      = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "BootstrapForest"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "# Idempotency: skip if forest already exists",
          "try { $forest = Get-ADForest -ErrorAction Stop; Write-Host \"Forest '$($forest.Name)' already exists, skipping\"; exit 0 } catch { Write-Host 'No existing forest, proceeding with bootstrap' }",
          "# Set local Administrator password to the known domain admin password before promotion",
          "net user Administrator '{{ AdminPass }}'",
          "Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools",
          "$pwd = ConvertTo-SecureString '{{ SafeModePass }}' -AsPlainText -Force",
          "Install-ADDSForest -DomainName '{{ DomainFqdn }}' -DomainNetbiosName '{{ DomainNetbios }}' -SafeModeAdministratorPassword $pwd -Force:$true -NoRebootOnCompletion:$false"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "bootstrap_domain" {
  name = aws_ssm_document.bootstrap_domain.name

  targets {
    key    = "InstanceIds"
    values = [aws_instance.nodes[local.bootstrap_host].id]
  }

  parameters = {
    DomainFqdn    = local.domain.fqdn
    DomainNetbios = local.domain.netbios
    SafeModePass  = local.safe_mode_password
    AdminPass     = local.domain_admin_password
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/bootstrap-domain/${local.bootstrap_host}"
    }
  }

  # Forest creation triggers a reboot; allow enough time for reboot + AD startup.
  wait_for_success_timeout_seconds = 1200

  depends_on = [aws_ssm_association.install_windows_features]
}

# ---------------------------------------------------------------------------
# Phase: Configure DNS forwarder on bootstrap DC so AWS endpoints resolve
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "configure_dns_forwarder" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-dns-forwarder"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Add VPC DNS as forwarder on AD DNS server"
    parameters = {
      VpcDns = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "AddDnsForwarder"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "$existing = Get-DnsServerForwarder -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress | ForEach-Object { $_.IPAddressToString }",
          "if ('{{ VpcDns }}' -notin $existing) { Add-DnsServerForwarder -IPAddress '{{ VpcDns }}' -PassThru }"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "configure_dns_forwarder" {
  name = aws_ssm_document.configure_dns_forwarder.name

  targets {
    key    = "InstanceIds"
    values = [aws_instance.nodes[local.bootstrap_host].id]
  }

  parameters = {
    VpcDns = local.vpc_dns
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/dns-forwarder/${local.bootstrap_host}"
    }
  }

  wait_for_success_timeout_seconds = 120

  depends_on = [time_sleep.wait_for_bootstrap_reboot]
}

resource "time_sleep" "wait_for_bootstrap_reboot" {
  # DC needs time after forest promotion reboot to start AD DS, register SRV
  # records with DNS, and initialise Netlogon/KDC services.
  create_duration = "180s"

  depends_on = [aws_ssm_association.bootstrap_domain]
}

resource "aws_ssm_document" "join_domain" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-join-domain"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Join host to Active Directory domain"
    parameters = {
      DomainFqdn = { type = "String" }
      AdminUser  = { type = "String" }
      AdminPass  = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "JoinDomain"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "",
          "# Idempotency: skip if already domain-joined",
          "$cs = Get-WmiObject Win32_ComputerSystem",
          "if ($cs.PartOfDomain -and $cs.Domain -eq '{{ DomainFqdn }}') {",
          "    Write-Host 'Already joined to {{ DomainFqdn }}, skipping'",
          "    exit 0",
          "}",
          "",
          "# Clear negative DNS cache from any earlier failed lookups",
          "Clear-DnsClientCache -ErrorAction SilentlyContinue",
          "",
          "# Wait for DC SRV records (Add-Computer uses DsGetDcName which requires these)",
          "$srvName = '_ldap._tcp.dc._msdcs.{{ DomainFqdn }}'",
          "$timeout = 600; $elapsed = 0",
          "while ($elapsed -lt $timeout) {",
          "    try {",
          "        $srv = Resolve-DnsName $srvName -Type SRV -ErrorAction Stop",
          "        Write-Host \"DC SRV record found: $($srv[0].NameTarget)\"",
          "        break",
          "    } catch {",
          "        Write-Host \"Waiting for DC SRV record ($srvName)... ($elapsed s)\"",
          "        Start-Sleep 15",
          "        $elapsed += 15",
          "        Clear-DnsClientCache -ErrorAction SilentlyContinue",
          "    }",
          "}",
          "if ($elapsed -ge $timeout) { throw \"DC SRV record $srvName not found after $${timeout}s\" }",
          "",
          "# Build credential",
          "$sec = ConvertTo-SecureString '{{ AdminPass }}' -AsPlainText -Force",
          "$cred = New-Object System.Management.Automation.PSCredential('{{ AdminUser }}', $sec)",
          "",
          "# Attempt domain join with retries (DC may need extra time for Netlogon/KDC)",
          "$maxRetries = 8; $attempt = 0",
          "while ($attempt -lt $maxRetries) {",
          "    $attempt++",
          "    try {",
          "        Write-Host \"Domain join attempt $attempt of $maxRetries\"",
          "        Add-Computer -DomainName '{{ DomainFqdn }}' -Credential $cred -Force -Restart",
          "        Write-Host 'Domain join succeeded, restarting'",
          "        exit 0",
          "    } catch {",
          "        Write-Host \"Attempt $attempt failed: $_\"",
          "        if ($attempt -ge $maxRetries) { throw \"Domain join failed after $maxRetries attempts: $_\" }",
          "        Write-Host 'Sleeping 30s before retry...'",
          "        Start-Sleep 30",
          "        Clear-DnsClientCache -ErrorAction SilentlyContinue",
          "    }",
          "}"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "join_domain" {
  for_each = {
    for name, vm in aws_instance.nodes : name => vm if name != local.bootstrap_host
  }

  name = aws_ssm_document.join_domain.name

  targets {
    key    = "InstanceIds"
    values = [each.value.id]
  }

  parameters = {
    DomainFqdn = local.domain.fqdn
    AdminUser  = local.domain.admin_user
    AdminPass  = local.domain_admin_password
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/join-domain/${each.key}"
    }
  }

  # DNS wait (600s) + LDAP wait (300s) + join retries (150s) + reboot
  wait_for_success_timeout_seconds = 1200

  depends_on = [aws_ssm_association.configure_dns_forwarder]
}

resource "aws_ssm_document" "credential_setup" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-credential-setup"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Create service user and required remoting permissions"
    parameters = {
      Username     = { type = "String" }
      Password     = { type = "String" }
      DomainFqdn   = { type = "String" }
      TrustedHosts = { type = "String" }
      IsBootstrap  = { type = "String", default = "false" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "ConfigureCredentials"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "$username = '{{ Username }}'",
          "$upn = \"$username@{{ DomainFqdn }}\"",
          "$password = ConvertTo-SecureString '{{ Password }}' -AsPlainText -Force",
          "$isBootstrap = '{{ IsBootstrap }}' -eq 'true'",
          "",
          "# AD user creation — only on the DC (bootstrap host)",
          "if ($isBootstrap) {",
          "  # Complete DHCP post-install: create security groups and authorize in AD",
          "  netsh dhcp add securitygroups",
          "  Restart-Service dhcpserver -Force",
          "  $fqdn = \"$env:COMPUTERNAME.{{ DomainFqdn }}\"",
          "  $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress",
          "  if (-not (Get-DhcpServerInDC | Where-Object { $_.DnsName -eq $fqdn })) { Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ip; Write-Host \"DHCP server $fqdn authorized in AD\" } else { Write-Host \"DHCP server $fqdn already authorized\" }",
          "  Write-Host 'DHCP security groups created (DHCP Administrators, DHCP Users)'",
          "  if (-not (Get-ADUser -Filter \"UserPrincipalName -eq '$upn'\" -ErrorAction SilentlyContinue)) { New-ADUser -Name $username -SamAccountName $username -UserPrincipalName $upn -AccountPassword $password -Enabled $true; Write-Host \"Created user $upn\" } else { Write-Host \"User $upn already exists\" }",
          "  foreach ($grp in @('Domain Users','Remote Management Users','DNSAdmins','DHCP Administrators')) { try { Add-ADGroupMember -Identity $grp -Members $username -ErrorAction Stop; Write-Host \"Added to $grp\" } catch { if ($_.Exception.Message -match 'already a member') { Write-Host \"Already in $grp\" } elseif ($_.Exception.Message -match 'Cannot find an object with identity') { Write-Host \"Group $grp not found, skipping\" } else { throw } } }",
          "} else { Write-Host \"Non-DC host, skipping AD user creation\" }",
          "",
          "# CredSSP, firewall, TrustedHosts — all DHCP servers",
          "Enable-WSManCredSSP -Role Server -Force",
          "Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress Any",
          "Set-Item WSMan:\\localhost\\Client\\TrustedHosts -Value '{{ TrustedHosts }}' -Force",
          "# Grant WMI permissions (Remote Enable + Execute Methods) on DNS and DHCP namespaces",
          "function Set-WmiNamespaceSecurity($ns, $account) {",
          "  Write-Host \"[WMI] Setting permissions: namespace=$ns account=$account\"",
          "  $sec = ([wmiclass]\"\\\\localhost\\$($ns):__SystemSecurity\")",
          "  $sd = $sec.GetSecurityDescriptor().Descriptor",
          "  for ($i = 1; $i -le 12; $i++) { try { $sid = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]); Write-Host \"[WMI] Resolved $account -> SID=$($sid.Value)\"; break } catch { if ($i -eq 12) { throw } else { Write-Host \"[WMI] Retry $i/12: $account not resolvable yet - $($_.Exception.Message)\"; Start-Sleep -Seconds 10 } } }",
          "  $ace = ([wmiclass]'Win32_ACE').CreateInstance()",
          "  $trustee = ([wmiclass]'Win32_Trustee').CreateInstance()",
          "  $trustee.SIDString = $sid.Value",
          "  $ace.AccessMask = 0x23",
          "  $ace.AceType = 0",
          "  $ace.AceFlags = 0",
          "  $ace.Trustee = $trustee",
          "  $sd.DACL += $ace",
          "  $sec.SetSecurityDescriptor($sd) | Out-Null",
          "  $newSd = $sec.GetSecurityDescriptor().Descriptor",
          "  Write-Host \"[WMI] DACL for $ns now has $($newSd.DACL.Count) entries:\"",
          "  foreach ($a in $newSd.DACL) { $name = try { (New-Object System.Security.Principal.SecurityIdentifier($a.Trustee.SIDString)).Translate([System.Security.Principal.NTAccount]).Value } catch { $a.Trustee.SIDString }; Write-Host \"  - $name (AccessMask=0x$($a.AccessMask.ToString('X')))\" }",
          "}",
          "$domainPrefix = '{{ DomainFqdn }}'.Split('.')[0].ToUpper()",
          "Write-Host \"[WMI] domainPrefix=$domainPrefix username=$username hostname=$(hostname)\"",
          "foreach ($ns in @('Root/Microsoft/Windows/DNS')) { Set-WmiNamespaceSecurity $ns \"$domainPrefix\\$username\"; Set-WmiNamespaceSecurity $ns \"$domainPrefix\\DNSAdmins\"; Write-Host \"WMI: $username + DNSAdmins granted on $ns\" }",
          "try { foreach ($acct in @(\"$domainPrefix\\$username\", \"$domainPrefix\\DNSAdmins\")) { Set-WmiNamespaceSecurity 'Root/Microsoft/Windows/DHCP' $acct }; Write-Host \"WMI: $username + DNSAdmins granted on Root/Microsoft/Windows/DHCP\" } catch { Write-Host \"DHCP WMI namespace not available, skipping: $($_.Exception.Message)\" }",
          "if ($isBootstrap) {",
          "  $u = Get-ADUser -Identity $username -Properties MemberOf,UserPrincipalName,Enabled,WhenCreated",
          "  Write-Host '--- User Details ---'",
          "  Write-Host \"  SAM Account : $($u.SamAccountName)\"",
          "  Write-Host \"  UPN         : $($u.UserPrincipalName)\"",
          "  Write-Host \"  Domain Logon: $${env:USERDOMAIN}\\$($u.SamAccountName)\"",
          "  Write-Host \"  Enabled     : $($u.Enabled)\"",
          "  Write-Host \"  Created     : $($u.WhenCreated)\"",
          "  Write-Host \"  Groups      : $(($u.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }) -join ', ')\"",
          "}",
          "Write-Host \"Credential setup complete on $(hostname)\"",
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "credential_setup" {
  for_each = {
    for name, vm in aws_instance.nodes : name => vm if local.host_map[name].role == "dhcp_server" || name == local.bootstrap_host
  }

  name = aws_ssm_document.credential_setup.name

  targets {
    key    = "InstanceIds"
    values = [each.value.id]
  }

  parameters = {
    Username     = local.credentials.service_user
    Password     = local.service_user_password
    DomainFqdn   = local.domain.fqdn
    TrustedHosts = join(",", [for name in local.dhcp_hosts : local.assigned_ips_by_host[name]])
    IsBootstrap  = each.key == local.bootstrap_host ? "true" : "false"
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/credential-setup/${each.key}"
    }
  }

  wait_for_success_timeout_seconds = 600

  depends_on = [time_sleep.wait_for_join_reboot]
}

resource "time_sleep" "wait_for_join_reboot" {
  create_duration = "90s"

  depends_on = [aws_ssm_association.join_domain]
}

resource "aws_ssm_document" "agent_setup" {
  name            = "${try(local.aws_config.name_prefix, "msad")}-agent-setup"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Configure agent client: CredSSP, GPO delegation, RSAT, targets"
    parameters = {
      TargetServers = { type = "String" }
      DcIps         = { type = "String" }
      Username      = { type = "String" }
      Password      = { type = "String" }
      DomainFqdn    = { type = "String" }
    }
    mainSteps = [{
      action = "aws:runPowerShellScript"
      name   = "ConfigureAgentClient"
      inputs = {
        runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "",
          "# --- CredSSP Client ---",
          "$dcIps = '{{ DcIps }}'.Split(',')",
          "foreach ($ip in $dcIps) { Enable-WSManCredSSP -Role Client -DelegateComputer $ip -Force }",
          "Write-Host \"CredSSP client enabled for: $($dcIps -join ', ')\"",
          "",
          "# --- TrustedHosts ---",
          "Set-Item WSMan:\\localhost\\Client\\TrustedHosts -Value ('{{ DcIps }}' -replace ',', ',') -Force",
          "Write-Host \"TrustedHosts set to: {{ DcIps }}\"",
          "",
          "# --- Install PolicyFileEditor to write Registry.pol properly ---",
          "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
          "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null",
          "Install-Module -Name PolicyFileEditor -Force | Out-Null",
          "Import-Module PolicyFileEditor",
          "Write-Host 'PolicyFileEditor module installed'",
          "",
          "# --- GPO: Allow delegating fresh credentials (Kerberos + NTLM-only) via Registry.pol ---",
          "$polPath = \"$env:SystemRoot\\System32\\GroupPolicy\\Machine\\Registry.pol\"",
          "$regPath = 'SOFTWARE\\Policies\\Microsoft\\Windows\\CredentialsDelegation'",
          "# Enable AllowFreshCredentialsWhenNTLMOnly",
          "Set-PolicyFileEntry -Path $polPath -Key $regPath -ValueName 'AllowFreshCredentialsWhenNTLMOnly' -Data 1 -Type DWord",
          "Set-PolicyFileEntry -Path $polPath -Key $regPath -ValueName 'ConcatenateDefaults_AllowFreshNTLMOnly' -Data 1 -Type DWord",
          "$i = 1",
          "foreach ($ip in $dcIps) { Set-PolicyFileEntry -Path $polPath -Key \"$regPath\\AllowFreshCredentialsWhenNTLMOnly\" -ValueName \"$i\" -Data \"WSMAN/$ip\" -Type String; $i++ }",
          "Write-Host \"GPO Registry.pol: AllowFreshCredentialsWhenNTLMOnly set for: $($dcIps | ForEach-Object { \"WSMAN/$_\" })\"",
          "",
          "# --- Apply group policy ---",
          "gpupdate /force",
          "Write-Host 'Group policy updated'",
          "",
          "# --- Write agent target list ---",
          "$path = 'C:\\ProgramData\\msad-agent'",
          "New-Item -Path $path -ItemType Directory -Force | Out-Null",
          "$targets = '{{ TargetServers }}'.Split(',')",
          "$targets | ConvertTo-Json | Set-Content -Path \"$path\\dhcp-targets.json\"",
          "Write-Host \"Agent targets written to $path\\dhcp-targets.json\"",
          "",
          "# --- Verify CredSSP with Invoke-Command ---",
          "$secPass = ConvertTo-SecureString '{{ Password }}' -AsPlainText -Force",
          "$cred = New-Object System.Management.Automation.PSCredential('{{ Username }}@{{ DomainFqdn }}', $secPass)",
          "$dcIp = ($dcIps | Select-Object -First 1)",
          "Write-Host \"Testing Invoke-Command to $dcIp as {{ Username }}@{{ DomainFqdn }}...\"",
          "$result = Invoke-Command -ComputerName $dcIp -Credential $cred -Authentication Credssp -ScriptBlock { \"CredSSP OK from $env:COMPUTERNAME as $(whoami) on $(hostname)\" } -ErrorAction Stop",
          "Write-Host $result",
          "Write-Host '--- CredSSP Verification Passed ---'",
          "Write-Host 'Agent setup complete'"
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "agent_setup" {
  for_each = {
    for name, vm in aws_instance.nodes : name => vm if local.host_map[name].role == "agent_client"
  }

  name = aws_ssm_document.agent_setup.name

  targets {
    key    = "InstanceIds"
    values = [each.value.id]
  }

  parameters = {
    TargetServers = join(",", [for name in local.dhcp_hosts : local.assigned_ips_by_host[name]])
    DcIps         = local.assigned_ips_by_host[local.bootstrap_host]
    Username      = local.credentials.service_user
    Password      = local.service_user_password
    DomainFqdn    = local.domain.fqdn
  }

  dynamic "output_location" {
    for_each = local.ssm_logs_enabled ? [1] : []
    content {
      s3_bucket_name = local.ssm_log_bucket
      s3_key_prefix  = "${local.ssm_log_prefix}/agent-setup/${each.key}"
    }
  }

  wait_for_success_timeout_seconds = 300

  depends_on = [aws_ssm_association.credential_setup]
}

resource "vault_kv_secret_v2" "rdp_credentials" {
  for_each = local.rdp_store_enabled ? aws_instance.nodes : {}

  mount = try(local.vault_cfg.mount, "secret")
  name  = "${trimspace(local.rdp_vault_prefix)}/${each.key}"

  data_json = jsonencode({
    username    = "CORP\\Administrator"
    password    = local.domain_admin_password
    instance_id = each.value.id
    private_ip  = each.value.private_ip
    host        = each.key
  })

  depends_on = [aws_instance.nodes]
}
