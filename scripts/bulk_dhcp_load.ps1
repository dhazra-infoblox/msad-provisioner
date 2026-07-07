<#
.SYNOPSIS
    Creates bulk DHCP scopes and optional static reservations for performance testing.

.DESCRIPTION
    Generates synthetic /24 DHCP scopes starting at a configurable base network.
    Optionally populates each scope with a fixed number of static reservations.
    Idempotent: skips scopes that already exist.

.PARAMETER ScopeCount
    Number of DHCP scopes to create. Default: 500.

.PARAMETER ReservationsPerScope
    Number of static reservations to add inside each scope. Default: 0 (none).

.PARAMETER BaseSecondOctet
    Second octet of the base network (10.<N>.0.0). Default: 20.
    Scopes cycle through third octets 1-254, then increment second octet.

.PARAMETER ScopeLeaseDurationHours
    Lease duration in hours for each scope. Default: 8.

.PARAMETER OutFile
    Path to write a summary CSV of created scopes. Default: C:\ProgramData\msad-agent\bulk_dhcp_results.csv.

.EXAMPLE
    # Create 500 scopes, no reservations
    .\bulk_dhcp_load.ps1 -ScopeCount 500

.EXAMPLE
    # Create 200 scopes with 10 reservations each
    .\bulk_dhcp_load.ps1 -ScopeCount 200 -ReservationsPerScope 10

.EXAMPLE
    # Dry run: show what would be created
    .\bulk_dhcp_load.ps1 -ScopeCount 100 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]    $ScopeCount            = 500,
    [int]    $ReservationsPerScope  = 0,
    [int]    $BaseSecondOctet       = 20,
    [int]    $ScopeLeaseDurationHours = 8,
    [string] $OutFile               = 'C:\ProgramData\msad-agent\bulk_dhcp_results.csv'
)

$ErrorActionPreference = 'Stop'

# ── Validate DHCP server role ──────────────────────────────────────────────────
if (-not (Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue | Where-Object Installed)) {
    Write-Warning "DHCP Server feature is not installed on this host. Proceeding anyway (may fail on scope cmdlets)."
}

# ── Prepare output directory ───────────────────────────────────────────────────
$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$leaseDuration = New-TimeSpan -Hours $ScopeLeaseDurationHours

$created    = 0
$skipped    = 0
$failed     = 0
$results    = [System.Collections.Generic.List[PSCustomObject]]::new()
$startTime  = Get-Date

Write-Host "=== Bulk DHCP Load: $ScopeCount scopes, $ReservationsPerScope reservations/scope ==="
Write-Host "Base network: 10.$BaseSecondOctet.1.0/24 → 10.$BaseSecondOctet.254.0/24 (wrapping second octet)"
Write-Host "Output CSV  : $OutFile"
Write-Host ""

for ($i = 0; $i -lt $ScopeCount; $i++) {
    # Calculate octets: third cycles 1-254, second increments
    $thirdOctet  = ($i % 254) + 1
    $secondExtra = [int]($i / 254)
    $second      = $BaseSecondOctet + $secondExtra

    if ($second -gt 254) {
        Write-Warning "Ran out of address space at scope $i (second octet $second > 254). Stopping."
        break
    }

    $network   = "10.$second.$thirdOctet.0"
    $startIp   = "10.$second.$thirdOctet.1"
    $endIp     = "10.$second.$thirdOctet.254"
    $mask      = "255.255.255.0"
    $scopeName = "PerfScope-$second-$thirdOctet"
    $scopeId   = $network

    try {
        # Idempotency: check if scope already exists
        $existing = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
        if ($existing) {
            $skipped++
            $results.Add([PSCustomObject]@{
                Index       = $i
                ScopeId     = $scopeId
                Network     = $network
                Status      = 'Skipped'
                Reservations = 0
            })
            if ($i % 50 -eq 0) { Write-Host "[$i/$ScopeCount] Skipping existing scope $scopeId..." }
            continue
        }

        if ($PSCmdlet.ShouldProcess($scopeId, "Add-DhcpServerv4Scope")) {
            Add-DhcpServerv4Scope `
                -Name          $scopeName `
                -StartRange    $startIp `
                -EndRange      $endIp `
                -SubnetMask    $mask `
                -LeaseDuration $leaseDuration `
                -State         Active
        }

        $resvCount = 0

        if ($ReservationsPerScope -gt 0 -and $PSCmdlet.ShouldProcess($scopeId, "Add reservations")) {
            # Add up to $ReservationsPerScope reservations (IPs .101 onwards to avoid pool conflict)
            $maxResv = [Math]::Min($ReservationsPerScope, 100)  # max 100 per /24 to stay safe
            for ($r = 0; $r -lt $maxResv; $r++) {
                $hostPart  = 101 + $r
                $resvIp    = "10.$second.$thirdOctet.$hostPart"
                # Generate a deterministic MAC: 02:perf:<second>:<third>:<hostpart>
                $macAddr   = "02:50:{0:X2}:{1:X2}:{2:X2}:{3:X2}" -f $second, $thirdOctet, $hostPart, ($i % 256)
                $resvName  = "Resv-$second-$thirdOctet-$hostPart"

                Add-DhcpServerv4Reservation `
                    -ScopeId      $scopeId `
                    -IPAddress    $resvIp `
                    -ClientId     $macAddr `
                    -Name         $resvName `
                    -Description  "PerfTest reservation"
                $resvCount++
            }
        }

        $created++
        $results.Add([PSCustomObject]@{
            Index        = $i
            ScopeId      = $scopeId
            Network      = $network
            Status       = 'Created'
            Reservations = $resvCount
        })

        if ($i % 50 -eq 0 -or $i -eq ($ScopeCount - 1)) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            Write-Host "[$i/$ScopeCount] Created $scopeId  (created=$created skipped=$skipped failed=$failed elapsed=${elapsed}s)"
        }
    }
    catch {
        $failed++
        $results.Add([PSCustomObject]@{
            Index        = $i
            ScopeId      = $scopeId
            Network      = $network
            Status       = "Failed: $_"
            Reservations = 0
        })
        Write-Warning "[$i] Failed to create scope $scopeId : $_"
    }
}

# ── Write CSV ──────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "=== Done ==="
Write-Host "Created : $created"
Write-Host "Skipped : $skipped  (already existed)"
Write-Host "Failed  : $failed"
$totalElapsed = ((Get-Date) - $startTime).TotalSeconds
Write-Host "Total time: ${totalElapsed}s"
Write-Host "Results CSV: $OutFile"
