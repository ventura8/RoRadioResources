# Error reports and run metrics of the weekly refresh (dot-sourced).
#
# Sentry: every failure and unhandled exception is sent to the project roradioresources-updater (organization 77bits)
# as an event through the envelope API, with the run, the stage, the station and the source as tags and the run's
# steps as breadcrumbs. The DSN comes from the SENTRY_DSN secret; without one nothing is sent. No secret ever leaves:
# tokens in the text (a push url's x-access-token, the values of GH_TOKEN, REFRESH_TOKEN, SENTRY_DSN) are replaced
# before the event is built.
#
# Metrics: one JSON line per run (metrics/runs.jsonl on the refresh-data branch): stations probed, failing, fixed,
# unresolved, retired and restored; per source the queries, hits, candidates and milliseconds; each stage's seconds;
# the retries; how long each failing station has failed. The weekly summary and the ranking of the sources read it.

$script:Breadcrumbs = [Collections.Generic.List[object]]::new()
$script:RunMetrics = [ordered]@{ Stages = [ordered]@{} }
$script:SentryTags = @{}
# The strong sources in their default order; Get-SourceRanking reorders them by how often each found the fix.
$script:DefaultSourceOrder = @('myradioonline', 'radio-browser', 'same-server')

# Text with every secret this run knows replaced.
function Protect-Text([string]$Text) {
    $clean = $Text -replace 'x-access-token:[^@\s]+@', 'x-access-token:[redacted]@'
    foreach ($secret in @($env:GH_TOKEN, $env:REFRESH_TOKEN, $env:SENTRY_DSN) | Where-Object { $_ -and $_.Length -ge 8 }) {
        $clean = $clean.Replace($secret, '[redacted]')
    }
    $clean
}

function Add-Breadcrumb([string]$Category, [string]$Message) {
    $script:Breadcrumbs.Add([ordered]@{ timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); category = $Category; message = (Protect-Text $Message) })
    if ($script:Breadcrumbs.Count -gt 100) { $script:Breadcrumbs.RemoveAt(0) }
}

# Sends one event to Sentry; $true when Sentry took it. Never throws: a report that cannot be sent must not stop the
# refresh (the warning says why).
function Send-SentryEvent([string]$Message, [string]$Level = 'error', [hashtable]$Tags = @{}, [object]$ErrorRecord, [string]$Dsn = $env:SENTRY_DSN) {
    if ($Dsn -notmatch '^(?<scheme>https?)://(?<key>[^@:/]+)(?::[^@]*)?@(?<host>[^/]+)/(?<path>(?:[^/]+/)*)(?<project>\d+)$') { return $false }
    $endpoint = "$($Matches.scheme)://$($Matches.host)/$($Matches.path)api/$($Matches.project)/envelope/"
    $auth = "Sentry sentry_version=7, sentry_key=$($Matches.key), sentry_client=roradio-refresh/1.0"
    $allTags = @{}
    foreach ($table in $script:SentryTags, $Tags) { foreach ($key in $table.Keys) { $allTags[$key] = Protect-Text "$($table[$key])" } }
    $eventId = [Guid]::NewGuid().ToString('n')
    $sentEvent = [ordered]@{
        event_id    = $eventId
        timestamp   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        platform    = 'other'
        level       = $Level
        logger      = 'station-refresh'
        environment = 'production'
        message     = @{ formatted = (Protect-Text $Message) }
        tags        = $allTags
        breadcrumbs = @{ values = @($script:Breadcrumbs) }
    }
    if ($ErrorRecord) {
        $sentEvent.exception = @{ values = @(@{
            type       = $ErrorRecord.Exception.GetType().Name
            value      = Protect-Text $ErrorRecord.Exception.Message
            stacktrace = @{ frames = @(@{ function = 'script'; filename = (Protect-Text "$($ErrorRecord.InvocationInfo.ScriptName)"); lineno = $ErrorRecord.InvocationInfo.ScriptLineNumber }) }
        }) }
    }
    $envelope = @(
        (@{ event_id = $eventId; sent_at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress),
        (@{ type = 'event' } | ConvertTo-Json -Compress),
        ($sentEvent | ConvertTo-Json -Compress -Depth 10)
    ) -join "`n"
    try {
        $null = Invoke-RestMethod -Method Post -Uri $endpoint -Headers @{ 'X-Sentry-Auth' = $auth } -ContentType 'application/x-sentry-envelope' -Body $envelope -TimeoutSec 15
        $true
    } catch {
        Write-Warning "Could not report to Sentry: $(Protect-Text $_.Exception.Message)"
        $false
    }
}

# Runs one stage of the refresh: its seconds go to the metrics, its start and end to the breadcrumbs, and a failure
# to Sentry (tag "stage") before it is thrown on.
function Measure-Stage([string]$Name, [scriptblock]$Action) {
    Add-Breadcrumb 'stage' "start $Name"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        Add-Breadcrumb 'stage' "end $Name"
    } catch {
        Add-Breadcrumb 'stage' "failed $Name"
        $null = Send-SentryEvent -Message "The refresh failed in stage $Name`: $($_.Exception.Message)" -Tags @{ stage = $Name } -ErrorRecord $_
        throw
    } finally {
        $script:RunMetrics.Stages[$Name] = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
    }
}

