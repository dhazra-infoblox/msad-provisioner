# --- Input ---
$targetPid = (Get-Process -Name 'InfobloxAgentForMicrosoft').Id    # or set a specific PID: $targetPid = 1234
$outFile   = 'C:\Users\MSADAgent\Agent.csv'
$seconds   = 120
$interval  = 1

# --- Resolve the Process(*) instance name that matches this PID ---
# We query \Process(*)\ID Process and find the instance that has our PID.
$instances = Get-Counter '\Process(*)\ID Process'
$match = $instances.CounterSamples |
    Where-Object { $_.CookedValue -eq [double]$targetPid } |
    Select-Object -First 1

if (-not $match) {
    throw "Could not find a \Process(*) instance for PID $targetPid. Is the process running?"
}

# Instance name looks like 'YourAppName' or 'YourAppName#1' etc.
$instanceName = $match.Path -replace '^.*\\Process\((.+?)\)\\ID Process$','$1'
Write-Host "Resolved PID $targetPid to Process instance '$instanceName'"

# --- Build counters for this specific instance ---
# Note: typeperf needs quotes around each counter path.
$counters = @(
    "\Process($instanceName)\% Processor Time",
    "\Process($instanceName)\Working Set"
)

# --- Run typeperf ---
# -si sampling interval in seconds; -sc sample count; -f CSV output format
# On some systems you may need to quote the -o path if it contains spaces.
$typeperfArgs = @()
$counters | ForEach-Object { $typeperfArgs += $_ }
$typeperfArgs += @('-si', $interval, '-sc', $seconds, '-f', 'CSV', '-o', $outFile)

typeperf @typeperfArgs
Write-Host "Saved to $outFile"