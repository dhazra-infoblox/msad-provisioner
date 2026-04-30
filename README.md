# MSAD Provisioner

Automated provisioning of Windows Server VMs with Active Directory, DHCP, DNS, CredSSP delegation, and WMI permissions on AWS using Terraform and SSM.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.5 | `brew install terraform` |
| AWS CLI | v2 | `brew install awscli` |

You also need an AWS SSO profile, an EC2 key pair, and a VPC with a subnet and security group.

## Quick Start

```bash
cp config/environment.yml.example config/environment.yml   # edit with your AWS details
cat > terraform/secret.tfvars <<'EOF'
admin_password     = "YourAdminPassword"
safe_mode_password = "YourSafeModePassword"
service_password   = "YourServicePassword"
key_pair_pem_path  = "/path/to/your-key.pem"
EOF

make login

make init && make apply
make progress   # monitor phase status
```

For a full teardown and rebuild: `make redeploy`

## Host Roles

| Role | Description |
|------|-------------|
| `dhcp_server` | DHCP + DNS + AD tools. The `bootstrap: true` host creates the AD forest. |
| `agent_client` | RSAT tools + CredSSP client. Joins domain as member server. |
| `domain_controller` | AD DS + DHCP + DNS. Additional DC (if not bootstrap). |

## Provisioning Phases

```
1. rename_computer       → Set hostname (reboot)
2. configure_networking  → Static IP, DNS, IMDS route
3. install_features      → Role-specific Windows features
4. bootstrap_domain      → Create AD forest on bootstrap host (reboot)
5. dns_forwarder         → VPC DNS forwarder on the DC
6. join_domain           → Domain join with SRV polling + retries (reboot)
7. credential_setup      → Service user, CredSSP server, WMI ACLs, DHCP post-install
8. agent_setup           → CredSSP client, GPO delegation, target list, e2e verification
```

## Make Targets

| Command | Description |
|---------|-------------|
| `make apply` | Deploy everything |
| `make destroy` | Tear down everything |
| `make redeploy` | Destroy + apply |
| `make progress` | SSM phase status |
| `make logs PHASE=x HOST=y` | View SSM script output |
| `make logs PHASE=x HOST=y RUN=all` | List all runs with timestamps |
| `make status` | Host inventory |
| `make creds HOST=x` | RDP credentials for a host |

## VM Credentials

Credentials are read directly from local files — no secrets server required.

```bash
make creds              # table of all hosts (instance ID, IP, username, password)
make creds HOST=dhcp01  # details for a single host
```

Sources used:
- **Username** — `domain.admin_user` in `config/environment.yml`
- **Password** — `admin_password` in `terraform/secret.tfvars`
- **Instance ID / IP** — `terraform output host_inventory` (from state)

Both config files are gitignored and stay on disk, so credentials are always available after `make apply` without any additional setup.



Script output goes to S3 (not Terraform stdout). Configure in `environment.yml`:

```yaml
ssm_logs:
  s3_bucket: your-bucket
  s3_prefix: ib-msad
```

## Project Structure

```
config/environment.yml       # Your config (gitignored)
terraform/main.tf            # VM + SSM provisioning (8 phases)
terraform/secret.tfvars      # Passwords (gitignored)
scripts/progress.sh          # SSM phase progress viewer
scripts/ssm_logs.sh          # S3 log viewer
scripts/creds.sh             # VM credential lookup
Makefile                     # All commands
TROUBLESHOOTING.md           # Debugging guide
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debugging common issues, verification steps, and WMI/CredSSP diagnostics.
