#Requires -Version 7.0
<#
.SYNOPSIS
    Finds a verified current url for every station whose stream is broken and writes it into the catalogue.

.DESCRIPTION
    The weekly refresh (.github/workflows/refresh-stations.yml) and the manual fix both run this:

      1. Probe every station (Test-StationStreams.ps1).
      2. Probe the failures again a minute later: a stream that answers the second time was a blip, not a move.
      3. For each station still failing, collect candidate urls, in this order:
           a. https://myradioonline.ro/<slug>, the page whose slug matches the station's title; the stream is
              the player's src/url attribute (its ?time= cache-buster removed)
           b. radio-browser.info, only entries whose name is exactly the station's title, whose country is
              Romania or Moldova, and whose homepage or stream host carries the station's name
           c. the old url's own server: its Icecast (status-json.xsl) or Shoutcast (statistics?json=1) status page,
              on the old port and on 8000, mounts whose name or url carry the station's name
           d. the Shoutcast directory (entries whose name contains the title) and radio.net (the exact title, in
              Romania or Moldova): suggestions only, never written - a name is not proof (2026-09-29)
         a, b and c are strong; d is weak. Old Shoutcast 1 servers answer "ICY 200 OK", which the probe reads
         since 2026-09-29 (before that, playing stations were reported dead).
      4. Probe the candidates, and the chosen one a second time: a url is written only when both probes heard
         audio. The first strong one that passes replaces the url; a weak one only goes to "Needs review". Nothing
         is written on a guess: a station with no live candidate keeps its url and is listed as unresolved. A
         candidate that is, contains or is contained in another station's url (or the new url of a station fixed
         earlier in the run) is dropped: RoRadio's unit tests require unique urls, and two stations on one stream
         means the broadcaster merged them, which is the owner's decision.
      5. Write a Markdown report (-ReportPath) of what changed, what did not, and which sources could not be read.

    Only the Url field changes. GUID (what listeners' favorites refer to), title, category and order never do,
    and the file keeps its encoding and line endings (UTF-8 with BOM; LF in the repository, CRLF in a Windows
    checkout with core.autocrlf), so the diff is one line per fix. The written list is checked before it is saved:
    the same stations, in the same order, and only the fixed urls changed.

    -WhatIf is the dry run: everything above against the live list and the live sources, the report written, the
    catalogue left alone (the workflow's dry_run input runs it that way).

.PARAMETER Catalog
    The station list. Default: RadioStationsData.json next to this folder.

.PARAMETER ReportPath
    Where to write the Markdown report. Default: none (the report is written to the output only).

.PARAMETER Title
    Consider only these stations (titles, compared without diacritics and case). Default: all of them.

.PARAMETER TimeoutSeconds
    How long one stream may take to send its first bytes (see Test-StationStreams.ps1).

.PARAMETER ThrottleLimit
    How many streams are probed at once.

.PARAMETER RetryDelaySeconds
    How long to wait before probing the failures a second time.

.PARAMETER ReplaceOnlyDead
    Replace only streams that are `dead` (no connection, nothing within the timeout). An HTTP error or a
    non-audio answer can be the network the probe runs from, not the stream: the first weekly run (2026-09-29,
    from a US runner) got HTTP 404 from Europa FM, which plays fine in Romania, and would have swapped it for a
    48k stream. Those stations are listed under "Needs review from Romania" with the candidate found. The weekly
    workflow passes this; a run from Romania can leave it off.

.PARAMETER MyRadioOnlineUrl
    The sources' addresses. The defaults are the real ones; the end-to-end tests point them at a fake server.

.PARAMETER RadioBrowserUrl
    See -MyRadioOnlineUrl.

.PARAMETER ShoutcastDirectoryUrl
    See -MyRadioOnlineUrl.

.PARAMETER ShoutcastPlaylistUrl
    See -MyRadioOnlineUrl.

.PARAMETER RadioNetUrl
    See -MyRadioOnlineUrl.

.OUTPUTS
    One object per station that failed both probes: Title, Guid, OldUrl, OldVerdict, NewUrl, Suggested, Source,
    Tried.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Catalog,
    [string]$ReportPath,
    [string[]]$Title,
    [int]$TimeoutSeconds = 20,
    [int]$ThrottleLimit = 16,
    [int]$RetryDelaySeconds = 60,
    [switch]$ReplaceOnlyDead,
    [string]$MyRadioOnlineUrl = 'https://myradioonline.ro',
    [string]$RadioBrowserUrl = 'https://de1.api.radio-browser.info',
    [string]$ShoutcastDirectoryUrl = 'https://directory.shoutcast.com',
    [string]$ShoutcastPlaylistUrl = 'https://yp.shoutcast.com',
    [string]$RadioNetUrl = 'https://prod.radio-api.net'
)

$ErrorActionPreference = 'Stop'
if (-not $Catalog) { $Catalog = Join-Path (Split-Path $PSScriptRoot -Parent) 'RadioStationsData.json' }
$Catalog = (Resolve-Path $Catalog).Path
$probeScript = Join-Path $PSScriptRoot 'Test-StationStreams.ps1'
$probeSettings = @{ TimeoutSeconds = $TimeoutSeconds; ThrottleLimit = $ThrottleLimit }
$scratch = Join-Path ([IO.Path]::GetTempPath()) "roradio-refresh-$PID"
# Scratch files are written even under -WhatIf, which only guards the catalogue (a dry run failed without them).
New-Item -ItemType Directory -Force -Path $scratch -WhatIf:$false | Out-Null
. (Join-Path $PSScriptRoot 'lib/Net.ps1')
. (Join-Path $PSScriptRoot 'lib/Names.ps1')

# Probes an arbitrary list of { Title, Url, Guid } through a throw-away catalogue, so the verdicts come from
# exactly the same code as the catalogue-wide probe.
function Invoke-StreamProbe([object[]]$Entries, [string]$Name) {
    $path = Join-Path $scratch "$Name.json"
    $list = @($Entries | ForEach-Object { [ordered]@{ GUID = $_.Guid; Title = $_.Title; Url = $_.Url } })
    ConvertTo-Json -InputObject @([ordered]@{ Name = $Name; List = $list }) -Depth 5 | Set-Content -Path $path -Encoding utf8 -WhatIf:$false
    @(& $probeScript -Catalog $path @probeSettings 6>$null)
}

# c. The old server itself. A station that moved its mount or port on the same Icecast / Shoutcast server lists
#    its current mounts on the server's status page (Radio Caprice's channels moved from ports 9085/9029/9135 to
#    mounts on :8000, 2026-09-29). Each mount is matched on its own name and path, never the host. A mark shared
#    by several mounts is the brand every channel carries ("caprice", "jazz") and tells them apart from nothing:
#    only marks that match exactly one mount count. One match is the station (strong); several are channels the
#    marks cannot separate, and go to review (CodeRabbit, RoRadioResources#2).
function Get-SameServerCandidate([string]$OldUrl, [string[]]$Marks) {
    $old = [Uri]$OldUrl
    $bases = @("$($old.Scheme)://$($old.Host):$($old.Port)") + @("http://$($old.Host):8000" | Where-Object { $old.Port -ne 8000 })
    $mounts = @(foreach ($base in $bases) {
        $icecast = Get-OptionalJson "$base/status-json.xsl"
        foreach ($source in @($icecast.icestats.source | Where-Object listenurl)) {
            [pscustomobject]@{ Url = $source.listenurl; Text = "$($source.server_name) $(Get-UrlPath $source.listenurl)"; Source = "same server, Icecast status ($base)" }
        }

        $shoutcast = Get-OptionalJson "$base/statistics?json=1"
        foreach ($stream in @($shoutcast.streams | Where-Object streampath)) {
            [pscustomobject]@{ Url = "$base$($stream.streampath)"; Text = "$($stream.servertitle) $($stream.streampath)"; Source = "same server, Shoutcast status ($base)" }
        }
    })

    $specific = @($Marks | Where-Object { $mark = $_; @($mounts | Where-Object { Test-NameMark @($mark) $_.Text }).Count -eq 1 })
    $found = @($mounts | Where-Object { $specific -and (Test-NameMark $specific $_.Text) })
    foreach ($mount in $found) {
        [pscustomobject]@{ Url = $mount.Url; Source = $mount.Source; Strong = $found.Count -eq 1 }
    }
}

# d. The Shoutcast directory: most Romanian manele web radios are listed there and nowhere else (Dip Music, Radio
#    Amma, 2026-09-29). It has no country, so a name match is only a suggestion for the owner.
function Get-ShoutcastCandidate([string]$StationTitle, [string]$DirectoryUrl, [string]$PlaylistUrl) {
    $plainTitle = ConvertTo-PlainTitle $StationTitle
    $search = "$DirectoryUrl/Search/UpdateSearch"
    try {
        if (-not (Test-PublicUrl $search)) { throw "$search is not a public address." }
        $found = Invoke-RestMethod -Method Post -Uri $search -Body @{ query = $StationTitle } -UserAgent $StationUserAgent -TimeoutSec 20 -MaximumRedirection 0
    } catch {
        Write-Warning "Could not read $search ($($_.Exception.Message))"
        $script:UnreadableSource.Add($search)
        return
    }

    foreach ($entry in @($found | Where-Object { (ConvertTo-PlainTitle $_.Name).Contains($plainTitle) } | Select-Object -First 3)) {
        $playlist = Get-Text "$PlaylistUrl/sbin/tunein-station.pls?id=$($entry.ID)"
        if ($playlist -match '(?m)^File1=(\S+)') {
            [pscustomobject]@{ Url = $Matches[1]; Source = "Shoutcast directory: $($entry.Name) (id $($entry.ID))"; Strong = $false }
        }
    }
}

# e. radio.net: the exact name, in Romania or Moldova. Its search is fuzzy and its stream hosts are often CDNs
#    without the station's name, so this too is only a suggestion.
function Get-RadioNetCandidate([string]$StationTitle, [string]$SearchUrl) {
    $plainTitle = ConvertTo-PlainTitle $StationTitle
    $found = Get-OptionalJson "$SearchUrl/stations/search?count=10&query=$([Uri]::EscapeDataString($StationTitle))"
    foreach ($entry in @($found.playables | Where-Object { (ConvertTo-PlainTitle $_.name) -eq $plainTitle -and $_.country -in 'Romania', 'Moldova' })) {
        foreach ($stream in @($entry.streams | Select-Object -First 1)) {
            [pscustomobject]@{ Url = $stream.url; Source = "radio.net ($($entry.id))"; Strong = $false }
        }
    }
}

# True when a url is, contains or is contained in one of the others (RoRadio's unit tests refuse that).
function Test-UrlClash([string]$Url, [string[]]$Others) {
    [bool]($Others | Where-Object { $_.Contains($Url) -or $Url.Contains($_) })
}

# 1 and 2: what is broken now, and still broken a minute later.
$stations = @(foreach ($category in (Get-Content $Catalog -Raw -Encoding utf8 | ConvertFrom-Json)) {
    foreach ($station in $category.List) { [pscustomobject]@{ Title = $station.Title; Url = $station.Url; Guid = $station.GUID } }
})
$toProbe = $stations
if ($Title) {
    $wanted = @($Title | ForEach-Object { ConvertTo-PlainTitle $_ })
    $toProbe = @($stations | Where-Object { $wanted -contains (ConvertTo-PlainTitle $_.Title) })
}
$firstPass = Invoke-StreamProbe $toProbe 'all'
$failing = @($firstPass | Where-Object Verdict -ne 'alive')
if ($failing) {
    Write-Information "$($failing.Count) failing; probing them again in $RetryDelaySeconds s." -InformationAction Continue
    Start-Sleep -Seconds $RetryDelaySeconds
    $failing = @(Invoke-StreamProbe $failing 'retry' | Where-Object Verdict -ne 'alive')
}
Write-Information "$($failing.Count) station(s) failed both probes." -InformationAction Continue

# 3: candidates.
$slugs = @()
if ($failing) {
    $slugs = Get-MyRadioOnlineSitemap $MyRadioOnlineUrl
    Write-Information "myradioonline.ro lists $($slugs.Count) stations." -InformationAction Continue
}

$notStream = '\.(png|jpe?g|webp|gif|svg|ico|css|js|json|html?)(\?|$)|google|facebook|apple\.com|twitter|instagram|youtube|myradioonline|schema\.org|w3\.org'
$claimed = [Collections.Generic.List[string]]::new()
$results = foreach ($station in $failing) {
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($pageSlug in Get-MyRadioOnlineSlug $station.Title $slugs) {
        $pageUrl = "$MyRadioOnlineUrl/$pageSlug"
        $page = Get-Text $pageUrl
        foreach ($match in [regex]::Matches($page, '(?:src|url)="(https?://[^"]+)"')) {
            $url = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) -replace '[?&]time=\d+$', ''
            if ($url -notmatch $notStream) { $candidates.Add([pscustomobject]@{ Url = $url; Source = $pageUrl; Strong = $true }) }
        }
    }

    # A directory entry with the same name is often another station: the first dry run (2026-09-29) matched
    # "Flash FM" to a GTA game radio, "One FM" to a Swiss one and "Radio Campus" to a Belgian one. So an entry
    # counts only when it is Romanian or Moldovan AND its homepage or stream host carries the station's name.
    $plainTitle = ConvertTo-PlainTitle $station.Title
    $marks = Get-NameMark $station.Title
    $directory = Get-Text "$RadioBrowserUrl/json/stations/search?hidebroken=true&limit=50&name=$([Uri]::EscapeDataString($station.Title))"
    foreach ($entry in @($directory | Where-Object { $_ } | ConvertFrom-Json)) {
        if ((ConvertTo-PlainTitle $entry.name) -ne $plainTitle -or -not $entry.url_resolved -or $entry.countrycode -notin 'RO', 'MD') { continue }
        $hosts = @($entry.homepage, $entry.url_resolved) | Where-Object { $_ } | ForEach-Object { Get-UrlHost $_ }
        if (-not ($marks | Where-Object { $mark = $_; $hosts | Where-Object { $_.Replace('-', '').Contains($mark) } })) { continue }
        $candidates.Add([pscustomobject]@{ Url = $entry.url_resolved; Source = "radio-browser.info ($($entry.homepage))"; Strong = $true })
    }

    $shoutcast = @(Get-ShoutcastCandidate -StationTitle $station.Title -DirectoryUrl $ShoutcastDirectoryUrl -PlaylistUrl $ShoutcastPlaylistUrl)
    foreach ($candidate in @(Get-SameServerCandidate $station.Url $marks) + $shoutcast + @(Get-RadioNetCandidate -StationTitle $station.Title -SearchUrl $RadioNetUrl)) {
        $candidates.Add($candidate)
    }

    # RoRadio's unit tests require every url to be unique and none to contain another: a candidate that is
    # another station's stream, or the new stream of a station fixed earlier in this run, means the broadcaster
    # merged the two channels, which is the owner's call. A script block, not `ForEach-Object Url`: under -WhatIf
    # the member form only reports what it would do and returns nothing, which switched this check off in dry runs.
    # Duplicates go in the order found (a set, not Group-Object, which sorts by url and so put a later source first).
    $others = @($stations | Where-Object Guid -ne $station.Guid | ForEach-Object { $_.Url }) + @($claimed)
    $seen = [Collections.Generic.HashSet[string]]::new()
    $unique = @($candidates | Where-Object { $_.Url -ne $station.Url -and -not (Test-UrlClash $_.Url $others) -and $seen.Add($_.Url) })
    # The live candidates, strong ones first; the first that is alive a second time too is the one. A live weak one
    # (a name match in a directory without a country) is only suggested: the same name is often another station
    # (round one, 2026-09-29).
    $best = $null
    if ($unique) {
        $entries = for ($i = 0; $i -lt $unique.Count; $i++) {
            [pscustomobject]@{ Title = "candidate $i"; Url = $unique[$i].Url; Guid = "$i" }
        }
        $verdicts = Invoke-StreamProbe $entries "candidates-$($station.Guid)"
        $alive = @(for ($i = 0; $i -lt $unique.Count; $i++) {
            if (($verdicts | Where-Object Guid -eq "$i").Verdict -eq 'alive') { $unique[$i] }
        })
        foreach ($candidate in @($alive | Where-Object Strong) + @($alive | Where-Object { -not $_.Strong })) {
            $again = Invoke-StreamProbe @([pscustomobject]@{ Title = 'confirm'; Url = $candidate.Url; Guid = 'confirm' }) "confirm-$($station.Guid)"
            if ($again.Verdict -eq 'alive') { $best = $candidate; break }
        }
    }

    $held = $best -and (-not $best.Strong -or ($ReplaceOnlyDead -and $station.Verdict -ne 'dead'))
    if ($best -and -not $held) { $claimed.Add($best.Url) }
    [pscustomobject]@{
        Title      = $station.Title
        Guid       = $station.Guid
        OldUrl     = $station.Url
        OldVerdict = $station.Verdict
        NewUrl     = @($best.Url)[[int][bool]$held]
        Suggested  = @($null, $best.Url)[[int][bool]$held]
        Source     = $best.Source
        Tried      = $unique.Count
    }
}
$results = @($results)

