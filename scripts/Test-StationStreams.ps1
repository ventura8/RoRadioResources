#Requires -Version 7.0
<#
.SYNOPSIS
    Probes the stream of every station (or the named ones) and says which are alive, dead or not audio.

.DESCRIPTION
    Before a station's url is changed, find out whether its stream is actually broken. A station that is
    alive but failed for one listener is not fixed by a new url, and a url is never replaced on a guess.
    Used by RoRadio's fix-failing-stations skill and by Update-StationUrls.ps1 (the weekly refresh workflow).

    Uses curl, not HttpClient: many Romanian stations still run Shoutcast servers that answer "ICY 200 OK"
    instead of an HTTP status line, which HttpClient rejects. Current curl rejects it too unless asked for
    HTTP/0.9, so a server that sent nothing to the plain request is asked again that way and its ICY status
    line is read from the body (Invoke-IcyProbe; the app itself plays these streams). An HLS playlist (.m3u8) is
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

    # The weekly refresh runs this on a GitHub runner against urls that come from the internet (directories, the
    # status pages of stream servers). A url - or a redirect - that points into a private network, the machine
    # itself or a cloud metadata address (169.254.169.254) is never requested: it counts as dead (CodeRabbit,
    # RoRadioResources#2). Redirects are therefore followed here, one checked hop at a time, not by curl -L.
    function Test-PrivateAddress([Net.IPAddress]$Address) {
        if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
        if ([Net.IPAddress]::IsLoopback($Address) -or $Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or $Address.IsIPv6Multicast) { return $true }
        $b = $Address.GetAddressBytes()
        if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
            return ($b[0] -band 0xFE) -eq 0xFC -or $Address.Equals([Net.IPAddress]::IPv6None)
        }

        $b[0] -eq 0 -or $b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -ge 224 -or
            ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
            ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)
    }

    # The curl arguments that pin a request to an address checked here, or $null when the url may not be
    # requested. Checking the name and letting curl resolve it again would leave a gap (DNS rebinding: the second
    # answer can be private), so a name is bound with --resolve to the first checked address.
    function Get-PinnedTarget([string]$Url) {
        try { $uri = [Uri]$Url } catch { return $null }
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin 'http', 'https') { return $null }
        try { $addresses = [Net.Dns]::GetHostAddresses($uri.DnsSafeHost) } catch { return $null }
        if ($addresses.Count -eq 0 -or ($addresses | Where-Object { Test-PrivateAddress $_ })) { return $null }
        if ($uri.HostNameType -in 'IPv4', 'IPv6') { return , @() }
        # IPv4 first: GitHub's runners have no IPv6 route, and a pinned IPv6 address would read as dead there.
        $address = @($addresses | Where-Object AddressFamily -eq ([Net.Sockets.AddressFamily]::InterNetwork)) + @($addresses) | Select-Object -First 1
        $literal = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { "[$address]" } else { "$address" }
        , @('--resolve', "$($uri.Host):$($uri.Port):$literal")
    }

    function Test-PublicUrl([string]$Url) {
        $null -ne (Get-PinnedTarget $Url)
    }

    # One request per hop: the first 4 KB at most, the status, the content type and how long each step took.
    # Final is the url that answered (after redirects), so the ICY retry and HLS resolution start from there.
    function Invoke-Probe([string]$Url) {
        $format = '%{http_code}|%{content_type}|%{time_connect}|%{time_starttransfer}|%{size_download}|%{redirect_url}'
        $current = $Url
        foreach ($hop in 0..5) {
            $pin = Get-PinnedTarget $current
            if ($null -eq $pin) { break }
            $line = & $curl -s @pin -o $discard -r 0-4095 --max-time $timeout -A 'RoRadio-station-probe' -w $format $current 2>$null
            $parts = "$line".Split('|')
            $result = [pscustomobject]@{
                Code        = $parts[0]
                ContentType = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                Connect     = if ($parts.Count -gt 2) { [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
                FirstByte   = if ($parts.Count -gt 3) { [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
                Bytes       = if ($parts.Count -gt 4) { [long]$parts[4] } else { 0 }
                Final       = $current
            }
            $redirect = if ($parts.Count -gt 5) { $parts[5] } else { '' }
            if ($result.Code -notmatch '^3\d\d$' -or -not $redirect) { return $result }
            $current = $redirect
        }

        [pscustomobject]@{ Code = '000'; ContentType = ''; Connect = 0; FirstByte = 0; Bytes = 0; Final = $current }
    }

    # A playlist's text and the url it came from (relative entries resolve against that), redirects checked.
    function Get-Body([string]$Url) {
        $file = [IO.Path]::GetTempFileName()
        try {
            $current = $Url
            foreach ($hop in 0..5) {
                $pin = Get-PinnedTarget $current
                if ($null -eq $pin) { break }
                $line = & $curl -s @pin -o $file --max-time $timeout --max-filesize 1048576 -A 'RoRadio-station-probe' -w '%{http_code}|%{redirect_url}' $current 2>$null
                $parts = "$line".Split('|')
                if ($parts[0] -notmatch '^3\d\d$' -or $parts.Count -lt 2 -or -not $parts[1]) {
                    return [pscustomobject]@{ Body = [IO.File]::ReadAllText($file); Final = $current }
                }
                $current = $parts[1]
            }

            [pscustomobject]@{ Body = ''; Final = $current }
        } finally {
            Remove-Item $file -ErrorAction SilentlyContinue
        }
    }

    # Shoutcast 1 servers answer "ICY 200 OK" instead of an HTTP status line. curl 7.66 and later read that only
    # as HTTP/0.9 when --http0.9 is given, and even then report no status and no content type: the plain probe
    # sees nothing and would call a playing station dead (Pure Jazz Radio, Dip Music, 2026-09-29). Such a server
    # is asked again that way, for a few seconds, and the ICY status line and headers are read from the start of
    # what it sent. It ignores the byte range and streams on, so the rate is capped: at most ~96 KB per probe.
    # $Url is the probe's Final url (redirects already followed and checked).
    function Invoke-IcyProbe([string]$Url) {
        $pin = Get-PinnedTarget $Url
        if ($null -eq $pin) { return $null }
        $file = [IO.Path]::GetTempFileName()
        try {
            $null = & $curl -s @pin --http0.9 -o $file --max-time ([Math]::Min($timeout, 6)) --limit-rate 16K -A 'RoRadio-station-probe' $Url 2>$null
            $length = (Get-Item $file).Length
            if ($length -eq 0) { return $null }
            $stream = [IO.File]::OpenRead($file)
            try {
                $head = [byte[]]::new([Math]::Min($length, 4096))
                $null = $stream.Read($head, 0, $head.Length)
            } finally {
                $stream.Dispose()
            }

            $text = [Text.Encoding]::ASCII.GetString($head)
            if ($text -notmatch '^ICY (\d{3})') { return $null }
            $code = $Matches[1]
            $end = $text.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
            $headers = if ($end -ge 0) { $text.Substring(0, $end) } else { $text }
            [pscustomobject]@{
                Code        = $code
                ContentType = if ($headers -match '(?im)^content-type:\s*(\S+)') { $Matches[1] } else { 'audio/mpeg' }
                Connect     = 0
                FirstByte   = 0
                Bytes       = if ($end -ge 0) { $length - $end - 4 } else { 0 }
            }
        } finally {
            Remove-Item $file -ErrorAction SilentlyContinue
        }
    }

    $station = $_
    $probe = Invoke-Probe $station.Url
    if ($probe.Code -in '000', '' -and $probe.Bytes -eq 0 -and ($icy = Invoke-IcyProbe $probe.Final)) {
        $probe = $icy
    }

    $checked = $station.Url

    # An HLS playlist answering proves little: follow it to the first variant and the first segment.
    if ($probe.Code -eq '200' -and ($station.Url -match '\.m3u8(\?|$)' -or $probe.ContentType -match 'mpegurl')) {
        $base = $station.Url
        foreach ($hop in 1..2) {
            $playlist = Get-Body $base
            $next = $playlist.Body -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
            if (-not $next) { break }
            $base = ([Uri]::new([Uri]$playlist.Final, $next.Trim())).AbsoluteUri
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
