# MSAD Provisioner

Automated provisioning of Windows Server VMs with Active Directory, DHCP, and DNS on AWS using Terraform and SSM.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.5 | `brew install terraform` |
| AWS CLI | v2 | `brew install awscli` |
| Vault | any | `brew install vault` |
| Python 3 | 3.8+ | `brew install python3` |
| PyYAML | any | `pip3 install pyyaml` |

You also need:
- An **AWS SSO profile** configured (`aws configure sso`)
- An **EC2 key pair** (.pem file) for decrypting Windows passwords
- A **VPC** with a subnet, security group, and SSM instance profile already set up

## Quick Start

```bash
# 1. Copy and edit configuration files
cp config/environment.yml.example config/environment.yml
# Edit config/environment.yml with your AWS VPC, subnet, AMI, etc.

# 2. Create secrets file
cat > terraform/secret.tfvars <<'EOF'
admin_password     = "YourAdminPassword"
safe_mode_password = "YourSafeModePassword"
service_password   = "YourServicePassword"
key_pair_pem_path  = "/path/to/your-key.pem"
EOF

# 3. Login to AWS
make login

# 4. Start Vault (for credential storage)
make vault-start
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root
make vault-setup

# 5. Initialize and deploy
make init
make plan
make apply

# 6. Monitor progress
make progress
```

## Configuration

### Environment (`config/environment.yml`)

This is the main config file. See [environment.yml.example](config/environment.yml.example) for all options.

**Key sections:**

```yaml
aws:
  profile: your-aws-profile       # AWS SSO profile name
  region: us-east-1
  vpc_id: vpc-xxxxxxxx
  subnet_id: subnet-xxxxxxxx
  security_group_ids: [sg-xxxxxxxx]
  default_ami_id: ami-xxxxxxxxx   # Windows Server 2022 AMI
  key_name: your-key-pair

domain:
  fqdn: corp.local                # AD domain name
  netbios: CORP

hosts:                             # Define your VMs here
  - name: dhcp01
    role: dhcp_server
    bootstrap: true                # Exactly one host must be bootstrap
    instance_type: t3.large
    disk_gb: 100
```

### Secrets (`terraform/secret.tfvars`)

Passwords and key path (gitignored):

```hcl
admin_password     = "YourAdminPassword"
safe_mode_password = "YourSafeModePassword"
service_password   = "YourServicePassword"
key_pair_pem_path  = "/path/to/your-key.pem"
```

### Host Roles

| Role | What it does |
|------|-------------|
| `dhcp_server` | Installs DHCP, DNS, AD tools. The `bootstrap: true` host creates the AD forest. |
| `agent_client` | Installs RSAT tools. Joins domain as member server. |
| `domain_controller` | Installs AD DS, DHCP, DNS. Joins as additional DC (if not bootstrap). |

## Provisioning Phases

Terraform deploys VMs and configures them via SSM in this order:

```
1. rename_computer       → Rename from EC2AMAZ-xxx to configured name (reboot)
2. configure_networking  → Static IP, DNS, IMDS route, network profile
3. install_features      → Role-specific Windows features (DHCP, DNS, AD tools)
4. bootstrap_domain      → Create AD forest on bootstrap host (reboot)
5. dns_forwarder         → Add VPC DNS as forwarder on the DC
6. join_domain           → Non-bootstrap hosts join the domain (reboot)
7. credential_setup      → Create service account, configure WinRM
8. agent_setup           → Write DHCP target config on agent clients
```

Automatic `time_sleep` resources are inserted after reboot-inducing steps (rename, bootstrap, join) to allow instances to come back online before the next phase starts.

## Make Targets

```
make help              Show all targets
make login             AWS SSO login
make vault-start       Start Vault dev server (background)
make vault-stop        Stop Vault dev server
make vault-status      Check Vault server status
make vault-setup       Enable KV v2 engine at secret/
make init              Terraform init
make validate          Terraform validate
make plan              Terraform plan
make apply             Terraform apply (provision everything)
make destroy           Terraform destroy (tear down everything)
make output            Show Terraform outputs
make status            Quick host inventory status
make progress          Show SSM phase progress (status, attempts, retries)
make creds             List all VM credential Vault paths
make creds HOST=dhcp01 Show RDP credentials for a specific VM
```

## Accessing VMs

### RDP Credentials

If `vault.store_rdp_credentials: true` and `key_pair_pem_path` is set:

```bash
# List all stored credentials
make creds

# Get credentials for a specific host
make creds HOST=dhcp01
```

### Connect via RDP

Use the private IP from `make status` and the credentials from `make creds`.

### Connect via SSM Session Manager

```bash
aws ssm start-session --target <instance-id> --profile your-aws-profile
```

## Vault

The project uses HashiCorp Vault to store RDP credentials. For development, use the built-in dev server:

```bash
make vault-start                         # Start dev server
make vault-start TOKEN=my-secret-token   # Custom root token
make vault-stop                          # Stop dev server
```

Set these in every terminal that runs Terraform:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root
```

To disable Vault entirely, set `vault.enabled: false` in your environment config.

## SSM Output Logging

SSM command output is truncated by default. To capture full logs in S3, add to your `config/environment.yml`:

```yaml
ssm_logs:
  s3_bucket: your-existing-bucket
  s3_prefix: ib-msad           # optional, defaults to "ssm-logs"
```

This writes full stdout/stderr from every SSM command to `s3://your-existing-bucket/ib-msad/<phase>/<host>/`. An IAM policy granting `s3:PutObject` is automatically attached to the instance role.

To disable, remove the `ssm_logs` section or omit `s3_bucket`.

Browse logs:

```bash
aws s3 ls s3://your-existing-bucket/ib-msad/ --recursive --profile your-aws-profile
```

## Troubleshooting

### SSM agent not connecting

Check that your security group allows outbound HTTPS (443) to AWS endpoints. The VMs need to reach `ssm.us-east-1.amazonaws.com`, `ec2messages.us-east-1.amazonaws.com`, and `ssmmessages.us-east-1.amazonaws.com`.

### SSM association fails immediately after a reboot phase

The provisioner inserts `time_sleep` pauses between reboot-inducing steps. If you still see failures, increase the sleep durations in `main.tf` (search for `time_sleep`). Common cause: CIM/WMI not ready yet after Windows reboot.

### DNS resolution fails after AD install

The provisioner adds the VPC DNS resolver as a fallback in each VM's DNS config and configures a forwarder on the DC. If you still see issues, verify the forwarder:

```powershell
# On the DC
Get-DnsServerForwarder
```

### Domain join fails

Ensure the bootstrap DC is fully up before other VMs try to join. Check `make progress` to verify the `bootstrap_domain` and `dns_forwarder` phases completed before `join_domain`.

### IMDS unreachable after static IP

The networking step adds a route for `169.254.169.254`. Verify it exists:

```powershell
Get-NetRoute -DestinationPrefix '169.254.169.254/32'
```

## Project Structure

```
├── config/
│   ├── environment.yml           # Your config (gitignored)
│   └── environment.yml.example   # Template to copy
├── terraform/
│   ├── main.tf                   # VM + SSM provisioning
│   ├── variables.tf              # Input variables
│   ├── outputs.tf                # Outputs (IPs, Vault paths)
│   ├── secret.tfvars             # Passwords (gitignored)
│   └── terraform.tfvars.example  # Config path example
├── scripts/
│   ├── progress.sh               # SSM association progress
│   ├── check_ips.sh              # IP allocation check
│   └── ssm_logs.sh               # SSM log viewer
├── Makefile                      # All commands
└── README.md                     # This file
```
