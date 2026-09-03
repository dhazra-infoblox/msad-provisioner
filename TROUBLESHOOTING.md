# Troubleshooting

## `terraform plan` fails on a host name

Host names are validated at plan time against the 15-character Windows computer name limit, plus the character and uniqueness rules. The error names every offender and its length.

Fix the name in the config — the convention is `<prefix>-srvNN` / `<prefix>-cltNN`, e.g. `sw-srv01`. Renaming a host that is already deployed **replaces its instance**, since the name is the resource key. To keep a legacy setup planning while you migrate, add:

```yaml
validation:
  hostnames: false
```

Structural failures (duplicate names, an invalid role, no or several `bootstrap: true` hosts, not enough free IPs) cannot be bypassed — the plan could not succeed anyway.

## promote_dc fails or times out

The promotion phase is the least-exercised part of the pipeline. Check the log
first: `make logs PHASE=promote-dc HOST=sw-dc02`.

| Symptom | Likely cause |
|---------|--------------|
| `DC SRV record ... not found after 600s` | The first DC is not answering, or this host's resolver never got the DC's IP. Check `bootstrap_domain` and `dns_forwarder` completed, then `Resolve-DnsName _ldap._tcp.dc._msdcs.<domain> -Type SRV` on the host. |
| Association times out with no output | Promotion reboots the host; if SSM never comes back, DNS is the usual reason. See below. |
| `The credentials supplied ... are not sufficient` | `domain.admin_user` must be a Domain Admin. The bootstrap phase sets the built-in Administrator password to `admin_password`, so those two must agree. |

If a promoted DC goes silent after its reboot, it is almost always name
resolution: promotion installs the DNS role and can repoint the resolver at
itself, and an AD DNS server in a private subnet cannot reach the root hints, so
`ssm.<region>.amazonaws.com` stops resolving. That is what `configure_promoted_dc`
repairs — but if the host is already unreachable, SSM cannot deliver it. Recover
over RDP:

```powershell
Set-DnsClientServerAddress -InterfaceIndex (Get-NetAdapter | ? Status -eq Up).IfIndex `
  -ServerAddresses 127.0.0.1,<vpc-dns-ip>
Add-DnsServerForwarder -IPAddress <vpc-dns-ip>
```

The VPC DNS address is the VPC CIDR's `.2` — `terraform output` shows the subnet.

To confirm a promotion actually took:

```powershell
(Get-CimInstance Win32_ComputerSystem).DomainRole   # 4 or 5 = DC, 3 = member server
Get-ADDomainController -Filter * | Select HostName, Site, IsGlobalCatalog
repadmin /showrepl
```

## SSM agent not connecting

Check that your security group allows outbound HTTPS (443) to AWS endpoints. The VMs need to reach `ssm.us-east-1.amazonaws.com`, `ec2messages.us-east-1.amazonaws.com`, and `ssmmessages.us-east-1.amazonaws.com`.

## SSM association fails immediately after a reboot phase

The provisioner inserts `time_sleep` pauses between reboot-inducing steps. If you still see failures, increase the sleep durations in `main.tf` (search for `time_sleep`). Common cause: CIM/WMI not ready yet after Windows reboot.

## DNS resolution fails after AD install

The provisioner adds the VPC DNS resolver as a fallback in each VM's DNS config and configures a forwarder on the DC. If you still see issues, verify the forwarder:

```powershell
# On the DC
Get-DnsServerForwarder
```

## Domain join fails

Ensure the bootstrap DC is fully up before other VMs try to join. Check `make progress` to verify the `bootstrap_domain` and `dns_forwarder` phases completed before `join_domain`. The join phase includes SRV record polling (up to 600s) and 8 join retries with 30s backoff.

## credential_setup fails on non-DC hosts with IdentityNotMappedException

This happens when the non-DC host tries to resolve the service user SID before the DC has created the AD user. The built-in retry loop (12 attempts × 10s) handles this automatically. If it still fails, increase the `wait_for_join_reboot` sleep duration to give the bootstrap host more time to finish first.

## CredSSP "Access Denied" from agent client

Verify the GPO is applied on the agent client:

```powershell
# On the agent client
Get-WSManCredSSP
# Should show: configured to delegate to wsman/<DC_IP>

# Check Registry.pol entries
Import-Module PolicyFileEditor
Get-PolicyFileEntry -Path "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol" -All |
  Where-Object { $_.Key -match 'CredentialsDelegation' }
