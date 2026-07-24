# MSAD Provisioner

Automated provisioning of Windows Server VMs with Active Directory, DHCP, DNS, CredSSP delegation, and WMI permissions on AWS using Terraform and SSM.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.5 | `brew install terraform` |
| AWS CLI | v2 | `brew install awscli` |
| jq | any | `brew install jq` |
| Python 3 | >= 3.8 | `brew install python` |
| PyYAML | any | `pip3 install pyyaml` |

You also need an AWS SSO profile, an EC2 key pair, and a VPC with a subnet and security group.

## Quick Start

### Default setup

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

### Named setup

```bash
make create-setup SETUP=lab1          # scaffold config/lab1.yml + terraform/secret.lab1.tfvars
# edit config/lab1.yml and terraform/secret.lab1.tfvars

make apply lab1                       # positional arg, or: make apply SETUP=lab1
make progress lab1
make destroy lab1
```

## Multi-Setup (Workspaces)

Multiple independent AD environments can coexist in the same AWS account using named setups. Each setup gets its own:

- **Config file** — `config/<setup>.yml` (VPC, AMI, domain, hosts)
- **Secret file** — `terraform/secret.<setup>.tfvars` (passwords)
- **Terraform workspace** — auto-created on first `make apply <setup>`

The `SETUP` variable can be passed as an environment variable or as a positional second argument to any target:

```bash
make apply nstarqa
make status SETUP=nstarqa
make destroy failover
```

The default setup (no `SETUP` specified) uses `config/environment.yml` and `terraform/secret.tfvars` in the `default` workspace.

### Constraints when sharing a VPC/subnet

When multiple setups share the same subnet, two fields in each config must be unique:

| Field | Purpose | Example values |
|-------|---------|----------------|
| `aws.name_prefix` | Drives SSM document names in AWS (must be globally unique per account) | `msad_lab1`, `msad_lab2` |
| `network.ip_start_offset` | Which IP index to start assigning from; prevents IP conflicts | `10`, `30`, `50`, `70` … |

Allow at least 20 IP slots per setup (2 DHCP servers + 1 agent client + buffer). The `create-setup` script auto-picks a safe offset by scanning all existing configs.

### Existing setups

| Setup | Domain | IP offset |
|-------|--------|-----------|
| hari | hari.local | 10 |
| nstarqa | nstarqa.local | 30 |
| b1ddimigrate | b1ddimigrate.local | 50 |
| automation | automation.local | 70 |
| failover | failover.local | 90 |
| msmulti | msmulti.local | 110 |

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

Phases are chained via `depends_on` and `time_sleep` resources (90 s / 180 s / 90 s) to accommodate Windows reboots.

## Make Targets

| Command | Description |
|---------|-------------|
| `make login` | AWS SSO login |
| `make init` | Terraform init |
| `make create-setup SETUP=name` | Scaffold a new named setup |
| `make validate [setup]` | Terraform validate |
| `make plan [setup]` | Terraform plan |
| `make apply [setup]` | Deploy everything |
| `make destroy [setup]` | Tear down everything |
| `make redeploy [setup]` | Destroy + apply |
| `make output [setup]` | Terraform output |
| `make status [setup]` | Host inventory |
| `make progress [setup]` | SSM phase status |
| `make logs PHASE=x HOST=y` | View SSM script output |
| `make logs PHASE=x HOST=y RUN=all` | List all runs with timestamps |
| `make creds [setup]` | RDP credentials for all hosts |
| `make creds HOST=x [setup]` | RDP credentials for one host |
| `make deploy-perf-scripts [setup]` | Upload perf scripts to VMs |

For all targets that accept `[setup]`, pass it as a positional arg (`make apply nstarqa`) or as `SETUP=nstarqa`.

## VM Credentials

Credentials are read directly from local files — no secrets server required.

```bash
make creds              # table of all hosts (instance ID, IP, username, password)
make creds HOST=dhcp01  # details for a single host
make creds nstarqa      # credentials for a named setup
```

Sources used:
- **Username** — `domain.admin_user` in `config/<setup>.yml`
- **Password** — `admin_password` in `terraform/secret.<setup>.tfvars`
- **Instance ID / IP** — `terraform output host_inventory` (from state)

Both config files are gitignored and stay on disk, so credentials are always available after `make apply` without any additional setup.

## SSM Logs

Script output goes to S3 (not Terraform stdout). Configure in your setup's YAML:

```yaml
ssm_logs:
  s3_bucket: your-bucket
  s3_prefix: ib-msad
```

Browse logs with:

```bash
make logs                              # list phases with logs
make logs PHASE=join-domain            # list hosts for that phase
make logs PHASE=join-domain HOST=dhcp02          # show latest stdout/stderr
make logs PHASE=join-domain HOST=dhcp02 RUN=all  # list all runs
make logs PHASE=join-domain HOST=dhcp02 RUN=2    # show a specific run
```

## Performance Testing

Two scripts can be uploaded to the VMs to stress-test the Infoblox agent against a large DHCP dataset:

| Script | Target | Purpose |
|--------|--------|---------|
| `scripts/bulk_dhcp_load.ps1` | DHCP servers | Create synthetic `/24` scopes with optional static reservations |
| `scripts/performance.ps1` | Agent clients | Sample CPU/memory of the `InfobloxAgentForMicrosoft` process |

```bash
make deploy-perf-scripts SETUP=nstarqa
make deploy-perf-scripts SETUP=nstarqa SCOPE_COUNT=1000 RESERVATIONS_PER_SCOPE=10
make deploy-perf-scripts SETUP=nstarqa DRY_RUN=1   # preview without executing
```

`SCOPE_COUNT` defaults to `500`; `RESERVATIONS_PER_SCOPE` defaults to `0`.

## Project Structure

```
config/
  environment.yml.example  # canonical template (tracked)
  environment.yml          # default setup config (gitignored)
  <setup>.yml              # named setup config (gitignored)

terraform/
  main.tf                  # EC2, IAM, 8 SSM documents + associations
  variables.tf             # input variables
  outputs.tf               # host_inventory, phase_association_ids, etc.
  secret.tfvars            # default setup passwords (gitignored)
  secret.<setup>.tfvars    # named setup passwords (gitignored)

scripts/
  create_setup.sh          # scaffold a new named setup
  progress.sh              # SSM phase progress viewer
  ssm_logs.sh              # S3 log browser
  creds.sh                 # VM credential lookup
  deploy_perf_scripts.sh   # upload and run perf scripts via SSM
  bulk_dhcp_load.ps1       # create bulk DHCP scopes/reservations
  performance.ps1          # sample agent process CPU/memory

Makefile                   # all operator commands
TROUBLESHOOTING.md         # debugging guide
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debugging common issues, verification steps, and WMI/CredSSP diagnostics.
