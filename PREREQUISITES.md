# Prerequisite Testing

Scripts for validating and fixing Infoblox DHCP prerequisites on Windows VMs, executed remotely via AWS SSM.

## Scripts

| Script | Purpose | Customer-safe? |
|--------|---------|---------------|
| `check-prerequisites.ps1` | Read-only checker | Yes |
| `check-prerequisites.ps1 -Fix` | Check + auto-fix | Internal only |

## Make Targets

```bash
make check-prereqs HOST=name     # read-only check
make fix-prereqs HOST=name       # check + fix (-Fix flag)
```

Role, target IPs, domain, and service user are auto-resolved from Terraform output and `environment.yml`.

## Breakable Items by Role

These can be broken ad-hoc via SSM for testing, then fixed with `make fix-prereqs`.

| Item | DC | DHCP | Agent | What it does | PowerShell to break |
|------|:--:|:----:|:-----:|--------------|---------------------|
| WinRM | x | x | x | Stops WinRM service | `Stop-Service WinRM -Force; Set-Service -Name WinRM -StartupType Manual` |
| Firewall | x | x | | Disables WinRM inbound rules | `Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' \| Set-NetFirewallRule -Enabled False` |
| CredSSP Server | x | x | | Disables CredSSP server role | `Disable-WSManCredSSP -Role Server` |
| WMI Permissions | x | x | | Removes service user ACE from DHCP WMI namespace | See below |
| AD Group Membership | x | | | Removes service user from DHCP Admins + Remote Mgmt Users | See below |
| CredSSP Client | | | x | Disables CredSSP client delegation | `Disable-WSManCredSSP -Role Client` |
| TrustedHosts | | | x | Clears TrustedHosts list | `Set-Item WSMan:\localhost\Client\TrustedHosts -Value '' -Force` |
| GPO Delegation | | | x | Removes CredentialsDelegation registry keys | See below |

### WMI Permissions (DC/DHCP)

```powershell
$ns = 'Root\Microsoft\Windows\DHCP'
$dp = $env:USERDOMAIN
if (-not $dp) { $dp = (Get-WmiObject Win32_ComputerSystem).Domain.Split('.')[0].ToUpper() }
$fa = "$dp\SERVICE_USER"
$sec = ([wmiclass]"\\localhost\$($ns):__SystemSecurity")
$sd = $sec.GetSecurityDescriptor().Descriptor
$newDacl = @()
foreach ($ace in $sd.DACL) {
    $name = ''
    try { $name = (New-Object System.Security.Principal.SecurityIdentifier($ace.Trustee.SIDString)).Translate([System.Security.Principal.NTAccount]).Value } catch {}
    if ($name -ne $fa) { $newDacl += $ace }
}
$sd.DACL = $newDacl
$sec.SetSecurityDescriptor($sd) | Out-Null
```

Replace `SERVICE_USER` with the actual service account (e.g. `infoblox_agent`).

### AD Group Membership (DC only)

```powershell
Import-Module ActiveDirectory
Remove-ADGroupMember -Identity 'DHCP Administrators' -Members 'SERVICE_USER' -Confirm:$false
Remove-ADGroupMember -Identity 'Remote Management Users' -Members 'SERVICE_USER' -Confirm:$false
```

### GPO Delegation (AgentClient only)

```powershell
$regBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
if (Test-Path $regBase) { Remove-Item -Path $regBase -Recurse -Force }
& gpupdate /force 2>&1 | Out-Null
```

## Test Workflow

```bash
# 1. Break something ad-hoc via SSM (or ask the agent to do it)
# 2. Verify failures
make check-prereqs HOST=dhcp01
# 3. Fix
make fix-prereqs HOST=dhcp01
# 4. Confirm all green
make check-prereqs HOST=dhcp01
```

## Files

| File | Description |
|------|-------------|
| `scripts/check-prerequisites.ps1` | Read-only checker with `-Fix` mode |
| `scripts/run_prereqs_via_ssm.sh` | Sends PowerShell scripts to VMs via SSM send-command |
