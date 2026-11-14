# Retries shared by the refresh scripts (dot-sourced). Everything the weekly refresh talks to can fail for a moment:
# a directory answers 503, the GitHub API is rate-limited, a push races another one. Such a step is tried again with
# a growing pause (1 s, 2 s, 4 s, ... times -BaseDelaySeconds) before the run gives up.
#
# Every retry is counted in the process's environment (RORADIO_REFRESH_RETRIES), not in a script variable: the refresh
# runs its scripts inside each other, and each one dot-sources this file into its own scope, so a script-level counter
# lost the retries of the scripts it called (Greptile, #44). Invoke-Refresh.ps1 reads the total for the run's metrics.

# The retries counted so far in this process.
function Get-RetryTotal {
    [int]"0$env:RORADIO_REFRESH_RETRIES"
}

# Runs $Action until it succeeds or -Attempts runs out; the last failure is thrown. $Action fails by throwing.
function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 3, [double]$BaseDelaySeconds = 1, [string]$What = 'step') {
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Action
        } catch {
            if ($attempt -ge $Attempts) { throw }
            $env:RORADIO_REFRESH_RETRIES = "$((Get-RetryTotal) + 1)"
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
