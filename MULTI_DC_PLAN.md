# Design: multiple domain controllers

Status: **implemented, not yet exercised against a live domain.** The phases are
written and `terraform validate` is clean, but no two-DC setup has been applied,
so treat the first run as a test. **[D4]** is still open.

| Decision | Outcome |
|----------|---------|
| **[D1]** Must the bootstrap host be `role: dc`? | No — left free. `create-setup` emits `dc`, and validation only rejects a `clt` bootstrap host, which would be nonsense. |
| **[D2]** Auto-add extra DCs to `network.dns_servers`? | No. It would re-run `configure_networking` on every host and rewrite their static NIC config. Set `network.dns_servers` by hand if you want the redundancy. |
| **[D3]** Delegate CredSSP to all DCs? | Already handled. `agent_setup` unions `DcIps` with `TargetServers`, and `server_hosts` includes `dc`, so every DC is delegated with no parameter change. |
| **[D4]** Demote on removal? | **Open.** Documented as a limitation below. |
| **[D5]** Should `dc` hosts run DHCP? | Yes, kept as-is — a DC that is also DNS and DHCP is a realistic customer topology and a useful agent test target. |
| **[D6]** How many DCs? | Promotion runs per host in parallel, like every other phase. Fine for two; revisit if a setup ever wants ten. |

## Goal

Let a setup declare more than one `dc` host and have each one actually become a
read/write domain controller in the same domain, replicating with the first.

Non-goals for this phase: child domains, multiple forests, read-only DCs (RODC),
cross-site replication topology, FSMO role transfer, trusts.

## Why the current role model stops short

`dc` is already a valid role and already installs the right features, but nothing
promotes it:

| Piece | Where | State |
|-------|-------|-------|
| Forest creation on the bootstrap host | `Install-ADDSForest`, main.tf | done |
| `AD-Domain-Services` feature on `dc` hosts | `install_windows_features`, main.tf | done |
| `dc` counted as a managed server (agent targets, TrustedHosts) | `local.server_hosts`, main.tf | done |
| Promotion of a non-bootstrap `dc` host | `aws_ssm_association.promote_dc` | done |
| Resolver + forwarder repair after promotion | `aws_ssm_association.configure_promoted_dc` | done |
| DC-aware credential setup | `IsDomainController` parameter | done |
| Demotion when a `dc` host is removed | — | **not done, see [D4]** |

## How AD does it

The first DC creates the forest (`Install-ADDSForest`). Every additional DC in the
same domain is promoted with:

```powershell
Install-ADDSDomainController `
  -DomainName <fqdn> `
  -Credential <domain admin> `
  -SafeModeAdministratorPassword <secure string> `
  -InstallDns `
  -Force
