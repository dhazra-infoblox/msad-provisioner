 <#
.SYNOPSIS
    Tails Microsoft DHCP audit log files from one or more DHCP servers in real time
    using PowerShell Remoting (WinRM + Kerberos).

.DESCRIPTION
    Tail-DhcpAuditLog.ps1 connects to N Microsoft DHCP servers in parallel, discovers
    the current audit log path via Get-DhcpServerAuditLog, seeks to the last known
    byte offset (or end-of-file on first run), and polls for new lease events at a
    configurable cadence.

    Each parsed event is emitted to the pipeline as a PSCustomObject AND optionally
    appended to a local file as compact JSON (one event per line / JSON Lines format).

    A state file persists per-server (filename, byte offset) so that a restart catches
    up to events missed while the script was not running — targeting < 5 minutes of
    backlog without data loss.

    Parallelism: one Start-ThreadJob per server.  ThreadJob keeps all state in the
    calling process and avoids the overhead of child processes.  Requires the
    ThreadJob module (built into PowerShell 7+; install via
    Install-Module ThreadJob on Windows PowerShell 5.1).

    Auth: Kerberos via -Credential or the caller's current identity (if the machine
    is already domain-joined and has a valid TGT).

    File open mode: [System.IO.File]::Open with FileShare::ReadWrite so the script
    can read while the DHCP service holds an exclusive-write lock on the log file.

.PARAMETER ComputerName
    One or more DHCP server FQDNs or NetBIOS names to monitor.

.PARAMETER Credential
    PSCredential for WinRM authentication (Kerberos).  Omit to use the current
    thread identity (works on domain-joined machines with a valid Kerberos TGT).

.PARAMETER PollSeconds
    Seconds between reads on each server.  Default 3.  Keep <= 10 to satisfy the
    HLD latency target of < 60 seconds end-to-end.

.PARAMETER OutputPath
    Optional path to a local file.  Each event is appended as a single compact
    JSON line (JSON Lines / NDJSON).  The file is created if it does not exist.

.PARAMETER StateFile
    Path to a JSON file that persists per-server tail state (current filename and
    byte offset).  Required for the < 5-minute backlog / no-data-loss restart
    guarantee.  Created on first run; updated after every successful poll.

.PARAMETER EventCodes
    Optional array of integer DHCP event codes to pass through.  Default: all
    standard codes (10-17, 30-32).  Supply e.g. -EventCodes 10,11 to see only
    Assign and Renew events.

