# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project automates provisioning of Windows VMs with Active Directory, DHCP, and DNS on VMware vSphere. It replaces manual one-by-one server setup with Infrastructure as Code.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    vSphere / vCenter                     │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐  │
│  │   VM 1      │   │   VM 2      │   │   VM N      │  │
│  │ (DC/AD/DNS) │   │ (DHCP Srv)  │   │ (Member)    │  │
│  └─────────────┘   └─────────────┘   └─────────────┘  │
└─────────────────────────────────────────────────────────┘
         │                   │
         ▼                   ▼
┌─────────────────────────────────────────────────────────┐
│   Terraform (VM Provisioning) + Ansible (Configuration) │
└─────────────────────────────────────────────────────────┘
```

**Terraform**: Provisions VMs from Windows templates on vSphere
**Ansible**: Configures Windows (static IP, AD DS, DNS, DHCP, domain join)

## Directory Structure

```
.
├── terraform/              # VM provisioning on vSphere
│   ├── main.tf            # VM resource definitions
│   ├── variables.tf       # Input variables
│   ├── outputs.tf         # Output values
│   └── terraform.tfvars  # Environment config
├── ansible/                # Windows configuration
│   ├── inventory/         # VM definitions (hosts, IPs, roles)
│   ├── playbooks/         # Automation playbooks
│   └── roles/             # Reusable role definitions
├── agent/                  # Infoblox Agent for Microsoft AD
│   ├── install.yml        # Agent installation playbook
│   ├── configure.yml      # Agent configuration
│   └── vars/              # Agent variables
└── CLAUDE.md              # This file
```

## Commands

### Terraform (Provisioning)

```bash
# Initialize Terraform
cd terraform && terraform init

# Plan changes
terraform plan -out=tfplan

# Apply (create VMs)
terraform apply tfplan

# Destroy VMs
terraform destroy
```

### Ansible (Configuration)

```bash
# Run all configuration for a host
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/configure.yml --limit <hostname>

# Set static IP only
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/set_static_ip.yml --limit <hostname>

# Install AD DS and configure domain
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/configure_ad.yml --limit <hostname>

# Configure DHCP
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/configure_dhcp.yml --limit <hostname>

# Test WinRM connection
ansible -i ansible/inventory/hosts.yml <hostname> -m win_ping
```

### Agent Installation (Infoblox Agent for Microsoft)

Install Infoblox Agent on a domain member to sync DHCP/DNS from specified AD servers:

```bash
# Install and configure agent (single command)
ansible-playbook -i ansible/inventory/hosts.yml agent/install.yml --limit <agent_host>
```

### Full Provisioning Workflow

```bash
# 1. Provision VMs
cd terraform && terraform apply

# 2. Configure AD, DHCP, DNS
cd ansible && ansible-playbook -i inventory/hosts.yml playbooks/configure_all.yml

# 3. Install Infoblox Agent (optional)
ansible-playbook -i ansible/inventory/hosts.yml agent/install.yml --limit <agent_host>
```

## Agent Configuration

The agent module handles the complete installation of Infoblox Agent for Microsoft:

### Minimal Config (agent/vars/main.yml)

```yaml
# Download source - abstract interface (S3 URL, HTTP, etc.)
download_url: "https://your-bucket.s3.amazonaws.com/infoblox_agent_for_microsoft_v1.35.38.msi"

# Target AD servers to collect data from
target_servers:
  - 192.168.1.10   # DC with DNS/DHCP
  - 192.168.1.11   # DC with DNS only

# Service account credentials
service_account:
  username: "infoblox_agent"
  password: "{{ vault_password }}"
  domain: "corp.local"

# SaaS portal
portal_url: "https://portal.infoblox.com"
api_key: "{{ vault_api_key }}"
```

### Agent Installation Steps

The playbook performs these steps:

1. **Create AD service account** - with read permissions for DNS/DHCP
2. **Enable WinRM/PSRemote** - allow remote PowerShell execution
3. **Configure firewall policies** - allow agent ports
4. **Download agent** - fetch MSI from download URL
5. **Install agent** - silent MSI installation
6. **Configure agent** - set target servers and credentials
7. **Start agent service** - ensure running and set to auto-start

### Full Provisioning Workflow

```bash
# 1. Provision VMs
cd terraform && terraform apply

# 2. Wait for VMs to boot and get DHCP IPs

# 3. Configure everything
cd ansible && ansible-playbook -i inventory/hosts.yml playbooks/configure_all.yml
```

## Key Configuration

This project allows users to design their own infrastructure. Define your network topology in two files:

### 1. Terraform Configuration (terraform/terraform.tfvars)

Define VM specifications:

```hcl
vcenter_server   = "vcenter.example.com"
vcenter_user     = "admin@vsphere.local"
vcenter_password = "your_password"
datacenter       = "DC1"
cluster          = "Cluster1"
template         = "WindowsServer2022-Template"
datastore        = "datastore1"
network          = "VM Network"
vm_folder        = "AD-Servers"