# 4: write the fixes, one Url line each, inside the station's own block (found by its GUID).
$bytes = [IO.File]::ReadAllBytes($Catalog)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [Text.UTF8Encoding]::new($false).GetString($bytes).TrimStart([char]0xFEFF)
$fixed = @($results | Where-Object NewUrl)
foreach ($fix in $fixed) {
    $pattern = '("GUID":\s*"' + [regex]::Escape($fix.Guid) + '"[^}]*?"Url":\s*)"' + [regex]::Escape(($fix.OldUrl | ConvertTo-Json).Trim('"')) + '"'
    $replacement = '${1}' + ($fix.NewUrl | ConvertTo-Json).Replace('$', '$$')
    $updated = [regex]::Replace($text, $pattern, $replacement)
    if ($updated -eq $text) { throw "Could not find the Url line of '$($fix.Title)' ($($fix.Guid))." }
    $text = $updated
}

# The written list must be the same stations in the same order, with only the fixed urls changed: a station is
# never removed, renamed or moved by the refresh, and no url is written that was not verified above.
$expected = @($stations | ForEach-Object {
    $guid = $_.Guid
    $fix = $fixed | Where-Object Guid -eq $guid
    "$guid|$($_.Title)|$(@($_.Url, $fix.NewUrl)[[int][bool]$fix])"
})
$written = @(foreach ($category in ($text | ConvertFrom-Json)) { foreach ($station in $category.List) { "$($station.GUID)|$($station.Title)|$($station.Url)" } })
if (Compare-Object $expected $written -SyncWindow 0) { throw 'The updated station list differs from the list with only the verified urls changed; nothing was written.' }
if ($fixed -and $PSCmdlet.ShouldProcess($Catalog, "Update $($fixed.Count) station url(s)")) {
    [IO.File]::WriteAllText($Catalog, $text, [Text.UTF8Encoding]::new($hasBom))
}