```

## WMI permissions not applied

Verify via WMI Control (`wmimgmt.msc`) → Properties → Security tab → navigate to `Root\Microsoft\Windows\DNS` or `DHCP`. The service user and DNSAdmins should have **Enable Account**, **Execute Methods**, and **Remote Enable** checked.

## Server Manager still prompts "Complete DHCP configuration"

`credential_setup` does the whole post-install: it creates the DHCP security
groups, authorizes every server in AD, and writes the Server Manager completion
flag (`HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12` → `ConfigurationState = 2`).
A host still showing the yellow post-deployment flag has not run the current
version of that phase.

The fix is a normal apply — the phase re-runs on every server host and is
idempotent:

```bash
make apply <setup>
```

To clear the flag on a running fleet without a full apply, one SSM command covers
every host at once. No RDP session, no per-server login:

```bash
SETUP=dctest
cat > /tmp/fix-dhcp-flag.json <<'JSON'
{
  "commands": [
    "$k = 'HKLM:\\SOFTWARE\\Microsoft\\ServerManager\\Roles\\12'",
    "if (Test-Path $k) { Set-ItemProperty -Path $k -Name ConfigurationState -Value 2 -Force; Write-Host \"cleared on $env:COMPUTERNAME\" } else { Write-Host 'DHCP role not installed here' }"
  ]
}
JSON

IDS=$(TF_WORKSPACE=$SETUP terraform -chdir=terraform output -json host_inventory \
  | jq -r 'to_entries[] | select(.value.role != "clt") | .value.instance_id')

aws ssm send-command --profile <profile> --region <region> \
  --document-name AWS-RunPowerShellScript \
  --instance-ids $IDS \
  --parameters file:///tmp/fix-dhcp-flag.json
```

## DHCP server not serving leases

An unauthorized DHCP server starts but refuses to hand out addresses. Check the
AD-side authorization list from any domain-joined host:

```powershell
Get-DhcpServerInDC
```

Every `srv` and `dc` host in the setup should appear. Authorization is performed
by the **bootstrap host** for the whole setup, not by each server for itself: SSM
runs as SYSTEM, and a member server's machine account has no rights on the
NetServices container in AD. So a missing entry means the bootstrap host's
`credential_setup` run is the one to look at, not the affected server's — that run
fails outright if any server is left unauthorized.

## IMDS unreachable after static IP

The networking step adds a route for `169.254.169.254`. Verify it exists:

```powershell
Get-NetRoute -DestinationPrefix '169.254.169.254/32'
```

## Terraform state lock error

If `make apply` or `make destroy` fails with "Error acquiring the state lock", a previous Terraform process may still be running:

```bash
# Check for running terraform processes
ps aux | grep terraform | grep -v grep

# Kill the stale process
kill -9 <PID>

# Retry
make apply
```

## Viewing SSM logs

SSM script output (Write-Host) does **not** appear in `terraform apply` output. Terraform only waits for Success/Failed. View logs via S3:

```bash
make logs PHASE=credential-setup HOST=naq-srv02          # latest run
make logs PHASE=credential-setup HOST=naq-srv02 RUN=all  # list all runs
make logs PHASE=credential-setup HOST=naq-srv02 RUN=3    # specific run
```

## Verification checklist

After `make apply` completes, verify from the agent client (`<prefix>-clt01`):

```powershell
# RSAT tools installed?
Get-WindowsFeature -Name RSAT-AD-PowerShell,RSAT-DNS-Server,RSAT-DHCP

# Domain joined?
(Get-WmiObject Win32_ComputerSystem).Domain  # should be corp.local

# CredSSP configured?
Get-WSManCredSSP  # should show delegation to DC IP

# Test CredSSP end-to-end
$cred = New-Object PSCredential('infoblox_agent@corp.local',
  (ConvertTo-SecureString 'YourServicePassword' -AsPlainText -Force))
Invoke-Command -ComputerName <DC_IP> -Credential $cred -Authentication Credssp `
  -ScriptBlock { "OK from $(hostname) as $(whoami)" }
```

Verify WMI on the server hosts: RDP into `<prefix>-srv01`/`<prefix>-srv02` → `wmimgmt.msc` → Properties → Security → `Root\Microsoft\Windows\DNS` (or `DHCP`). The service user and DNSAdmins should have **Enable Account**, **Execute Methods**, and **Remote Enable** checked.
