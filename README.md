# MSAD Provisioner

Automated provisioning of Windows Server VMs with Active Directory, DNS, DHCP, CredSSP delegation, and WMI permissions on AWS using Terraform and SSM.

Every host gets the full AD + DNS + DHCP stack, so the same setup serves AD, DNS and DHCP work alike.

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

`create-setup` derives the domain, the IP offset, and a short host prefix from the setup name (see [Host Naming](#host-naming)). Override any of them:

```bash
make create-setup SETUP=stgwin                      # hosts: sw-srv01, sw-srv02, sw-clt01
make create-setup SETUP=stgwin PREFIX=stg           # hosts: stg-srv01, stg-srv02, stg-clt01
make create-setup SETUP=stgwin DOMAIN=win.stage.lab NETBIOS=WINSTAGE IP_OFFSET=210
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

Allow at least 20 IP slots per setup (2 server hosts + 1 agent client + buffer). The `create-setup` script auto-picks a safe offset by scanning the existing configs that share the same subnet.

`ip_start_offset` only governs where auto-assignment *begins*; it does not reserve a range. Growing a setup past its slice will run into the next setup's offset, and the IP capacity precondition fails the plan if the subnet runs out of room past the offset. Pin IPs with [`make lock-ips`](#ip-pinning) so allocations stay put.

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

A role names what the host *is*, not one of the services it runs — a `srv` host carries AD, DNS and DHCP together.

| Role | Description |
|------|-------------|
| `dc` | Domain controller: AD DS + DNS + DHCP. The `bootstrap: true` host creates the forest and is the first DC. |
| `srv` | Member server: DNS + DHCP + AD tools. Domain-joined, never promoted. |
| `clt` | Agent client: RSAT tools + CredSSP client. Joins the domain as a member server. |

`dc` and `srv` are both *managed servers* — the agent's target list and the `TrustedHosts` set cover both, because a DC runs DNS and DHCP just like a member server does. Only `clt` is treated differently.

The original names are still accepted as aliases, so a config written against the old schema needs no edit:

| Legacy role | Canonical role |
|-------------|----------------|
| `dhcp_server` | `srv` |
| `agent_client` | `clt` |
| `domain_controller` | `dc` |

Terraform normalises the alias before anything sees it, so `terraform output host_inventory`, the `HostRole` tag, and the SSM parameters all report the short form.

### Multiple domain controllers

AD supports any number of read/write DCs per domain, and the role model here is named for that: the bootstrap host is `dc01`, a second would be `dc02`.

Declare as many `dc` hosts as you want. The bootstrap host creates the forest (`Install-ADDSForest`); every other `dc` host is promoted into the same domain by the `promote_dc` phase (`Install-ADDSDomainController -InstallDns`), so it ends up a writable DC with a replicated copy of the AD-integrated DNS zones.

```yaml
hosts:
  - name: sw-dc01      # creates the forest, holds all 5 FSMO roles
    role: dc
    bootstrap: true
  - name: sw-dc02      # joins, then gets promoted
    role: dc
  - name: sw-srv01     # member server: DNS + DHCP, no directory copy
    role: srv
  - name: sw-clt01
    role: clt
```

> **Not yet exercised against a live domain.** The phase is written and the plan
> is clean, but no two-DC setup has been applied yet. Try it on a scratch setup
> before using it for anything that matters.

Two consequences worth knowing:

- **A promoted DC gets its own DNS phase.** Promotion installs the DNS role and can repoint the host's resolver at itself, which would break resolution of the AWS SSM endpoints — an AD DNS server in a private subnet cannot reach the root hints. `configure_promoted_dc` re-asserts the resolver list and adds the same VPC forwarder the first DC gets. The existing forwarder phase cannot cover both, because `join_domain` depends on it and waiting for promotion would close a dependency cycle.
- **`credential_setup` is now DC-aware.** Promotion converts a host's local groups into domain groups, so the `Add-LocalGroupMember` path fails on a DC. The `IsBootstrap` parameter became `IsDomainController` and covers every DC. On a single-DC setup the value is identical to before.

Still open: removing a `dc` host from a live config destroys the instance without demoting it, which leaves an orphaned DC object and stale SRV records in AD. See **[D4]** in [MULTI_DC_PLAN.md](MULTI_DC_PLAN.md). Full `make destroy` / `make redeploy` are unaffected — the whole domain goes with them.

## Setup Size

`make create-setup` mirrors the template's host list by default — one `dc`, one
`srv`, one `clt`. Pass any of `SERVERS`, `DCS` or `CLIENTS` to generate a given
number of hosts instead:

```bash
make create-setup SETUP=perf20 SERVERS=20 DCS=3 CLIENTS=3
  # 20 servers (3 dc + 17 srv) + 3 clt = 23 instances
```

**`SERVERS` is the total number of server machines, and `DCS` is carved out of
it** — the two do not add up. A `dc` host runs DNS and DHCP exactly like an `srv`
host; it is just also promoted to a domain controller. So `SERVERS=20 DCS=3` gives
you 20 DHCP/DNS servers, three of which are DCs, not 23.

- Counts left unset fall back to the template's counts for that role.
- `DCS` must be at least 1 (the bootstrap host is a DC) and at most `SERVERS`.
- Hosts are named `<prefix>-dc01`…, `<prefix>-srv01`…, `<prefix>-clt01`…. Two
  digits is the limit, so no count may exceed 99.
- `instance_type` and `disk_gb` for each role come from the first host of that role
  in the template, so sizing stays defined in one place.
- No `ip:` fields are written. Run `make lock-ips <setup>` after the first apply.

`SERVERS` is also what drives every per-server fan-out: `TrustedHosts`, the
`DhcpServers` authorization list, each client's `server-targets.json`, the perf
script deployment, and the number of SSM associations updated whenever you add a
host.

### The scaffolding template

`create-setup` reads `config/template.yml` when it exists, falling back to
`config/environment.yml`. Keep the template's `default_ami_id`, `subnet_id` and
`vpc_id` current — they are what every new setup inherits.

Do not use `config/environment.yml` as the place to update those. It is the
**default setup's own config**, describing running infrastructure; changing its AMI
or subnet forces every instance in that setup to be replaced on the next apply.
Pass `SOURCE_CONFIG=<path>` to scaffold from a specific config instead.

`ip_start_offset` is derived from the footprint (`ip_start_offset` + host
count) of every existing setup **in the same subnet**, plus a gap of 10, so a
large setup does not overlap the next one's range. The new setup goes in the
first gap wide enough to hold it rather than after the highest range in use —
setups get deleted, so the space below the watermark is mostly free, and
appending to the end eventually walks off a /24. If nothing fits, `create-setup`
fails instead of scaffolding a config that cannot be planned. Pass `IP_OFFSET=`
to choose the offset yourself.

Budget the apply time: every SSM phase fans out per host, and `make apply` runs at
`-parallelism=5` (see Make Targets), so a 23-host setup works through each phase in
batches of five.

## Host Naming

Windows caps a computer (NetBIOS) name at **15 characters**, which is the tightest constraint in the whole config. The convention is `<prefix>-<role>NN` — `dcNN`, `srvNN` or `cltNN` — where the prefix is an abbreviation of the setup name:

```
stgwin  →  sw-dc01, sw-srv01, sw-srv02, sw-clt01
hari    →  hari-dc01, hari-srv01, hari-clt01
```

The suffix matches the role, so a multi-DC setup reads as `sw-dc01`, `sw-dc02`.

`create-setup` derives the prefix by length: 2 characters for a setup name up to 6, 3 up to 9, 4 up to 12 — one character per 3 characters of input. The name is split into that many chunks and the first letter of each is taken. Names under 6 characters are used whole.

| Setup | Prefix | Chunks | Example host |
|-------|--------|--------|--------------|
| `hari` | `hari` | (under 6 — used whole) | `hari-dc01` |
| `stgwin` | `sw` | `stg` `win` | `sw-dc01` |
| `nstarqa` | `naq` | `nst` `ar` `qa` | `naq-dc01` |
| `failover` | `fle` | `fai` `lov` `er` | `fle-dc01` |
| `b1ddimigrate` | `bdia` | `b1d` `dim` `igr` `ate` | `bdia-dc01` |

Pass `PREFIX=` to `create-setup` when the derived form is unhelpful. The prefix is capped at 9 characters so `<prefix>-srv01` still fits in 15.

## Plan-Time Validation

The config is validated by preconditions on `terraform_data.validation`, so a bad config **fails `terraform plan`** instead of failing hours into an apply. (These were `check` blocks before, which only ever produced warnings.)

| Rule | Bypassable |
|------|------------|
| Host name ≤ 15 characters | yes |
| Host name is letters, digits and inner hyphens only | yes |
| Host name is not all digits | yes |
| `domain.netbios` is 1–15 valid characters | yes |
| Host names are unique | no |
| Every role is `srv` / `clt` / `dc` (or a legacy alias) | no |
| Exactly one host sets `bootstrap: true` | no |
| Enough free IPs for every unpinned host | no |

The name-shape rules are bypassable because correcting a deployed host's name replaces its instance. A setup that predates these checks can keep planning while it migrates:

```yaml
validation:
  hostnames: false      # only for legacy setups; remove once names are fixed
```

The structural rules are never bypassable — a plan that violates them cannot succeed anyway.

### Migrating an existing setup

Full detail in [MIGRATION.md](MIGRATION.md). In short, a deployed setup keeps working as-is: the legacy role names still resolve, and the `aws.name_prefix` default changed for *newly scaffolded* setups only. Do not edit `name_prefix` in an existing config — it renames the SSM documents, which replaces every association.

Two things to expect:

- **Roles.** The first `apply` after this change rewrites the `HostRole` tag and the `install_features` SSM parameter from `dhcp_server` to `srv`, which re-runs the feature install on existing hosts. That is idempotent (`Install-WindowsFeature` no-ops on installed features) but costs a few minutes per host. Renaming the roles in the config to `srv`/`clt` yourself has the same effect, no more. An existing bootstrap host stays `srv` — it is a DC in fact, but changing it to `dc` buys nothing today, and renaming it to `<prefix>-dc01` would replace the instance.
- **Host names.** Setups that already carry an over-length name fail validation on their next plan. As of this change that is `amanperf`, `failover`, `hemanth`, `msmulti`, `nstarqa` (each `<setup>-client01`, 16–17 chars) and `stage10` (`stage10-client01`, `stage10-client02`). Either rename the host to `<prefix>-clt01` — which **replaces that instance** — or set `validation.hostnames: false` in the config to keep planning meanwhile.

Those over-length hosts are worth a look either way: `rename_computer` cannot apply a 16-character name, so the affected VM is likely still running under its EC2-assigned name. Check with `make progress <setup>`.

## Provisioning Phases

```
1.  rename_computer        → Set hostname (reboot)
2.  configure_networking   → Static IP, DNS, IMDS route
3.  install_features       → Role-specific Windows features
4.  bootstrap_domain       → Create AD forest on the bootstrap host (reboot)
5.  dns_forwarder          → VPC DNS forwarder on the first DC
6.  join_domain            → Domain join with SRV polling + retries (reboot)
7.  promote_dc             → Promote additional dc hosts (reboot)   ← only if any
8.  configure_promoted_dc  → Resolver list + VPC forwarder on promoted DCs
9.  credential_setup       → Service user, CredSSP server, WMI ACLs, DHCP post-install
10. agent_setup            → CredSSP client, GPO delegation, target list, e2e verification
```

Phases 7 and 8 have no targets unless the config declares a `dc` host other than the bootstrap host, so a single-DC setup runs exactly the pipeline it always did.

Phases are chained via `depends_on` and `time_sleep` resources (90 s rename / 120 s features / 180 s bootstrap / 90 s join / 240 s promotion) to accommodate Windows reboots. The promotion wait is longer because AD DS has to start and SYSVOL has to finish its initial DFSR sync.

Each `time_sleep` keys its `triggers` off the association IDs of the phase before it, so the wait re-runs when hosts are added. Without that, a newly added host would be handed to the next phase while it was still rebooting, and the phase would fail against a machine that was mid-restart.

## Make Targets

| Command | Description |
|---------|-------------|
| `make login` | AWS SSO login |
| `make init` | Terraform init |
| `make create-setup SETUP=name` | Scaffold a new named setup |
| `make create-setup SETUP=name SERVERS=20 DCS=3 CLIENTS=3` | …with a given number of hosts (see Setup Size) |
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

`make apply` runs Terraform at `-parallelism=5` rather than the default 10. Adding a
host changes a parameter on **every** existing SSM association — `TrustedHosts`
carries every server IP, `DhcpServers` every server — so Terraform fires that many
concurrent `UpdateAssociation` calls, and SSM rejects some with `TooManyUpdates`,
failing the apply partway through. Raise it with `PARALLELISM=10 make apply <setup>`
for a first apply, where there are no associations to update yet and the throttle
only slows the build down.

## IP Pinning

**Run `make lock-ips <setup>` after the first apply, and again after adding hosts.** Without it, changing the host list rebuilds the whole setup.

### Why

Hosts without an explicit `ip:` are assigned addresses by index into the list of currently-free subnet IPs. Once a host exists, its own IP counts as "in use" and drops out of that list — so the next plan hands out a *different* address. A changed `private_ip` forces EC2 replacement, and because the assignment is positional, adding or removing one host cascades into new IPs for the others too. The setup gets destroyed and recreated instead of amended, and the multi-phase provisioning restarts from scratch each time.

`make lock-ips` reads the deployed IPs out of Terraform state and writes them into the config as explicit `ip:` fields:

```yaml
hosts:
  - name: lab1-srv01
    ip: 172.28.26.225      # ← added by lock-ips
    role: srv
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

Adding one `srv` and one `clt` host to a healthy 5-host setup plans as:

| Resource | Action | Why |
|----------|--------|-----|
| `aws_instance.nodes` (new hosts only) | created | **No existing instance is touched** |
| All 6 phases for the new hosts | created | They provision from scratch |
| `credential_setup` on existing server hosts | updated in-place | `TrustedHosts` gained an IP |
| `agent_setup` on existing clients | updated in-place | `TargetServers` gained an IP |
| The 3 `time_sleep` resources | replaced | `triggers` changed, so reboot waits re-run |

The in-place updates re-run those scripts on existing machines. They are idempotent, so this is safe — it just adds a few minutes.

### Before you add

| Check | Limit | Symptom if violated |
|-------|-------|---------------------|
| Hostname length | **≤ 15 characters** | Plan fails validation. `lab1-client01` is 16; `lab1-clt01` is 10 and works. |
| Free IPs past `ip_start_offset` | Enough for the new hosts, within the subnet | Plan fails the IP capacity or offset-range precondition |
| EC2 vCPU quota | Account-wide | Instances launch then vanish: `collecting instance settings: empty result` |

The 15-character cap is the easiest one to trip, since a long suffix like `client01` pushes a prefixed name over on its own — that is exactly why the suffixes are `srvNN` and `cltNN`. The first two rows are now caught at plan time rather than mid-apply.

### Caveat: a clean apply does not mean every phase passed

`Apply complete!` only means Terraform had nothing left to create. An association that failed on an *earlier* run stays in state and is never retried, so its failure is invisible to later applies.

`make progress <setup>` shows the real per-phase status. To retry a specific failed phase, force it to re-run:

```bash
terraform -chdir=terraform apply \
  -var="config_file=../config/lab1.yml" \
  -var-file="secret.lab1.tfvars" \
  -replace='aws_ssm_association.configure_networking["lab1-srv04"]' \
  --auto-approve
```

The same `-replace` is needed after editing an SSM document's script: associations reference documents by name, so a content change alone will not re-execute anything.

Individual phases can also fail transiently when a host is slow to finish a reboot. Re-running `make apply` is usually enough, since only the failed association is retried.

## VM Credentials

Credentials are read directly from local files — no secrets server required.

```bash
make creds                # table of all hosts (instance ID, IP, username, password)
make creds HOST=naq-srv01 # details for a single host
make creds nstarqa        # credentials for a named setup
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
  s3_prefix: ssm-logs
```

Browse logs with:

```bash
make logs                              # list phases with logs
make logs PHASE=join-domain            # list hosts for that phase
make logs PHASE=join-domain HOST=naq-srv02          # show latest stdout/stderr
make logs PHASE=join-domain HOST=naq-srv02 RUN=all  # list all runs
make logs PHASE=join-domain HOST=naq-srv02 RUN=2    # show a specific run
```

## Performance Testing

Two scripts can be uploaded to the VMs to stress-test the Infoblox agent against a large DHCP dataset:

| Script | Target | Purpose |
|--------|--------|---------|
| `scripts/bulk_dhcp_load.ps1` | Server hosts (`srv`) | Create synthetic `/24` scopes with optional static reservations |
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
  main.tf                  # EC2, IAM, 10 SSM documents + associations
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
MIGRATION.md               # generic-naming + validation migration notes
MULTI_DC_PLAN.md           # design proposal for multiple domain controllers
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debugging common issues, verification steps, and WMI/CredSSP diagnostics.
