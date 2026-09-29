#Requires -Version 7.0
<#
.SYNOPSIS
    Probes the stream of every station (or the named ones) and says which are alive, dead or not audio.

.DESCRIPTION
    Before a station's url is changed, find out whether its stream is actually broken. A station that is
    alive but failed for one listener is not fixed by a new url, and a url is never replaced on a guess.
    Used by RoRadio's fix-failing-stations skill and by Update-StationUrls.ps1 (the weekly refresh workflow).

    Uses curl, not HttpClient: many Romanian stations still run Shoutcast servers that answer "ICY 200 OK"
    instead of an HTTP status line, which HttpClient rejects and curl accepts. An HLS playlist (.m3u8) is
    followed to its first variant and first segment, because a playlist that answers says nothing about
    whether the audio behind it does.

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
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue) -and -not (Get-Command curl -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'curl is needed (it ships with Windows 10 1803 and later, and with every Linux runner).'
}

$stations = foreach ($category in (Get-Content $Catalog -Raw -Encoding utf8 | ConvertFrom-Json)) {
    foreach ($station in $category.List) {
        [pscustomobject]@{ Category = $category.Name; Title = $station.Title; Url = $station.Url; Guid = $station.GUID }
    }
}

# Titles are matched without diacritics and case: Romanian writes ț/ș both with a cedilla and with a comma
# below, the catalogue is not consistent about it, and Sentry's logs drop them entirely ("Constan?a").
function ConvertTo-PlainTitle([string]$Text) {
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $kept = $decomposed.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' }
    (-join $kept).ToLowerInvariant()
}

if ($Title) {
    $wanted = @($Title | ForEach-Object { ConvertTo-PlainTitle $_ })
    $stations = @($stations | Where-Object { $wanted -contains (ConvertTo-PlainTitle $_.Title) })
    $missing = @($wanted | Where-Object { $plain = $_; -not ($stations | Where-Object { (ConvertTo-PlainTitle $_.Title) -eq $plain }) })
    if ($missing) { Write-Warning "Not in the catalogue: $($missing -join ', ')" }
}
Write-Host "Probing $(@($stations).Count) station(s), $TimeoutSeconds s each, $ThrottleLimit at a time..."

$results = $stations | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $timeout = $using:TimeoutSeconds
    $curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }
    $discard = if ($IsWindows) { 'NUL' } else { '/dev/null' }

    # One request: the first 4 KB at most, the status, the content type and how long each step took.
    function Invoke-Probe([string]$Url) {
        $format = '%{http_code}|%{content_type}|%{time_connect}|%{time_starttransfer}|%{size_download}'
        $line = & $curl -s -L -o $discard -r 0-4095 --max-time $timeout -A 'RoRadio-station-probe' -w $format $Url 2>$null
        $parts = "$line".Split('|')
        [pscustomobject]@{
            Code        = $parts[0]
            ContentType = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            Connect     = if ($parts.Count -gt 2) { [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
            FirstByte   = if ($parts.Count -gt 3) { [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
            Bytes       = if ($parts.Count -gt 4) { [long]$parts[4] } else { 0 }
        }
    }

    function Get-Body([string]$Url) {
        & $curl -s -L --max-time $timeout -A 'RoRadio-station-probe' $Url 2>$null | Out-String
    }

    $station = $_
    $probe = Invoke-Probe $station.Url
    $checked = $station.Url

    # An HLS playlist answering proves little: follow it to the first variant and the first segment.
    if ($probe.Code -eq '200' -and ($station.Url -match '\.m3u8(\?|$)' -or $probe.ContentType -match 'mpegurl')) {
        $base = $station.Url
        foreach ($hop in 1..2) {
            $next = (Get-Body $base) -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
            if (-not $next) { break }
            $base = ([Uri]::new([Uri]$base, $next.Trim())).AbsoluteUri
            if ($base -notmatch '\.m3u8(\?|$)') { break }
        }

        $checked = $base
        $probe = Invoke-Probe $base
    }

    $isAudio = $probe.ContentType -match '^(audio/|application/(octet-stream|ogg|x-mpegurl|vnd\.apple\.mpegurl))|mpegurl|aac|mpeg' -or
               ($probe.ContentType -eq '' -and $probe.Bytes -gt 0)
    $verdict = if (($probe.Code -in '000', '') -or ($probe.Bytes -eq 0 -and $probe.Code -eq '200')) {
        'dead'
    } elseif ($probe.Code -notmatch '^2\d\d$') {
        "http-$($probe.Code)"
    } elseif (-not $isAudio) {
        'no-audio'
    } else {
        'alive'
    }

    [pscustomobject]@{
        Verdict     = $verdict
        Title       = $station.Title
        Category    = $station.Category
        FirstByte   = [Math]::Round($probe.FirstByte, 2)
        ContentType = $probe.ContentType
        Url         = $station.Url
        Checked     = $checked
        Guid        = $station.Guid
    }
}

$results = @($results | Sort-Object @{ Expression = { $_.Verdict -eq 'alive' } }, Title)
$summary = $results | Group-Object Verdict | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Result: " + ($summary -join '  '))
$results