.EXAMPLE
    # Monitor two servers using the current Kerberos identity, print to console
    .\Tail-DhcpAuditLog.ps1 -ComputerName "dhcp01.corp.local","dhcp02.corp.local" `
        -StateFile "C:\Logs\dhcp-tail-state.json"

.EXAMPLE
    # Explicit service-account credential, write JSON Lines to disk
    $cred = Get-Credential "b1ddimigrate\infoblox_agent"
    .\Tail-DhcpAuditLog.ps1 `
        -ComputerName "B1DMI-DHCP02.b1ddimigrate.local" `
        -Credential $cred `
        -PollSeconds 3 `
        -OutputPath  "C:\Logs\dhcp-events.jsonl" `
        -StateFile   "C:\Logs\dhcp-tail-state.json" `
        -EventCodes  10,11,12

.NOTES
    Requires:
      - PowerShell 5.1+ (WS2016+) or PowerShell 7+
      - ThreadJob module  (built-in on PS7; Install-Module ThreadJob on PS5)
      - WinRM enabled on each DHCP server (Enable-PSRemoting)
      - The running identity must have Read access to C:\Windows\debug\dhcplog\
        on each server (BUILTIN\Users already has ReadAndExecute there by default)
      - DHCP Server role and the DhcpServer PowerShell module on each server
        (the module is installed automatically with the DHCP Server role)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]] $ComputerName = @(
        'B1DMI-DHCP02.b1ddimigrate.local',
        'B1DMI-DHCP01.b1ddimigrate.local'
    ),

    [Parameter()]
    [PSCredential] $Credential,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int] $PollSeconds = 3,

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [string] $StateFile = 'C:\Logs\dhcp-tail-state.json',

    [Parameter()]
    [int[]] $EventCodes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Standard DHCP audit event-code names (codes outside this table are emitted
# with EventName = "Unknown").
$script:EventCodeNames = @{
    10 = 'Assign'
    11 = 'Renew'
    12 = 'Release'
    13 = 'Expire'
    14 = 'Delete'
    15 = 'NACK'
    16 = 'Decline'
    17 = 'ExpiredBelowThreshold'
    30 = 'DnsUpdateRequest'
    31 = 'DnsUpdateFailed'
    32 = 'DnsUpdateSuccess'
}

# Default filter: all well-known codes; overridden by -EventCodes.
$script:FilterCodes = if ($EventCodes -and $EventCodes.Count -gt 0) {
    $EventCodes
} else {
    $script:EventCodeNames.Keys
}

# Day-of-week abbreviations that the DHCP service uses in log filenames.
# .NET DayOfWeek enum ordinals 0-6 map to Sun-Sat — these match the DHCP
# service's own naming convention.
$script:DayAbbreviations = @('Sun','Mon','Tue','Wed','Thu','Fri','Sat')

# Maximum reconnect back-off (seconds).
$script:MaxBackoffSeconds = 60

# ---------------------------------------------------------------------------
# Shared output queue — thread-safe.
# Jobs write PSCustomObjects here; the main loop dequeues and emits them.
# ---------------------------------------------------------------------------
$script:OutputQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

# ---------------------------------------------------------------------------
# Helper: load / save state file
# ---------------------------------------------------------------------------
function Read-StateFile {
    param([string] $Path)
    # Returns a hashtable keyed by lowercased server name:
    #   { "server.fqdn" = @{ FileName = "DhcpSrvLog-Mon.log"; Offset = 12345 } }
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Raw -LiteralPath $Path
            $obj = $raw | ConvertFrom-Json
            $ht  = @{}
            foreach ($prop in $obj.PSObject.Properties) {
                $ht[$prop.Name] = @{
                    FileName = $prop.Value.FileName
                    Offset   = [long] $prop.Value.Offset
                }
            }
            return $ht
        } catch {
            Write-Warning "State file '$Path' is corrupt or unreadable — starting fresh. Error: $_"
            return @{}
        }
    }
    return @{}
}

function Save-StateFile {
    param(
        [string]    $Path,
        [hashtable] $State
    )
    # Atomic write: write to a .tmp file then rename, so a crash mid-write
    # never corrupts the last good state.
    $tmp = "$Path.tmp"
    $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------------------
# The remote script block executed on each DHCP server via Invoke-Command.
#
# Design decision: this block returns raw CSV strings over the remoting
# pipeline rather than parsed objects.  This keeps the remote footprint
# minimal (no custom classes, no DhcpServer module cmdlets beyond log
# discovery) and lets the local process do all parsing, filtering, and
# serialisation.  The final element returned is always a sentinel string
# "@OFFSET:<n>" carrying the new stream position back to the caller.
# ---------------------------------------------------------------------------
$script:RemoteReadBlock = {
    param(
        [string] $LogDirectory,
        [string] $CurrentFile,
        [long]   $SeekOffset
    )

    $fullPath = Join-Path $LogDirectory $CurrentFile

    # FileShare::ReadWrite | FileShare::Delete:
    #   ReadWrite  — allows reading while DHCP holds its exclusive-write lock
    #   Delete     — prevents a stale handle if DHCP truncates/replaces the
    #                file on day-of-week rollover before we close it
    $shareMode = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream    = $null
    $reader    = $null

    try {
        $stream = [System.IO.File]::Open(
            $fullPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $shareMode
        )
        $reader = [System.IO.StreamReader]::new(
            $stream,
            [System.Text.Encoding]::UTF8,
            $true   # detectEncodingFromByteOrderMarks
        )

        if ($SeekOffset -eq [long]::MaxValue) {
            # First-run sentinel: seek to current EOF so we stream only
            # new events from this point forward (avoids replaying hours
            # of history on startup).
            [void] $stream.Seek(0, [System.IO.SeekOrigin]::End)
        } elseif ($SeekOffset -gt $stream.Length) {
            # File shrank (DHCP rewrote same weekday file) — start over.
            [void] $stream.Seek(0, [System.IO.SeekOrigin]::Begin)
        } elseif ($SeekOffset -gt 0) {
            [void] $stream.Seek($SeekOffset, [System.IO.SeekOrigin]::Begin)
            # Discard a potential partial line at the seek boundary.
            # ReadLine advances past it cleanly.
        }
        # SeekOffset == 0: read from beginning (day rollover or explicit replay)

        $lines = [System.Collections.Generic.List[string]]::new()
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($null -ne $line) { $lines.Add($line) }
        }

        $lines.Add("@OFFSET:$($stream.Position)")
        $lines   # return to caller via pipeline
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# Per-server tail worker — runs inside Start-ThreadJob.
#
# ThreadJob was chosen over Invoke-Command -AsJob because:
#  - All state lives in the same process (shared ConcurrentQueue, no
#    serialisation/deserialisation roundtrip for every poll).
#  - No child processes — lower overhead for N servers running at once.
#  - Works on PS 5.1 with Install-Module ThreadJob and natively on PS 7+.
# ---------------------------------------------------------------------------
$script:ServerWorker = {
    param(
        [string]       $Server,
        [PSCredential] $Credential,
        [int]          $PollSeconds,
        [hashtable]    $InitialState,
        [System.Collections.Concurrent.ConcurrentQueue[object]] $Queue,
        [string[]]     $DayAbbreviations,
        [hashtable]    $EventCodeNames,
        [int[]]        $FilterCodes,
        [scriptblock]  $RemoteReadBlock,
        [int]          $MaxBackoff
    )

    # ------------------------------------------------------------------
    # Local helpers (must be redefined inside the job runspace — the
    # outer scope's functions are not inherited by ThreadJob).
    # ------------------------------------------------------------------

    function Get-DayAbbrev ([datetime] $dt) {
        return $DayAbbreviations[[int] $dt.DayOfWeek]
    }

    function Parse-DhcpLine ([string] $Line, [string] $Srv) {
        if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

        $parts   = $Line -split ',', -1
        $codeStr = $parts[0].Trim()
        $code    = 0

        # Skip header/preamble: first field must be a plain integer.
        if (-not [int]::TryParse($codeStr, [ref] $code)) { return $null }

        # Apply caller-specified event-code filter.
        if ($FilterCodes -notcontains $code) { return $null }

        $date     = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        $timeStr  = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
        $desc     = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
        $ip       = if ($parts.Count -gt 4) { $parts[4].Trim() } else { '' }
        $hostname = if ($parts.Count -gt 5) { $parts[5].Trim() } else { '' }
        $mac      = if ($parts.Count -gt 6) { $parts[6].Trim() } else { '' }
        $userName = if ($parts.Count -gt 7) { $parts[7].Trim() } else { '' }
        $txnId    = if ($parts.Count -gt 8) { $parts[8].Trim() } else { '' }

        $timestamp = $null
        if ($date -and $timeStr) {
            foreach ($fmt in @('MM/dd/yy HH:mm:ss', 'MM/dd/yyyy HH:mm:ss')) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParseExact(
                        "$date $timeStr", $fmt,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None,
                        [ref] $parsed)) {
                    $timestamp = $parsed
                    break
                }
            }
        }

        $ename = if ($EventCodeNames.ContainsKey($code)) { $EventCodeNames[$code] } else { 'Unknown' }

        return [PSCustomObject] @{
            Server        = $Srv
            EventCode     = $code
            EventName     = $ename
            Timestamp     = $timestamp
            IPAddress     = $ip
            HostName      = $hostname
            MACAddress    = $mac
            UserName      = $userName
            TransactionID = $txnId
            Description   = $desc
            RawLine       = $Line
        }
    }

    function Send-Diag ([string] $Level, [string] $Message) {
        $Queue.Enqueue([PSCustomObject] @{
            _IsDiag = $true
            Level   = $Level
            Server  = $Server
            Message = $Message
            At      = [datetime]::UtcNow
        })
    }

    function New-RemoteSession {
        # OperationTimeout covers the WinRM call itself; OpenTimeout covers
        # the initial TCP + auth handshake.
        $so     = New-PSSessionOption -OpenTimeout 30000 -OperationTimeout 60000
        $params = @{
            ComputerName  = $Server
            SessionOption = $so
            ErrorAction   = 'Stop'
        }
        if ($null -ne $Credential) {
            $params['Credential']     = $Credential
            $params['Authentication'] = 'Kerberos'
        }
        return New-PSSession @params
    }

    function Get-LogDirectory ($Sess) {
        return Invoke-Command -Session $Sess -ScriptBlock {
            # Get-DhcpServerAuditLog auto-imports from the DhcpServer module,
            # which ships with the DHCP Server role on WS2012+.
            (Get-DhcpServerAuditLog).Path
        }
    }

    # ------------------------------------------------------------------
    # Mutable state for this server
    # ------------------------------------------------------------------
    $currentFileName = $InitialState['FileName']          # '' on first run
    $currentOffset   = [long] $InitialState['Offset']     # 0 on first run
    $logDirectory    = $null
    $session         = $null
    $backoffSeconds  = 5

    Send-Diag -Level 'Info' -Message "Worker starting"

    while ($true) {
        # --- Ensure live session ---
        $sessionOk = $false
        if ($null -ne $session) {
            try { $sessionOk = ($session.State -eq 'Opened') } catch {}
        }

        if (-not $sessionOk) {
            if ($null -ne $session) {
                try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch {}
                $session = $null; $logDirectory = $null
            }
            Send-Diag -Level 'Info' -Message "Connecting (backoff ${backoffSeconds}s)..."
            try {
                $session        = New-RemoteSession
                $logDirectory   = Get-LogDirectory -Sess $session
                $backoffSeconds = 5   # reset on successful connect
                Send-Diag -Level 'Info' -Message "Connected — log dir: $logDirectory"
            } catch {
                Send-Diag -Level 'Warning' -Message "Connect failed: $_.  Retrying in ${backoffSeconds}s."
                Start-Sleep -Seconds $backoffSeconds
                $backoffSeconds = [Math]::Min($backoffSeconds * 2, $MaxBackoff)
                continue
            }
        }

        # --- Day rollover detection ---
        $todayFile = "DhcpSrvLog-$(Get-DayAbbrev -dt ([datetime]::Now)).log"

        if ($currentFileName -and ($currentFileName -ne $todayFile)) {
            Send-Diag -Level 'Info' -Message "Day rollover: $currentFileName -> $todayFile  (offset reset)"
            $currentFileName = $todayFile
            $currentOffset   = 0L   # read new day's file from the beginning
        } elseif (-not $currentFileName) {
            # Very first run: stream from current EOF to avoid historical replay.
            $currentFileName = $todayFile
            $currentOffset   = [long]::MaxValue   # sentinel; remote block handles it
        }

        # --- Poll ---
        try {
            $rawLines = Invoke-Command -Session $session `
                -ScriptBlock $RemoteReadBlock `
                -ArgumentList $logDirectory, $currentFileName, $currentOffset

            $newOffset  = $currentOffset
            $dataLines  = [System.Collections.Generic.List[string]]::new()

            foreach ($raw in $rawLines) {
                if ($raw -match '^@OFFSET:(\d+)$') {
                    $newOffset = [long] $Matches[1]
                } else {
                    $dataLines.Add($raw)
                }
            }

            $currentOffset = $newOffset

            # Tell the main loop to persist state.
            $Queue.Enqueue([PSCustomObject] @{
                _IsStateUpdate = $true
                Server         = $Server
                FileName       = $currentFileName
                Offset         = $currentOffset
            })

            # Parse and enqueue lease events.
            foreach ($line in $dataLines) {
                $evt = Parse-DhcpLine -Line $line -Srv $Server
                if ($null -ne $evt) { $Queue.Enqueue($evt) }
            }

        } catch {
            Send-Diag -Level 'Warning' -Message "Remote read error: $_.  Will reconnect."
            try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch {}
            $session = $null
            # Do not sleep here; the reconnect path at the top of the loop
            # applies back-off.
            continue
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

# ===========================================================================
# Entry point
# ===========================================================================

if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Install-Module ThreadJob -Scope CurrentUser -Force -ErrorAction Stop
    Import-Module ThreadJob -ErrorAction Stop
}

# Ensure state file directory exists.
$stateDir = Split-Path -Parent $StateFile
if ($stateDir -and -not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

# Load persisted tail state.
$state = Read-StateFile -Path $StateFile

# Open output file in append mode if requested.
$outputWriter = $null
if ($OutputPath) {
    $outputWriter = [System.IO.StreamWriter]::new(
        $OutputPath,
        $true,                          # append = $true
        [System.Text.Encoding]::UTF8
    )
    $outputWriter.AutoFlush = $true
    Write-Verbose "JSON Lines output: $OutputPath"
}

# Start one ThreadJob per DHCP server.
$jobs = [System.Collections.Generic.List[object]]::new()

foreach ($srv in $ComputerName) {
    $key       = $srv.ToLowerInvariant()
    $initState = if ($state.ContainsKey($key)) {
        $state[$key]
    } else {
        @{ FileName = ''; Offset = 0L }
    }

    Write-Verbose "Starting worker for $srv  (file='$($initState.FileName)' offset=$($initState.Offset))"

    $job = Start-ThreadJob -Name "DhcpTail-$srv" -ScriptBlock $script:ServerWorker -ArgumentList @(
        $srv,
        $Credential,
        $PollSeconds,
        $initState,
        $script:OutputQueue,
        $script:DayAbbreviations,
        $script:EventCodeNames,
        ([int[]] $script:FilterCodes),
        $script:RemoteReadBlock,
        $script:MaxBackoffSeconds
    )
    $jobs.Add($job)
}

Write-Verbose "$($jobs.Count) worker job(s) started.  Ctrl+C to stop."
$stateChanged    = $false
$eventCounts     = @{}   # total events seen per server (lowercased key)
$lastEventAt     = @{}   # last event timestamp per server
$lastStatusAt    = [datetime]::Now

try {
    while ($true) {
        # Drain shared queue.
        $item = $null
        while ($script:OutputQueue.TryDequeue([ref] $item)) {

            # Diagnostic message from a worker.
            if ($item.PSObject.Properties['_IsDiag'] -and $item._IsDiag) {
                $msg = "[$($item.Server)] $($item.Message)"
                if ($item.Level -eq 'Warning') { Write-Warning $msg } else { Write-Verbose $msg }
                continue
            }

            # State-update token from a worker.
            if ($item.PSObject.Properties['_IsStateUpdate'] -and $item._IsStateUpdate) {
                $state[$item.Server.ToLowerInvariant()] = @{
                    FileName = $item.FileName
                    Offset   = $item.Offset
                }
                $stateChanged = $true
                continue
            }

            # Lease event: emit to the pipeline.
            Write-Output $item
            $evtKey = $item.Server.ToLowerInvariant()
            $eventCounts[$evtKey] = if ($eventCounts.ContainsKey($evtKey)) { $eventCounts[$evtKey] + 1 } else { 1 }
            $lastEventAt[$evtKey] = [datetime]::Now

            if ($null -ne $outputWriter) {
                # Build an ordered dict so JSON key order is deterministic.
                $jsonObj = [ordered] @{
                    Server        = $item.Server
                    EventCode     = $item.EventCode
                    EventName     = $item.EventName
                    # ISO 8601 with sub-second precision; null if parse failed.
                    Timestamp     = if ($null -ne $item.Timestamp) { $item.Timestamp.ToString('o') } else { $null }
                    IPAddress     = $item.IPAddress
                    HostName      = $item.HostName
                    MACAddress    = $item.MACAddress
                    UserName      = $item.UserName
                    TransactionID = $item.TransactionID
                    Description   = $item.Description
                }
                $outputWriter.WriteLine(($jsonObj | ConvertTo-Json -Compress -Depth 2))
            }
        }

        # Persist state after every drain cycle.
        if ($stateChanged) {
            Save-StateFile -Path $StateFile -State $state
            $stateChanged = $false
        }

        # Surface any worker that terminated unexpectedly.
        foreach ($job in $jobs) {
            if ($job.State -in @('Failed', 'Stopped')) {
                $errDetail = Receive-Job -Job $job -ErrorAction SilentlyContinue
                Write-Warning "Worker '$($job.Name)' stopped unexpectedly (state=$($job.State)). Detail: $errDetail"
            }
        }

        # Print a status line every 30 seconds.
        if (([datetime]::Now - $lastStatusAt).TotalSeconds -ge 30) {
            foreach ($job in $jobs) {
                $srv   = $job.Name -replace '^DhcpTail-', ''
                $key   = $srv.ToLowerInvariant()
                $count = if ($eventCounts.ContainsKey($key)) { $eventCounts[$key] } else { 0 }
                $last  = if ($lastEventAt.ContainsKey($key)) { $lastEventAt[$key].ToString('HH:mm:ss') } else { 'none yet' }
                $color = if ($job.State -eq 'Running') { 'Cyan' } else { 'Red' }
                Write-Host ('[STATUS {0}]  {1}  State={2}  TotalEvents={3}  LastEvent={4}' -f `
                    [datetime]::Now.ToString('HH:mm:ss'), $srv, $job.State, $count, $last) `
                    -ForegroundColor $color
            }
            $lastStatusAt = [datetime]::Now
        }

        # Yield the CPU between drain cycles; workers sleep PollSeconds.
        Start-Sleep -Milliseconds 250
    }
}
finally {
    # Cleanup runs on Ctrl+C, pipeline stop, or any unhandled terminating error.
    Write-Verbose "Shutting down..."

    foreach ($job in $jobs) {
        try { Stop-Job  -Job $job -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    }

    if ($null -ne $outputWriter) {
        try { $outputWriter.Flush(); $outputWriter.Dispose() } catch {}
    }

    # Drain residual queue items and save final state before exiting.
    $item = $null
    while ($script:OutputQueue.TryDequeue([ref] $item)) {
        if ($item.PSObject.Properties['_IsStateUpdate'] -and $item._IsStateUpdate) {
            $state[$item.Server.ToLowerInvariant()] = @{
                FileName = $item.FileName
                Offset   = $item.Offset
            }
            $stateChanged = $true
        }
    }
    if ($stateChanged) {
        try { Save-StateFile -Path $StateFile -State $state } catch {}
    }

    Write-Verbose "Shutdown complete."
}
 
