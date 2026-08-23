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

`ip_start_offset` only governs where auto-assignment *begins*; it does not reserve a range. Growing a setup past its slice will run into the next setup's offset, and the `ip_capacity` check fails at plan time if the subnet runs out of room past the offset. Pin IPs with [`make lock-ips`](#ip-pinning) so allocations stay put.

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

Phases are chained via `depends_on` and `time_sleep` resources (90 s rename / 120 s features / 180 s bootstrap / 90 s join) to accommodate Windows reboots.

Each `time_sleep` keys its `triggers` off the association IDs of the phase before it, so the wait re-runs when hosts are added. Without that, a newly added host would be handed to the next phase while it was still rebooting, and the phase would fail against a machine that was mid-restart.

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
| `make lock-ips [setup]` | Pin current IPs into the config (see [IP Pinning](#ip-pinning)) |
| `make deploy-perf-scripts [setup]` | Upload perf scripts to VMs |

For all targets that accept `[setup]`, pass it as a positional arg (`make apply nstarqa`) or as `SETUP=nstarqa`.

## IP Pinning

**Run `make lock-ips <setup>` after the first apply, and again after adding hosts.** Without it, changing the host list rebuilds the whole setup.

### Why

Hosts without an explicit `ip:` are assigned addresses by index into the list of currently-free subnet IPs. Once a host exists, its own IP counts as "in use" and drops out of that list — so the next plan hands out a *different* address. A changed `private_ip` forces EC2 replacement, and because the assignment is positional, adding or removing one host cascades into new IPs for the others too. The setup gets destroyed and recreated instead of amended, and the multi-phase provisioning restarts from scratch each time.

`make lock-ips` reads the deployed IPs out of Terraform state and writes them into the config as explicit `ip:` fields:

```yaml
hosts:
  - name: lab1-dhcp01
    ip: 172.28.26.225      # ← added by lock-ips
    role: dhcp_server
    bootstrap: true
```

Pinned hosts bypass index assignment entirely, so their IPs are stable no matter what else changes.

### Workflow

```bash
make apply lab1        # initial deploy
make lock-ips lab1     # pin the assigned IPs
git diff config/lab1.yml

# later — adding hosts
vim config/lab1.yml    # append new hosts (no ip: field)
make apply lab1        # only the new hosts are created
make lock-ips lab1     # pin the new hosts too
```

| After | Run `lock-ips`? | Why |
|-------|-----------------|-----|
| Initial `apply` | **Yes** | Pins everything; makes future edits incremental |
| `apply` that added hosts | **Yes** | New hosts are unpinned until you do |
| `apply` that only removed hosts | No | Survivors are already pinned |
| `apply` with no host-list change | No | Nothing new to pin |
| `redeploy` | **Yes** | Every instance is new |
| `destroy` | No | Nothing left to pin |

The command is idempotent — re-running it just rewrites the same values.

### Effects

Terraform also skips its subnet-wide ENI scan when nothing needs auto-assignment. That speeds up plans and avoids a race where an ENI belonging to another setup is deleted mid-plan, which otherwise fails with `no matching EC2 Network Interface found`.

One caveat: between adding a host and running `lock-ips`, the new host's IP is still auto-assigned and can shift on a subsequent plan. Pin promptly.

## Adding or Removing Hosts

Provided every existing host is pinned ([IP Pinning](#ip-pinning)), growing or shrinking a setup only touches the machines you changed.

### Steps

```bash
# 1. Confirm existing hosts are pinned — every entry should have an ip: field
grep -c 'ip:' config/lab1.yml

# 2. Append the new hosts (no ip: field — they get auto-assigned)
vim config/lab1.yml

# 3. Dry run. Check for "must be replaced" on any aws_instance — there should be none.
make plan lab1

# 4. Apply, then pin the new hosts
make apply lab1
make lock-ips lab1

# 5. Verify every phase actually succeeded (see the caveat below)
make progress lab1
```

Removing a host is the same minus step 4's `lock-ips`: delete its block from the config and apply.

### What actually changes

Adding one `dhcp_server` and one `agent_client` to a healthy 5-host setup plans as:

| Resource | Action | Why |
|----------|--------|-----|
| `aws_instance.nodes` (new hosts only) | created | **No existing instance is touched** |
| All 6 phases for the new hosts | created | They provision from scratch |
| `credential_setup` on existing DHCP hosts | updated in-place | `TrustedHosts` gained an IP |
| `agent_setup` on existing clients | updated in-place | `TargetServers` gained an IP |
| The 3 `time_sleep` resources | replaced | `triggers` changed, so reboot waits re-run |

The in-place updates re-run those scripts on existing machines. They are idempotent, so this is safe — it just adds a few minutes.

### Before you add

| Check | Limit | Symptom if violated |
|-------|-------|---------------------|
| Hostname length | **≤ 15 characters** | `rename_computer` fails. `lab1-client01` is 16 and fails; `lab1-clt01` is 10 and works. |
| Free IPs past `ip_start_offset` | Enough for the new hosts | Plan fails the `ip_capacity` check |
| EC2 vCPU quota | Account-wide | Instances launch then vanish: `collecting instance settings: empty result` |

The NetBIOS 15-character cap is the easiest one to trip, since role names like `client01` push a prefixed name over on their own. Prefer short forms such as `clt01`.

### Caveat: a clean apply does not mean every phase passed

`Apply complete!` only means Terraform had nothing left to create. An association that failed on an *earlier* run stays in state and is never retried, so its failure is invisible to later applies.

`make progress <setup>` shows the real per-phase status. To retry a specific failed phase, force it to re-run:

```bash
terraform -chdir=terraform apply \
  -var="config_file=../config/lab1.yml" \
  -var-file="secret.lab1.tfvars" \
  -replace='aws_ssm_association.configure_networking["lab1-dhcp04"]' \
  --auto-approve
```

The same `-replace` is needed after editing an SSM document's script: associations reference documents by name, so a content change alone will not re-execute anything.

Individual phases can also fail transiently when a host is slow to finish a reboot. Re-running `make apply` is usually enough, since only the failed association is retried.

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
  lock_ips.py              # pin deployed IPs into the config YAML
  deploy_perf_scripts.sh   # upload and run perf scripts via SSM
  bulk_dhcp_load.ps1       # create bulk DHCP scopes/reservations
  performance.ps1          # sample agent process CPU/memory

Makefile                   # all operator commands
TROUBLESHOOTING.md         # debugging guide
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debugging common issues, verification steps, and WMI/CredSSP diagnostics.
