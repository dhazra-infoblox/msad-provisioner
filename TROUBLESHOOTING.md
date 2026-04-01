# Troubleshooting

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
make logs PHASE=credential-setup HOST=dhcp02          # latest run
make logs PHASE=credential-setup HOST=dhcp02 RUN=all  # list all runs
make logs PHASE=credential-setup HOST=dhcp02 RUN=3    # specific run
```

## Verification checklist

After `make apply` completes, verify from the agent client (client01):

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

Verify WMI on DHCP servers: RDP into dhcp01/dhcp02 → `wmimgmt.msc` → Properties → Security → `Root\Microsoft\Windows\DNS` (or `DHCP`). The service user and DNSAdmins should have **Enable Account**, **Execute Methods**, and **Remote Enable** checked.
