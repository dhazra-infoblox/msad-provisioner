<#
.SYNOPSIS
    Checks (and optionally fixes) Infoblox DHCP management prerequisites on Windows servers.

.DESCRIPTION
    Validates the prerequisites documented at:
    https://docs.infoblox.com/space/UniversalAssetInsights/1835925677/Prerequisites+for+DHCP

    Supports three roles:
      - DomainController : DC that will be managed by the Infoblox agent
      - DhcpServer       : Windows DHCP server managed by the Infoblox agent
      - AgentClient      : Windows member server running the Universal DDI Agent

    When run with -Fix, the script will attempt to remediate any failing checks.

.PARAMETER Role
    The role of this machine: DomainController, DhcpServer, or AgentClient.

.PARAMETER TargetServers
    Comma-separated IPs of the DC(s) and DHCP server(s) to manage. Required for AgentClient role.

.PARAMETER DomainFqdn
    The Active Directory domain FQDN (e.g. corp.local). Required for AgentClient role.

.PARAMETER ServiceUser
    The AD service account used by the Infoblox agent (e.g. infoblox_agent).
    Required for DomainController and DhcpServer role checks.

.PARAMETER Fix
    When specified, attempt to automatically remediate any failing checks.

.EXAMPLE
    # Check a Domain Controller (read-only)
    .\check-prerequisites.ps1 -Role DomainController -ServiceUser infoblox_agent

    # Check and fix a DHCP server
    .\check-prerequisites.ps1 -Role DhcpServer -ServiceUser infoblox_agent -Fix

    # Check and fix the agent client
    .\check-prerequisites.ps1 -Role AgentClient -TargetServers "10.0.1.10,10.0.1.20" -DomainFqdn corp.local -Fix
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DomainController', 'DhcpServer', 'AgentClient')]
    [string]$Role,

    [Parameter()]
    [string]$TargetServers,

    [Parameter()]
    [string]$DomainFqdn,

    [Parameter()]
    [string]$ServiceUser,

    [Parameter()]
    [switch]$Fix
)

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$script:PassCount = 0
$script:FailCount = 0
$script:FixedCount = 0
$script:Errors = @()

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    if ($Passed) {
        $script:PassCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:Errors += "$Name : $Detail"
    }
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
}

