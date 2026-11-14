# Retries shared by the refresh scripts (dot-sourced). Everything the weekly refresh talks to can fail for a moment:
# a directory answers 503, the GitHub API is rate-limited, a push races another one. Such a step is tried again with
# a growing pause (1 s, 2 s, 4 s, ... times -BaseDelaySeconds) before the run gives up, and every retry is counted
# for the run's metrics (scripts/lib/Telemetry.ps1).

$script:RetryCount = 0

# Runs $Action until it succeeds or -Attempts runs out; the last failure is thrown. $Action fails by throwing.
function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 3, [double]$BaseDelaySeconds = 1, [string]$What = 'step') {
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Action
        } catch {
            if ($attempt -ge $Attempts) { throw }
            $script:RetryCount++
            $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
            Write-Warning "$What failed (attempt $attempt of $Attempts): $($_.Exception.Message); trying again in $delay s."
            Start-Sleep -Milliseconds ([int]($delay * 1000))
        }
    }
}

# Writes a file through a temporary file next to it and a rename: a run cancelled halfway leaves the old file or
# the new one, never half of one.
function Write-FileAtomic([string]$Path, [string]$Text, [bool]$Bom = $false) {
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($Bom))
    Move-Item -LiteralPath $temporary -Destination $Path -Force -WhatIf:$false
}
