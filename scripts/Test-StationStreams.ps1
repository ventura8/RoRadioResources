#Requires -Version 7.0
<#
.SYNOPSIS
    Probes the stream of every station (or the named ones) and says which are alive, dead or not audio.

.DESCRIPTION
    Before a station's url is changed, find out whether its stream is actually broken. A station that is
    alive but failed for one listener is not fixed by a new url, and a url is never replaced on a guess.
    Used by RoRadio's fix-failing-stations skill and by Update-StationUrls.ps1 (the weekly refresh workflow).

    The probe itself is lib/Probe.ps1. It uses curl, not HttpClient: many Romanian stations still run Shoutcast
    servers that answer "ICY 200 OK" instead of an HTTP status line, which HttpClient rejects. Current curl rejects
    it too unless asked for HTTP/0.9, so a server that sent nothing to the plain request is asked again that way and
    its ICY status line is read from the body (the app itself plays these streams). An HLS playlist (.m3u8) is
    followed to its first variant and first segment, because a playlist that answers says nothing about whether the
    audio behind it does.

    Verdicts:
      alive     the stream answered with audio bytes
      no-audio  it answered, but with something that is not audio (an HTML page, an empty body)
      http-NNN  it answered with an HTTP error
      dead      no connection, or connected and nothing came back within -TimeoutSeconds

.PARAMETER Catalog
    The station list. Default: RadioStationsData.json next to this folder.

.PARAMETER Title
    Probe only these stations (titles, compared without diacritics and case). Default: all of them.

.PARAMETER TimeoutSeconds
    How long one station may take to send its first bytes. RoRadio gives up after 20 s (RadioPlayer.StallTimeout).

.PARAMETER ThrottleLimit
    How many stations are probed at once.

.EXAMPLE
    ./scripts/Test-StationStreams.ps1 | Where-Object Verdict -ne 'alive'

.EXAMPLE
    ./scripts/Test-StationStreams.ps1 -Title 'Europa FM', 'Radio Zu'
#>
[CmdletBinding()]
param(
    [string]$Catalog,
    [string[]]$Title,
    [int]$TimeoutSeconds = 20,
    [int]$ThrottleLimit = 24
)

$ErrorActionPreference = 'Stop'
if (-not $Catalog) { $Catalog = Join-Path (Split-Path $PSScriptRoot -Parent) 'RadioStationsData.json' }
if (-not (Test-Path $Catalog)) { throw "Station catalogue not found: $Catalog" }
$probeLibrary = Join-Path $PSScriptRoot 'lib/Probe.ps1'
. $probeLibrary
. (Join-Path $PSScriptRoot 'lib/Names.ps1')
if (-not (Get-Command $script:Curl -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'curl is needed (it ships with Windows 10 1803 and later, and with every Linux runner).'
}

$stations = foreach ($category in (Get-Content $Catalog -Raw -Encoding utf8 | ConvertFrom-Json)) {
    foreach ($station in $category.List) {
        [pscustomobject]@{ Category = $category.Name; Title = $station.Title; Url = $station.Url; Guid = $station.GUID }
    }
}

if ($Title) {
    $wanted = @($Title | ForEach-Object { ConvertTo-PlainTitle $_ })
    $stations = @($stations | Where-Object { $wanted -contains (ConvertTo-PlainTitle $_.Title) })
    $missing = @($wanted | Where-Object { $plain = $_; -not ($stations | Where-Object { (ConvertTo-PlainTitle $_.Title) -eq $plain }) })
    if ($missing) { Write-Warning "Not in the catalogue: $($missing -join ', ')" }
}
Write-Information "Probing $(@($stations).Count) station(s), $TimeoutSeconds s each, $ThrottleLimit at a time..." -InformationAction Continue

# Each runspace loads the probe itself. The work item carries what the runspace needs, and the worker is built from
# text: its whole body is lib/Probe.ps1, which the tests measure where they call it directly.
$work = @($stations | ForEach-Object { [pscustomobject]@{ Station = $_; Timeout = $TimeoutSeconds; Library = $probeLibrary } })
$worker = [scriptblock]::Create('. $_.Library; Get-StreamVerdict $_.Station $_.Timeout')
$results = @($work | ForEach-Object -ThrottleLimit ([Math]::Max($ThrottleLimit, 1)) -Parallel $worker)

$results = @($results | Sort-Object @{ Expression = { $_.Verdict -eq 'alive' } }, Title)
$summary = $results | Group-Object Verdict | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Information ("Result: " + ($summary -join '  ')) -InformationAction Continue
$results