# Define your VMs here
vms = {
  dc01 = {
    name       = "dc01"
    ip_address = "192.168.1.10"
    cpu        = 4
    memory     = 8192
    disk       = 100
  }
  dc02 = {
    name       = "dc02"
    ip_address = "192.168.1.11"
    cpu        = 4
    memory     = 8192
    disk       = 100
  }
  member01 = {
    name       = "member01"
    ip_address = "192.168.1.50"
    cpu        = 2
    memory     = 4096
    disk       = 80
  }
  dhcp01 = {
    name       = "dhcp01"
    ip_address = "192.168.1.20"
    cpu        = 2
    memory     = 4096
    disk       = 60
  }
}
```

### 2. Ansible Inventory (ansible/inventory/hosts.yml)

Define roles and configurations for each VM:

```yaml
all:
  vars:
    domain_name: corp.local
    domain_netbios: CORP
    admin_password: "{{ vault_admin_password }}"
    dns_servers:
      - 192.168.1.10
      - 192.168.1.11

  children:
    # Domain Controllers - create new forest or join existing
    domain_controllers:
      hosts:
        dc01:
          ansible_host: 192.168.1.10
          ad_role: primary_dc
          ad_install: true
          dns_zones:
            - corp.local
            - 1.168.192.in-addr.arpa
        dc02:
          ansible_host: 192.168.1.11
          ad_role: replica_dc
          ad_install: true
          ad_parent_dc: dc01

    # Member servers - join domain
    member_servers:
      hosts:
        member01:
          ansible_host: 192.168.1.50
          server_role: file_server
        member02:
          ansible_host: 192.168.1.51
          server_role: app_server

    # DHCP Servers
    dhcp_servers:
      hosts:
        dhcp01:
          ansible_host: 192.168.1.20
          dhcp_enabled: true
          dhcp_scopes:
            - name: "Corp Network"
              subnet: 192.168.1.0
              start: 192.168.1.100
              end: 192.168.1.200
              router: 192.168.1.1
              dns_server: 192.168.1.10

    # Standalone / workgroup machines
    standalone:
      hosts:
        workstation01:
          ansible_host: 192.168.1.60
          domain_join: false
```

### Example Topologies

**Minimal AD Forest:**
```yaml
# dc01 = primary domain controller
# No DHCP - manual IP management
```

**Standard Office:**
```yaml
# dc01, dc02 = Domain Controllers with DNS
# dhcp01 = DHCP server
# member01+ = workstations/servers
```

**Multi-site Enterprise:**
```yaml
# site1: dc01, dc02 (primary site)
# site2: dc03 (replica DC)
# member servers distributed across sites
```

## IP Configuration Strategy

The provisioning is user-driven - you define IPs in your configuration:

1. **Pre-allocated IPs** - You specify IP addresses in terraform.tfvars and hosts.yml
2. **VM clones with DHCP** - Template gets temporary DHCP IP
3. **Set static** - Ansible converts the IP to static (or you configure reservations)

This supports any network design:

- **Static IPs everywhere** - Define each IP in config
- **DHCP for members** - DCs get static, members get DHCP
- **Hybrid** - Some static, some DHCP

## Design Your Infrastructure

The system is flexible - you choose the topology:

| Scenario | DCs | DHCP | Members | DNS |
|----------|-----|------|---------|-----|
| Lab/Test | 1 | No | 0 | Built-in |
| Small Office | 1-2 | Yes | 1-10 | Built-in |
| Enterprise | 2+ per site | Yes | Many | Integrated |
| Read-only DC | RODC | Optional | Branch office | Cache |

## Ansible Windows Modules Used

- `win_ip` - Configure static IP
- `win_feature` - Install AD DS, DHCP Server roles
- `win_domain` - Create new domain
- `win_domain_join` - Join existing domain
- `win_dns_record` - Manage DNS records
- `win_dhcp_scope` - Configure DHCP scopes
- `win_service` - Manage Windows services

## Requirements

### For Terraform
- Terraform >= 1.0
- `terraform-provider-vsphere` plugin

### For Ansible
- Ansible >= 2.10
- `community.windows` collection
- `ansible.windows` collection
- PyWinRM (`pip install pywinrm`)

### Access
- WinRM enabled on Windows templates
- vCenter API access
- Network connectivity to target VMs

## Security Notes

- Store vCenter credentials in environment variables or use Terraform Vault integration
- Ansible vault for sensitive variables (passwords, keys)
- Never commit credentials to version control