```

All DCs are read/write and replicate multi-master. `-InstallDns` makes the new DC
a DNS server and the AD-integrated zones replicate to it as part of promotion.
The five FSMO roles stay on the first DC and need no attention for a lab. In a
single subnet everything lands in `Default-First-Site-Name`, so no site or
replication-topology work is needed.

The host does not need to be domain-joined first, but ours already are, which is
fine and slightly simpler.

## Proposed phase

A new `promote_dc` SSM document and association, targeting
`dc` hosts other than the bootstrap host.

**Ordering.** Insert between the domain join and credential setup:

```
join_domain → wait_for_join_reboot → promote_dc → wait_for_promotion → credential_setup
```

`credential_setup` currently depends on `time_sleep.wait_for_join_reboot`; it
would move to a new `time_sleep.wait_for_promotion`, keyed off the promotion
association IDs the same way the existing sleeps are keyed. Setups with no extra
`dc` host get an empty association set, so the sleep is a no-op for them.

**Idempotency.** Skip if the host is already a DC — `(Get-WmiObject
Win32_ComputerSystem).DomainRole` returns 4 or 5 on a DC versus 3 for a member
server. Cheap and available before the AD cmdlets are loaded.

**Completion check.** Promotion reboots on its own. After it, poll until the NTDS,
Netlogon and DNS services are running and `Get-ADDomainController -Identity
$env:COMPUTERNAME` resolves, rather than trusting the exit code — the same
pattern the join phase already uses for SRV records.

## The part that will bite: local groups

`credential_setup` has two branches, selected by the `IsBootstrap` parameter. The
non-bootstrap branch uses `Add-LocalGroupMember` for `DHCP Administrators` and
`Remote Management Users`.

**Promoting a host to a DC converts its local groups into domain groups.** Those
`Add-LocalGroupMember` calls fail on a DC — the existing code even throws
deliberately if the local `DHCP Administrators` group is missing.

So `IsBootstrap` has to become "is this host a DC", covering the bootstrap host
and every promoted `dc` host. That is a parameter rename plus a filter change,
and it is the main reason this is not a one-line feature. I have left a comment
at that parameter in main.tf marking the dependency.

Consequence for existing setups: renaming the parameter changes the
`credential_setup` association, so it re-runs on every host. Idempotent, but it
is a real cost to schedule.

## Decision detail

- **[D1] Must the bootstrap host be `role: dc`?** It is a DC in fact. Enforcing it
  is a validation change that would fail every existing config, so the options are
  to require it only for new setups, warn, or leave it free. My preference: leave
  it free, and have `create-setup` emit `dc` (which it now does).
- **[D2] Should extra DCs be added to `network.dns_servers` automatically?** A
  second DC is only useful for resolver redundancy if clients know about it. But
  changing the DNS list changes the `configure_networking` parameters, which
  re-runs that phase on **every** host in the setup and rewrites their static NIC
  config. Safer as an opt-in field than as automatic behaviour.
- **[D3] Should `agent_setup` delegate CredSSP to all DCs?** `DcIps` is currently
  the bootstrap IP alone. Extending it re-runs `agent_setup` on clients.
- **[D4] What happens when a `dc` host is removed from the config? — STILL OPEN.**
  Destroying a DC instance without demoting it leaves an orphaned DC object, plus
  stale DNS SRV records and replication partners in AD. The domain keeps working,
  but clients may try the dead DC until the records age out, and a later host
  reusing that name will collide with the stale object. Options: a demotion step
  (`Uninstall-ADDSDomainController`) triggered before destroy — awkward in
  Terraform, since it needs to run on a machine that is about to disappear — or a
  documented manual `ntdsutil` metadata cleanup, or a `make demote-dc HOST=x`
  helper run by hand before editing the config. **My recommendation: the helper.**
  It keeps the destroy path honest without wiring a fragile destroy-time
  provisioner. Full `make destroy` / `make redeploy` are unaffected, since the
  whole domain goes with them.
- **[D5] Should `dc` hosts run DHCP at all?** They do today. DHCP on a DC is
  supported but has a known wrinkle: the DHCP service registers DNS records as the
  machine account, which is why Microsoft advises against putting a DC in the
  `DnsUpdateProxy` group. Worth an explicit decision rather than inheriting it.
- **[D6] How many DCs is this expected to scale to?** Two is a different test
  target than ten; it changes whether promotion can run in parallel or has to be
  serialised behind the first DC's replication.

## Validation changes needed

- Exactly one `bootstrap: true` — unchanged.
- Allow many `dc` hosts — already allowed, no change.
- Possibly require at least one `dc` host, so a setup cannot consist only of `srv`
  hosts with a bootstrap that never gets the AD DS feature installed. Today that
  works by accident, because `bootstrap_domain` installs the feature itself.

## Test plan — none of this has been run yet

1. New setup, one `dc` + one `srv` + one `clt` — proves no regression for the
   single-DC path.
2. New setup, two `dc` hosts — `Get-ADDomainController -Filter *` lists both,
   `repadmin /showrepl` is clean, DNS zones present on both.
3. Existing setup (`stgwin`), unchanged config — plan shows only the
   `credential_setup` parameter rename, no replacement.
4. `make destroy` on a two-DC setup — completes without manual cleanup.
5. Add a `dc` host to a live setup, then remove it — this is where **[D4]** gets
   decided in practice.

## Rough size

The promotion document and association are straightforward. The
`IsBootstrap` → "is a DC" change touches `credential_setup`'s filter, parameters
and PowerShell branching, and re-runs that phase everywhere. The DNS and CredSSP
questions (**[D2]**, **[D3]**) are each small in code and large in blast radius,
which is why they are decisions rather than defaults.
