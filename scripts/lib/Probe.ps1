# The stream probe of Test-StationStreams.ps1 (dot-sourced; each of its parallel runspaces loads this file, and this
# file loads the network helpers). One station in, one verdict out:
#
#   alive     the stream answered with audio bytes
#   no-audio  it answered, but with something that is not audio (an HTML page, an empty body)
#   http-NNN  it answered with an HTTP error
#   dead      no connection, or connected and nothing came back within the timeout
#
# Every request is checked and pinned (lib/Net.ps1): a url - or a redirect - that points into a private network, the
# machine itself or a cloud metadata address is never requested and counts as dead (CodeRabbit, RoRadioResources#2).

. (Join-Path $PSScriptRoot 'Net.ps1')

# One request per hop: the first 4 KB at most, the status, the content type and how long each step took. Final is
# the url that answered (after redirects), so the ICY retry and the HLS resolution start from there.
function Invoke-Probe([string]$Url, [int]$TimeoutSeconds) {
    $format = '%{http_code}|%{content_type}|%{time_connect}|%{time_starttransfer}|%{size_download}|%{redirect_url}'
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    # The body is discarded: a stream that ignores the byte range keeps sending until the timeout (Greptile, #38).
    $discard = ('/dev/null', 'NUL')[[int][bool]$IsWindows]
    $current = $Url
    foreach ($hop in 0..5) {
        Write-Debug "Hop ${hop}: $current"
        $pin = Get-PinnedTarget $current
        if ($null -eq $pin) { break }
        $line = & $script:Curl -s @pin -o $discard -r 0-4095 --max-time $TimeoutSeconds -A 'RoRadio-station-probe' -w $format $current 2>$null
        # curl prints every field even when it got no answer ("000||0.000000|...").
        $parts = "$line".Split('|')
        $result = [pscustomobject]@{
            Code        = $parts[0]
            ContentType = $parts[1]
            Connect     = [double]::Parse($parts[2], $invariant)
            FirstByte   = [double]::Parse($parts[3], $invariant)
            Bytes       = [long]$parts[4]
            Final       = $current
        }
        if ($result.Code -notmatch '^3\d\d$' -or -not $parts[5]) { return $result }
        $current = $parts[5]
    }

    [pscustomobject]@{ Code = '000'; ContentType = ''; Connect = 0; FirstByte = 0; Bytes = 0; Final = $current }
}

# A playlist's text and the url it came from (relative entries resolve against that): checked, pinned and capped like
# every download (Save-PublicFile); a playlist cut short or answered with an error has no text.
function Get-Body([string]$Url, [int]$TimeoutSeconds) {
    $file = [IO.Path]::GetTempFileName()
    try {
        $final = Save-PublicFile $Url $file -TimeoutSeconds $TimeoutSeconds -MaxBytes 1MB
        if ($final) { return [pscustomobject]@{ Body = [IO.File]::ReadAllText($file); Final = $final } }
        [pscustomobject]@{ Body = ''; Final = $Url }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# Shoutcast 1 servers answer "ICY 200 OK" instead of an HTTP status line. curl 7.66 and later read that only as
# HTTP/0.9 when --http0.9 is given, and even then report no status and no content type: the plain probe sees nothing
# and would call a playing station dead (Pure Jazz Radio, Dip Music, 2026-09-29). Such a server is asked again that
# way, for a few seconds, and the ICY status line and headers are read from the start of what it sent. It ignores the
# byte range and streams on, so the rate is capped: at most ~96 KB per probe. $Url is the probe's Final url
# (redirects already followed and checked).
function Invoke-IcyProbe([string]$Url, [int]$TimeoutSeconds) {
    $pin = Get-PinnedTarget $Url
    if ($null -eq $pin) { return $null }
    $file = [IO.Path]::GetTempFileName()
    try {
        $null = & $script:Curl -s @pin --http0.9 -o $file --max-time ([Math]::Min($TimeoutSeconds, 6)) --limit-rate 16K -A 'RoRadio-station-probe' $Url 2>$null
        $all = [IO.File]::ReadAllBytes($file)
        $text = [Text.Encoding]::ASCII.GetString($all, 0, [Math]::Min($all.Length, 4096))
        if ($text -notmatch '^ICY (\d{3})') { return $null }
        $code = $Matches[1]
        $end = $text.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
        $headers = ($text, $text.Substring(0, [Math]::Max($end, 0)))[[int]($end -ge 0)]
        # A server that names no type sends MP3: Shoutcast 1 knew nothing else.
        $typed = $headers -match '(?im)^content-type:\s*(\S+)'
        [pscustomobject]@{
            Code        = $code
            ContentType = ('audio/mpeg', $Matches[1])[[int]$typed]
            Connect     = 0
            FirstByte   = 0
            Bytes       = [Math]::Max($all.Length - $end - 4, 0) * [int]($end -ge 0)
        }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# The verdict on one station ({ Title, Url, Guid, Category }).
function Get-StreamVerdict([object]$Station, [int]$TimeoutSeconds) {
    $probe = Invoke-Probe $Station.Url $TimeoutSeconds
    if ($probe.Code -in '000', '' -and $probe.Bytes -eq 0 -and ($icy = Invoke-IcyProbe $probe.Final $TimeoutSeconds)) {
        $probe = $icy
    }

    $checked = $Station.Url
    $reached = $true

    # An HLS playlist answering proves little: follow it to the first variant and the first segment. What an entry
    # is comes from its own answer, never its name: an entry that answers with a playlist type is another playlist,
    # whatever its extension (Greptile and CodeRabbit, #38). A playlist that leads to no segment within two levels
    # (an empty one, or playlists all the way down) is not audio: before 2026-11-14 the last playlist's own content
    # type made it "alive".
    if ($probe.Code -eq '200' -and ($Station.Url -match '\.m3u8(\?|$)' -or $probe.ContentType -match 'mpegurl')) {
        $reached = $false
        $base = $Station.Url
        foreach ($hop in 1..2) {
            Write-Debug "Playlist ${hop}: $base"
            $playlist = Get-Body $base $TimeoutSeconds
            $next = $playlist.Body -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
            if (-not $next) { break }
            $base = ([Uri]::new([Uri]$playlist.Final, $next.Trim())).AbsoluteUri
            $probe = Invoke-Probe $base $TimeoutSeconds
            $reached = $probe.ContentType -notmatch 'mpegurl'
            if ($reached) { break }
        }

        $checked = $base
    }

    $isAudio = $reached -and ($probe.ContentType -match '^(audio/|application/(octet-stream|ogg|x-mpegurl|vnd\.apple\.mpegurl))|mpegurl|aac|mpeg' -or
               ($probe.ContentType -eq '' -and $probe.Bytes -gt 0))
    $verdict = 'alive'
    if (-not $isAudio) { $verdict = 'no-audio' }
    if ($probe.Code -notmatch '^2\d\d$') { $verdict = "http-$($probe.Code)" }
    if (($probe.Code -in '000', '') -or ($probe.Bytes -eq 0 -and $probe.Code -eq '200')) { $verdict = 'dead' }

    [pscustomobject]@{
        Verdict     = $verdict
        Title       = $Station.Title
        Category    = $Station.Category
        FirstByte   = [Math]::Round($probe.FirstByte, 2)
        ContentType = $probe.ContentType
        Url         = $Station.Url
        Checked     = $checked
        Guid        = $Station.Guid
    }
}