function Write-Fixed {
    param([string]$Name)
    $script:FixedCount++
    Write-Host "  [FIXED] $Name" -ForegroundColor Yellow
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Validate parameters
# ---------------------------------------------------------------------------
if ($Role -eq 'AgentClient') {
    if (-not $TargetServers) { throw "AgentClient role requires -TargetServers (comma-separated IPs of DCs and DHCP servers)" }
    if (-not $DomainFqdn)    { throw "AgentClient role requires -DomainFqdn (e.g. corp.local)" }
}
if (($Role -eq 'DomainController' -or $Role -eq 'DhcpServer') -and -not $ServiceUser) {
    throw "$Role role requires -ServiceUser (e.g. infoblox_agent)"
}

# ---------------------------------------------------------------------------
# Common: WinRM Service
# ---------------------------------------------------------------------------
function Test-WinRMService {
    Write-Section "WinRM Service"

    $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    $running = $svc -and $svc.Status -eq 'Running'
    Write-Check "WinRM service is running" $running "Status: $($svc.Status)"

    if (-not $running -and $Fix) {
        Set-Service -Name WinRM -StartupType Automatic
        Start-Service -Name WinRM
        Write-Fixed "WinRM service started and set to Automatic"
    }

    # Check PSRemoting listener
    $listener = $null
    try { $listener = Get-WSManInstance -ResourceURI winrm/config/listener -Enumerate 2>$null | Where-Object { $_.Transport -eq 'HTTP' } } catch {}
    $hasListener = $null -ne $listener
    Write-Check "WinRM HTTP listener configured" $hasListener

    if (-not $hasListener -and $Fix) {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
        Write-Fixed "Enable-PSRemoting executed"
    }
}

# ---------------------------------------------------------------------------
# DC / DHCP Server: CredSSP Server Role
# ---------------------------------------------------------------------------
function Test-CredSSPServer {
    Write-Section "CredSSP Server Role"

    $credSsp = $false
    try {
        $out = Get-WSManCredSSP 2>$null
        $credSsp = ($out | Out-String) -match 'This computer is configured to receive credentials'
    } catch {}
    Write-Check "CredSSP server role enabled" $credSsp

    if (-not $credSsp -and $Fix) {
        Enable-WSManCredSSP -Role Server -Force
        Write-Fixed "CredSSP server role enabled"
    }
}

# ---------------------------------------------------------------------------
# DC / DHCP Server: WMI Permissions on DHCP namespace
# ---------------------------------------------------------------------------
function Test-WmiDhcpPermissions {
    param([string]$Account)

    Write-Section "WMI Permissions (Root\Microsoft\Windows\DHCP)"

    $ns = 'Root\Microsoft\Windows\DHCP'
    $hasDhcpNs = $false
    try {
        $null = [wmiclass]"\\localhost\$($ns):__SystemSecurity"
        $hasDhcpNs = $true
    } catch {}

    if (-not $hasDhcpNs) {
        Write-Check "DHCP WMI namespace exists" $false "Namespace $ns not found — is DHCP installed?"
        return
    }
    Write-Check "DHCP WMI namespace exists" $true

    # Resolve the account to check — use DOMAIN\user format
    $domainPrefix = ($env:USERDOMAIN)
    if (-not $domainPrefix) { $domainPrefix = (Get-WmiObject Win32_ComputerSystem).Domain.Split('.')[0].ToUpper() }
    $fullAccount = if ($Account -match '\\') { $Account } else { "$domainPrefix\$Account" }

    $sec = ([wmiclass]"\\localhost\$($ns):__SystemSecurity")
    $sd = $sec.GetSecurityDescriptor().Descriptor

    $requiredMask = 0x23  # Execute Methods (0x01) + Remote Enable (0x20) + Enable Account (0x02) = 0x23
    $found = $false
    foreach ($ace in $sd.DACL) {
        try {
            $name = (New-Object System.Security.Principal.SecurityIdentifier($ace.Trustee.SIDString)).Translate(
                [System.Security.Principal.NTAccount]).Value
            if ($name -eq $fullAccount) {
                if (($ace.AccessMask -band $requiredMask) -eq $requiredMask) {
                    $found = $true
                }
            }
        } catch {}
    }
    Write-Check "'$fullAccount' has Execute Methods + Remote Enable on DHCP WMI" $found

    if (-not $found -and $Fix) {
        try {
            $sid = (New-Object System.Security.Principal.NTAccount($fullAccount)).Translate(
                [System.Security.Principal.SecurityIdentifier])
            $ace = ([wmiclass]'Win32_ACE').CreateInstance()
            $trustee = ([wmiclass]'Win32_Trustee').CreateInstance()
            $trustee.SIDString = $sid.Value
            $ace.AccessMask = $requiredMask
            $ace.AceType = 0  # Allow
            $ace.AceFlags = 0
            $ace.Trustee = $trustee
            $sd.DACL += $ace
            $sec.SetSecurityDescriptor($sd) | Out-Null
            Write-Fixed "'$fullAccount' granted Execute Methods + Remote Enable on $ns"
        } catch {
            Write-Host "  [ERROR] Could not set WMI permissions for '$fullAccount': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------------------
# DC: AD Service User & Group Membership
# ---------------------------------------------------------------------------
function Test-ADServiceUser {
    param([string]$User)

    Write-Section "AD Service User ($User)"

    # Check AD module available
    $adModule = Get-Module -ListAvailable -Name ActiveDirectory
    if (-not $adModule) {
        Write-Check "ActiveDirectory PowerShell module available" $false "Install RSAT-AD-PowerShell"
        return
    }
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    # Check user exists
    $adUser = $null
    try { $adUser = Get-ADUser -Identity $User -Properties MemberOf -ErrorAction Stop } catch {}
    Write-Check "AD user '$User' exists" ($null -ne $adUser)

    if (-not $adUser) {
        Write-Host "         Cannot check group membership without the user existing." -ForegroundColor Gray
        return
    }

    # Check user is enabled
    Write-Check "AD user '$User' is enabled" $adUser.Enabled

    # Required groups
    $requiredGroups = @('DHCP Administrators', 'Remote Management Users')
    $memberGroups = $adUser.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }

    foreach ($group in $requiredGroups) {
        $inGroup = $memberGroups -contains $group
        Write-Check "User '$User' is member of '$group'" $inGroup

        if (-not $inGroup -and $Fix) {
            try {
                Add-ADGroupMember -Identity $group -Members $User -ErrorAction Stop
                Write-Fixed "Added '$User' to '$group'"
            } catch {
                Write-Host "  [ERROR] Could not add to group: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Agent Client: CredSSP Client Role
# ---------------------------------------------------------------------------
function Test-CredSSPClient {
    param([string[]]$Targets)

    Write-Section "CredSSP Client Role"

    $credSspOut = ''
    try { $credSspOut = (Get-WSManCredSSP 2>$null) | Out-String } catch {}

    $allDelegated = $true
    foreach ($ip in $Targets) {
        $delegated = $credSspOut -match [regex]::Escape("wsman/$ip")
        Write-Check "CredSSP client delegates to $ip" $delegated
        if (-not $delegated) { $allDelegated = $false }
    }

    if (-not $allDelegated -and $Fix) {
        foreach ($ip in $Targets) {
            if (-not ($credSspOut -match [regex]::Escape("wsman/$ip"))) {
                Enable-WSManCredSSP -Role Client -DelegateComputer $ip -Force
                Write-Fixed "CredSSP client delegation added for $ip"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Agent Client: TrustedHosts
# ---------------------------------------------------------------------------
function Test-TrustedHosts {
    param([string[]]$Targets)

    Write-Section "TrustedHosts"

    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
    $currentList = if ($current) { $current.Split(',') | ForEach-Object { $_.Trim() } } else { @() }

    foreach ($ip in $Targets) {
        $present = $currentList -contains $ip
        Write-Check "TrustedHosts contains $ip" $present
    }

    $missing = $Targets | Where-Object { $_ -notin $currentList }
    if ($missing -and $Fix) {
        $newList = (($currentList + $missing) | Select-Object -Unique) -join ','
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newList -Force
        Write-Fixed "TrustedHosts updated to: $newList"
    }
}

# ---------------------------------------------------------------------------
# Agent Client: GPO CredSSP Delegation (Registry)
# ---------------------------------------------------------------------------
function Test-GPOCredSSPDelegation {
    param([string[]]$Targets, [string]$Domain)

    Write-Section "GPO: CredSSP Delegation (Allow Fresh Credentials)"

    $regBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
    $polPath = "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"

    # Check AllowFreshCredentials policy is enabled
    $freshEnabled = $false
    try {
        $val = Get-ItemProperty -Path $regBase -Name 'AllowFreshCredentials' -ErrorAction Stop
        $freshEnabled = $val.AllowFreshCredentials -eq 1
    } catch {}
    Write-Check "AllowFreshCredentials policy enabled" $freshEnabled

    # Check each target has WSMAN entry
    $freshPath = "$regBase\AllowFreshCredentials"
    $freshEntries = @()
    try {
        $props = Get-ItemProperty -Path $freshPath -ErrorAction Stop
        $freshEntries = $props.PSObject.Properties | Where-Object { $_.Value -match '^WSMAN/' } | ForEach-Object { $_.Value }
    } catch {}

    foreach ($ip in $Targets) {
        $hasEntry = $freshEntries -contains "WSMAN/$ip"
        Write-Check "AllowFreshCredentials has WSMAN/$ip" $hasEntry
    }

    # Check WSMAN/*.<domain> wildcard
    $wildcard = "WSMAN/*.$Domain"
    $hasWildcard = $freshEntries -contains $wildcard
    Write-Check "AllowFreshCredentials has $wildcard" $hasWildcard

    # Check AllowFreshCredentialsWhenNTLMOnly
    Write-Section "GPO: CredSSP Delegation (Allow Fresh Credentials NTLM-Only)"

    $ntlmEnabled = $false
    try {
        $val = Get-ItemProperty -Path $regBase -Name 'AllowFreshCredentialsWhenNTLMOnly' -ErrorAction Stop
        $ntlmEnabled = $val.AllowFreshCredentialsWhenNTLMOnly -eq 1
    } catch {}
    Write-Check "AllowFreshCredentialsWhenNTLMOnly policy enabled" $ntlmEnabled

    $ntlmPath = "$regBase\AllowFreshCredentialsWhenNTLMOnly"
    $ntlmEntries = @()
    try {
        $props = Get-ItemProperty -Path $ntlmPath -ErrorAction Stop
        $ntlmEntries = $props.PSObject.Properties | Where-Object { $_.Value -match '^WSMAN/' } | ForEach-Object { $_.Value }
    } catch {}

    foreach ($ip in $Targets) {
        $hasEntry = $ntlmEntries -contains "WSMAN/$ip"
        Write-Check "AllowFreshCredentialsWhenNTLMOnly has WSMAN/$ip" $hasEntry
    }

    $hasNtlmWildcard = $ntlmEntries -contains $wildcard
    Write-Check "AllowFreshCredentialsWhenNTLMOnly has $wildcard" $hasNtlmWildcard

    # --- Fix via PolicyFileEditor or direct registry ---
    if ($Fix) {
        $needsFix = (-not $freshEnabled) -or (-not $ntlmEnabled) -or
                    ($Targets | Where-Object { "WSMAN/$_" -notin $freshEntries }) -or
                    ($Targets | Where-Object { "WSMAN/$_" -notin $ntlmEntries }) -or
                    (-not $hasWildcard) -or (-not $hasNtlmWildcard)

        if ($needsFix) {
            # Try PolicyFileEditor first (preferred, writes Registry.pol)
            $hasPFE = $null -ne (Get-Module -ListAvailable -Name PolicyFileEditor)
            if (-not $hasPFE) {
                Write-Host "  Installing PolicyFileEditor module..." -ForegroundColor Yellow
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                    Install-Module -Name PolicyFileEditor -Force -Scope AllUsers | Out-Null
                    $hasPFE = $true
                } catch {
                    Write-Host "  [WARN] Could not install PolicyFileEditor, falling back to direct registry" -ForegroundColor Yellow
                }
            }

            if ($hasPFE) {
                Import-Module PolicyFileEditor
                $regPath = 'SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'

                # AllowFreshCredentials
                Set-PolicyFileEntry -Path $polPath -Key $regPath -ValueName 'AllowFreshCredentials' -Data 1 -Type DWord
                Set-PolicyFileEntry -Path $polPath -Key $regPath -ValueName 'ConcatenateDefaults_AllowFresh' -Data 1 -Type DWord
                $i = 1
                foreach ($ip in $Targets) {
                    Set-PolicyFileEntry -Path $polPath -Key "$regPath\AllowFreshCredentials" -ValueName "$i" -Data "WSMAN/$ip" -Type String
                    $i++
                }
                Set-PolicyFileEntry -Path $polPath -Key "$regPath\AllowFreshCredentials" -ValueName "$i" -Data $wildcard -Type String

                # AllowFreshCredentialsWhenNTLMOnly
                Set-PolicyFileEntry -Path $polPath -Key $regPath -ValueName 'AllowFreshCredentialsWhenNTLMOnly' -Data 1 -Type DWord
                Set-PolicyFileEntry -Path $polPath -Key $regPath -ValueName 'ConcatenateDefaults_AllowFreshNTLMOnly' -Data 1 -Type DWord
                $i = 1
                foreach ($ip in $Targets) {
                    Set-PolicyFileEntry -Path $polPath -Key "$regPath\AllowFreshCredentialsWhenNTLMOnly" -ValueName "$i" -Data "WSMAN/$ip" -Type String
                    $i++
                }
                Set-PolicyFileEntry -Path $polPath -Key "$regPath\AllowFreshCredentialsWhenNTLMOnly" -ValueName "$i" -Data $wildcard -Type String

                Write-Fixed "GPO Registry.pol updated with CredSSP delegation entries"
            } else {
                # Direct registry fallback
                if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }
                Set-ItemProperty -Path $regBase -Name 'AllowFreshCredentials' -Value 1 -Type DWord
                Set-ItemProperty -Path $regBase -Name 'ConcatenateDefaults_AllowFresh' -Value 1 -Type DWord
                $freshSubPath = "$regBase\AllowFreshCredentials"
                if (-not (Test-Path $freshSubPath)) { New-Item -Path $freshSubPath -Force | Out-Null }
                $i = 1
                foreach ($ip in $Targets) { Set-ItemProperty -Path $freshSubPath -Name "$i" -Value "WSMAN/$ip" -Type String; $i++ }
                Set-ItemProperty -Path $freshSubPath -Name "$i" -Value $wildcard -Type String

                Set-ItemProperty -Path $regBase -Name 'AllowFreshCredentialsWhenNTLMOnly' -Value 1 -Type DWord
                Set-ItemProperty -Path $regBase -Name 'ConcatenateDefaults_AllowFreshNTLMOnly' -Value 1 -Type DWord
                $ntlmSubPath = "$regBase\AllowFreshCredentialsWhenNTLMOnly"
                if (-not (Test-Path $ntlmSubPath)) { New-Item -Path $ntlmSubPath -Force | Out-Null }
                $i = 1
                foreach ($ip in $Targets) { Set-ItemProperty -Path $ntlmSubPath -Name "$i" -Value "WSMAN/$ip" -Type String; $i++ }
                Set-ItemProperty -Path $ntlmSubPath -Name "$i" -Value $wildcard -Type String

                Write-Fixed "GPO registry entries set directly (Registry.pol not available)"
            }

            # Apply group policy
            & gpupdate /force 2>&1 | Out-Null
            Write-Fixed "Group policy refreshed (gpupdate /force)"
        }
    }
}

# ---------------------------------------------------------------------------
# Agent Client: Network connectivity to targets
# ---------------------------------------------------------------------------
function Test-NetworkConnectivity {
    param([string[]]$Targets)

    Write-Section "Network Connectivity (WinRM port 5985)"

    foreach ($ip in $Targets) {
        $reachable = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $result = $tcp.BeginConnect($ip, 5985, $null, $null)
            $waited = $result.AsyncWaitHandle.WaitOne(3000, $false)
            if ($waited -and $tcp.Connected) { $reachable = $true }
            $tcp.Close()
        } catch {}
        Write-Check "TCP connection to ${ip}:5985" $reachable $(if (-not $reachable) { "Cannot connect — check WinRM on target and firewall rules" } else { "" })
    }
}

# ---------------------------------------------------------------------------
# Agent Client: RSAT Features
# ---------------------------------------------------------------------------
function Test-RSATFeatures {
    Write-Section "RSAT Features (Agent Client)"

    $requiredFeatures = @('RSAT-AD-PowerShell', 'RSAT-DNS-Server', 'RSAT-DHCP')
    foreach ($feature in $requiredFeatures) {
        $installed = $false
        try {
            $f = Get-WindowsFeature -Name $feature -ErrorAction Stop
            $installed = $f.Installed
        } catch {}
        Write-Check "$feature installed" $installed

        if (-not $installed -and $Fix) {
            try {
                Install-WindowsFeature -Name $feature -ErrorAction Stop | Out-Null
                Write-Fixed "$feature installed"
            } catch {
                Write-Host "  [ERROR] Could not install ${feature}: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# ---------------------------------------------------------------------------
# DC/DHCP: Firewall rules for WinRM
# ---------------------------------------------------------------------------
function Test-WinRMFirewall {
    Write-Section "Firewall: WinRM Inbound"

    $rules = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue
    $enabled = $rules | Where-Object { $_.Enabled -eq 'True' }
    $hasRule = $null -ne $enabled -and ($enabled | Measure-Object).Count -gt 0
    Write-Check "WinRM HTTP inbound firewall rule enabled" $hasRule

    if (-not $hasRule -and $Fix) {
        try {
            Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress Any -Enabled True -ErrorAction Stop
            Write-Fixed "WinRM firewall rule enabled for all remote addresses"
        } catch {
            try {
                Enable-PSRemoting -Force -SkipNetworkProfileCheck
                Write-Fixed "Enable-PSRemoting re-run to create firewall rules"
            } catch {
                Write-Host "  [ERROR] Could not configure firewall: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# ---------------------------------------------------------------------------
# End-to-end: PSRemoting test from agent client to targets
# ---------------------------------------------------------------------------
function Test-PSRemotingConnectivity {
    param([string[]]$Targets)

    Write-Section "PSRemoting Connectivity (WinRM + Auth)"

    foreach ($ip in $Targets) {
        $reachable = $false
        try {
            $reachable = Test-WSMan -ComputerName $ip -ErrorAction Stop
            $reachable = $true
        } catch {
            $reachable = $false
        }
        Write-Check "WSMan responds on $ip" $reachable $(if (-not $reachable) { "WinRM not reachable — ensure Enable-PSRemoting and CredSSP Server are configured on that host" } else { "" })
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor White
Write-Host " Infoblox DHCP Prerequisites Checker" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor White
Write-Host " Host      : $env:COMPUTERNAME"
Write-Host " Role      : $Role"
Write-Host " Fix mode  : $(if ($Fix) { 'ENABLED' } else { 'Disabled (read-only)' })"
Write-Host " Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "==========================================" -ForegroundColor White

switch ($Role) {
    'DomainController' {
        Test-WinRMService
        Test-WinRMFirewall
        Test-CredSSPServer
        Test-WmiDhcpPermissions -Account $ServiceUser
        Test-ADServiceUser -User $ServiceUser
    }
    'DhcpServer' {
        Test-WinRMService
        Test-WinRMFirewall
        Test-CredSSPServer
        Test-WmiDhcpPermissions -Account $ServiceUser
    }
    'AgentClient' {
        $targets = $TargetServers.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        Test-WinRMService
        Test-RSATFeatures
        Test-NetworkConnectivity -Targets $targets
        Test-PSRemotingConnectivity -Targets $targets
        Test-CredSSPClient -Targets $targets
        Test-TrustedHosts -Targets $targets
        Test-GPOCredSSPDelegation -Targets $targets -Domain $DomainFqdn
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor White
Write-Host " SUMMARY" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor White
Write-Host "  Passed : $script:PassCount" -ForegroundColor Green
Write-Host "  Failed : $script:FailCount" -ForegroundColor $(if ($script:FailCount -gt 0) { 'Red' } else { 'Green' })
if ($Fix) {
    Write-Host "  Fixed  : $script:FixedCount" -ForegroundColor Yellow
}
Write-Host ""

if ($script:Errors.Count -gt 0 -and -not $Fix) {
    Write-Host "  Failing checks:" -ForegroundColor Red
    foreach ($err in $script:Errors) {
        Write-Host "    - $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Tip: Re-run with -Fix to attempt automatic remediation." -ForegroundColor Yellow
    Write-Host ""
}

if ($script:FailCount -gt 0) {
    exit 1
} else {
    Write-Host "  All prerequisites met." -ForegroundColor Green
    Write-Host ""
    exit 0
}
