# Migration: generic naming + plan-time validation

Covers the change that renamed the DHCP-specific identifiers to generic ones and
moved config validation from `check` blocks to preconditions (2026-08-23).

**Short version:** existing setups keep working without a config edit. Nothing is
replaced, no IP moves, no domain is touched. The one visible cost is that the
Windows feature install re-runs once per host on the next apply.

## What changed

| Area | Before | After |
|------|--------|-------|
| Roles | `dhcp_server`, `agent_client`, `domain_controller` | `srv`, `clt`, `dc` — old names accepted as aliases |
| Host names | `<setup>-dhcp01`, `<setup>-client01` | `<prefix>-dc01`, `<prefix>-srv01`, `<prefix>-clt01` |
| Terraform locals | `dhcp_hosts`, `agent_hosts` | `server_hosts` (now `srv` + `dc`), `client_hosts` |
| Outputs | `dhcp_servers`, `agent_servers` | `server_hosts`, `client_hosts` |
| `name_prefix` default | `<setup>_msad_dhcp` | `<setup>_msad` (new setups only) |
| Agent target file | `dhcp-targets.json` | `server-targets.json` |
| Validation | 4 `check` blocks | preconditions on `terraform_data.validation` |

Anything that is genuinely about DHCP kept its name: `bulk_dhcp_load.ps1`, the
DHCP role and security groups, `Add-DhcpServerInDC`, and the NIC-level
DHCP-versus-static logic.

## Is it backward compatible?

Yes, with one deliberate exception (over-length host names, below). Verified
rather than assumed:

| Question | Answer |
|----------|--------|
| Did the old `check` blocks fail a plan? | No — warning only. The README's claim that `ip_capacity` "fails at plan time" was wrong. |
| Do the new preconditions fail a plan? | Yes — `Error: Resource precondition failed`. |
| Do they block `make destroy`? | **No.** Terraform skips preconditions on destroy, so a setup that fails validation can always be torn down. |

### What the first plan on an existing setup shows

| Resource | Action | Why |
|----------|--------|-----|
| `terraform_data.validation` | created | New no-op resource holding the preconditions |
| `aws_instance.nodes[*]` | updated in place | `HostRole` tag `dhcp_server` → `srv` |
| `aws_ssm_document.install_windows_features` | updated | Script now matches `srv`/`clt`/`dc` |
| `aws_ssm_association.install_windows_features[*]` | updated in place | `HostRole` parameter changed, so the feature install **re-runs** |
| `aws_ssm_document.credential_setup` | updated | `IsBootstrap` parameter renamed to `IsDomainController` |
| `aws_ssm_association.credential_setup[*]` | updated in place | Parameter rename, so credential setup **re-runs** (the value is unchanged — only the bootstrap host is a DC on a single-DC setup) |
| `aws_ssm_document.agent_setup` | updated | Target filename and comment changes only |
| `aws_ssm_document.promote_dc`, `configure_promoted_dc` | created | New phases; their associations have no targets unless a non-bootstrap `dc` host exists |

Not in the plan, deliberately:

- **No instance replacement.** Nothing touches `private_ip`, `ami`, `subnet_id`
  or the `for_each` keys, which are the only things that force one.
- **No IP changes.** Pinned IPs and the auto-assignment order are untouched.
- **`agent_setup` does not re-run.** Its `TargetServers` parameter comes out
  byte-identical, because `server_hosts` is still built in config order and no
  setup has a `dc` host yet.
- **`credential_setup` does re-run**, because of the parameter rename. It is
  idempotent, with one wart worth knowing: `Set-WmiNamespaceSecurity` appends an
  ACE without checking for an existing one, so each run adds a duplicate ACE for
  the same account on the DNS and DHCP WMI namespaces. Harmless (same SID, same
  mask) but untidy, and it already happens today every time a host is added.

The feature re-run is idempotent — `Install-WindowsFeature` no-ops on installed
features and does not reboot — but Terraform waits on it, so budget a few
minutes per host. This is the same mechanism the README already documents for
adding hosts.

## Per-setup status

| Setup | Enforcement | Action needed |
|-------|-------------|---------------|
| `automation`, `b1ddi10`, `b1ddimigrate`, `hari`, `stgwin`, `environment` (default) | on | none |
| `amanperf`, `failover`, `hemanth`, `msmulti`, `nstarqa`, `stage10` | **off** via `validation.hostnames: false` | optional, see below |

Those six have host names over the 15-character Windows limit
(`<setup>-client01`, 16–17 chars; `stage10` has two). Rather than break their
plans, each config now carries:

```yaml
validation:
  hostnames: false
```

The structural rules — unique names, valid roles, exactly one `bootstrap: true`,
enough free IPs — still apply to those setups. Only the name-shape rules are off.

### Migrating an over-length host

Worth doing: `rename_computer` cannot apply a 16-character name, so the affected
VM is probably still running under its EC2-assigned name. Confirm with
`make progress <setup>` before deciding.

The host name is the Terraform resource key, so renaming **replaces that
instance**. The domain and the other hosts are unaffected.

```bash
make progress nstarqa                  # confirm the rename phase actually failed
vim config/nstarqa.yml                 # nstarqa-client01 → naq-clt01, drop its ip:
                                       # and remove the validation: block
make plan nstarqa                      # expect exactly 1 instance replaced
make apply nstarqa
make lock-ips nstarqa                  # pin the new host's IP
make progress nstarqa                  # every phase green this time
```

Leave the existing `srv` hosts alone. Their names are fine, and renaming them to
`<prefix>-dc01`/`<prefix>-srvNN` would replace working instances for cosmetics.
An existing bootstrap host also stays `role: srv` — it is a DC in fact, but
changing it to `dc` buys nothing today.

## Things outside this repo that may break

Neither is used by anything in the repo, so both are listed as unknowns rather
than fixed:

1. **Renamed outputs.** Anything reading `terraform output dhcp_servers` or
   `agent_servers` needs `server_hosts` / `client_hosts`.
2. **`host_inventory[*].role`** now reports `srv`/`clt` instead of
   `dhcp_server`/`agent_client`. `scripts/deploy_perf_scripts.sh` accepts both
   forms; external tooling that filters on the string needs the same treatment.
3. **`dhcp-targets.json` → `server-targets.json`** on agent clients. No existing
   host is affected until that association re-runs (a `-replace`, or adding a
   `clt` host), since the parameters did not change. If the agent or a runbook
   reads the old path, revert the filename or write both.

## Rolling back

`git revert` the change. The next apply flips the `HostRole` tag and parameter
back, destroys `terraform_data.validation`, and re-runs the feature install a
second time. Nothing is left in an unrecoverable state. Configs carrying
`validation.hostnames: false` are harmless once reverted — the key is simply
ignored.

## New setups

`make create-setup <name>` now produces:

- host names `<prefix>-dc01`, `<prefix>-srvNN`, `<prefix>-cltNN`, where the
  prefix is derived from the setup name (`stgwin` → `sw`); see README → Host Naming
- the bootstrap host as `dc01` with `role: dc`, whatever the source config called it
- `name_prefix: <setup>_msad`
- no inherited `ip:` pins — scaffolding from a locked config used to copy the
  source setup's addresses, which would collide on apply
- a hard failure if any generated name exceeds 15 characters or collides