# Appends the run's metrics as one JSON line.
function Write-RunMetric([string]$Path) {
    $folder = Split-Path $Path -Parent
    New-Item -ItemType Directory -Force -Path $folder -WhatIf:$false | Out-Null
    Add-Content -Path $Path -Value ($script:RunMetrics | ConvertTo-Json -Compress -Depth 6) -Encoding utf8 -WhatIf:$false
}

# The runs of a metrics file, oldest first; none when it does not exist. A line that is not JSON (a run cut short
# mid-write) is skipped.
function Read-RunMetric([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return }
    foreach ($line in Get-Content -Path $Path -Encoding utf8) {
        try { $line | ConvertFrom-Json } catch { Write-Verbose "Skipped a metrics line that is not JSON: $line" }
    }
}

# The strong sources, the one that found the most fixes per query over the last -Runs runs first; a source with no
# data keeps its default place behind the ones that have some.
function Get-SourceRanking([string]$Path, [int]$Runs = 12) {
    $recent = @(Read-RunMetric $Path | Select-Object -Last $Runs)
    $rates = @{}
    foreach ($source in $script:DefaultSourceOrder) {
        $queries = ($recent | ForEach-Object { $_.Sources.$source.Queries } | Measure-Object -Sum).Sum
        $hits = ($recent | ForEach-Object { $_.Sources.$source.Hits } | Measure-Object -Sum).Sum
        $rates[$source] = @(-1, ($hits / [Math]::Max($queries, 1)))[[int]($queries -gt 0)]
    }
    @($script:DefaultSourceOrder | Sort-Object @{ Expression = { $rates[$_] }; Descending = $true }, @{ Expression = { $script:DefaultSourceOrder.IndexOf($_) } })
}

# The weekly summary: the last -Runs runs as a table, and each source's hit rate and speed over them.
function Format-RunTrend([string]$Path, [int]$Runs = 8) {
    $recent = @(Read-RunMetric $Path | Select-Object -Last $Runs)
    if (-not $recent) { return }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('## Trend (last runs)')
    $lines.Add('')
    $lines.Add('| Date | Probed | Failing | Fixed | Unresolved | Retired | Restored | Retries | Minutes |')
    $lines.Add('| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    foreach ($run in $recent) {
        $minutes = [Math]::Round((@($run.Stages.PSObject.Properties.Value) | Measure-Object -Sum).Sum / 60, 1)
        $lines.Add("| $($run.Date) | $($run.Probed) | $($run.Failing) | $($run.Fixed) | $($run.Unresolved) | $($run.Retired) | $($run.Restored) | $($run.Retries) | $minutes |")
    }
    $lines.Add('')
    $lines.Add('| Source | Queries | Fixes found | Hit rate | Average ms |')
    $lines.Add('| :--- | ---: | ---: | ---: | ---: |')
    $names = @($recent | ForEach-Object { $_.Sources.PSObject.Properties.Name } | Select-Object -Unique)
    foreach ($name in $names) {
        $queries = ($recent | ForEach-Object { $_.Sources.$name.Queries } | Measure-Object -Sum).Sum
        $hits = ($recent | ForEach-Object { $_.Sources.$name.Hits } | Measure-Object -Sum).Sum
        $milliseconds = ($recent | ForEach-Object { $_.Sources.$name.Milliseconds } | Measure-Object -Sum).Sum
        $rate = [Math]::Round(100 * $hits / [Math]::Max($queries, 1))
        $lines.Add("| $name | $queries | $hits | $rate% | $([Math]::Round($milliseconds / [Math]::Max($queries, 1))) |")
    }
    $lines -join "`n"
}