# 5: the report. It becomes the pull request body and docs/releases/<date>-refresh.md, so what can be a link is one.
function Format-Source([string]$Source) {
    if ($Source -match '^https?://(\S+)$') { return "[$($Matches[1])]($Source)" }
    if ($Source -match '^radio-browser\.info \((https?://[^)]+)\)$') { return "radio-browser.info ([$($Matches[1])]($($Matches[1])))" }
    if ($Source -match '^radio\.net \(([^)]+)\)$') { return "[radio.net ($($Matches[1]))](https://www.radio.net/s/$($Matches[1]))" }
    if ($Source -match '^(same server, (?:Icecast|Shoutcast) status) \((https?://[^)]+)\)$') { return "$($Matches[1]) ([$($Matches[2])]($($Matches[2])))" }
    # Anything else (a directory entry's own name) is quoted: a name ending in a "www." address was a bare url,
    # which markdownlint (MD034) refuses, and the 2026-10-19 note turned the repository's lint red.
    '`' + $Source.Replace('`', "'") + '`'
}

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Probed $(@($toProbe).Count) stations; $($results.Count) failed twice; $($fixed.Count) fixed.")
$lines.Add('')
if ($fixed) {
    $lines.Add('## Fixed')
    $lines.Add('')
    $lines.Add('| Station | Was | Old url | New url | Found on |')
    $lines.Add('| :--- | :--- | :--- | :--- | :--- |')
    foreach ($fix in $fixed) { $lines.Add("| $($fix.Title) | $($fix.OldVerdict) | ``$($fix.OldUrl)`` | ``$($fix.NewUrl)`` | $(Format-Source $fix.Source) |") }
    $lines.Add('')
}
$review = @($results | Where-Object Suggested)
if ($review) {
    $lines.Add('## Needs review (url kept): not an outright failure from here, or found only by name in a directory')
    $lines.Add('')
    $lines.Add('| Station | Verdict here | Url | Candidate | Found on |')
    $lines.Add('| :--- | :--- | :--- | :--- | :--- |')
    foreach ($item in $review) { $lines.Add("| $($item.Title) | $($item.OldVerdict) | ``$($item.OldUrl)`` | ``$($item.Suggested)`` | $(Format-Source $item.Source) |") }
    $lines.Add('')
}
$unresolved = @($results | Where-Object { -not $_.NewUrl -and -not $_.Suggested })
if ($unresolved) {
    $lines.Add('## Unresolved (url kept; the owner decides)')
    $lines.Add('')
    $lines.Add('| Station | Verdict | Url | Candidates tried |')
    $lines.Add('| :--- | :--- | :--- | :--- |')
    foreach ($miss in $unresolved) { $lines.Add("| $($miss.Title) | $($miss.OldVerdict) | ``$($miss.OldUrl)`` | $($miss.Tried) |") }
    $lines.Add('')
}
# A source that was down makes "unresolved" mean "not looked for": the report says which.
$unreadable = @($UnreadableSource | Select-Object -Unique)
if ($unreadable) {
    $lines.Add('## Sources that could not be read (the stations above were not searched there)')
    $lines.Add('')
    foreach ($url in $unreadable) { $lines.Add("- ``$url``") }
    $lines.Add('')
}
$report = $lines -join "`n"
if ($ReportPath) { Set-Content -Path $ReportPath -Value $report -Encoding utf8 -WhatIf:$false }
Write-Information $report -InformationAction Continue
Remove-Item -Recurse -Force $scratch -WhatIf:$false
$results
