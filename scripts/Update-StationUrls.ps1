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
      4. Probe the candidates. The first strong one that is alive replaces the url; a weak one only goes to
         "Needs review". Nothing is written on a guess:
         a station with no live candidate keeps its url and is listed as unresolved. A candidate that is,
         contains or is contained in another station's url is dropped: RoRadio's unit tests require unique urls,
         and two stations on one stream means the broadcaster merged them, which is the owner's decision.
      5. Write a Markdown report (-ReportPath) of what changed and what did not.

    Only the Url field changes. GUID (what listeners' favorites refer to), title, category and order never do,
    and the file keeps its encoding and line endings (UTF-8 with BOM; LF in the repository, CRLF in a Windows
    checkout with core.autocrlf), so the diff is one line per fix.

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

.OUTPUTS
    One object per station that failed both probes: Title, Guid, OldUrl, OldVerdict, NewUrl, Source.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Catalog,
    [string]$ReportPath,
    [string[]]$Title,
    [int]$TimeoutSeconds = 20,
    [int]$ThrottleLimit = 16,
    [int]$RetryDelaySeconds = 60,
    [switch]$ReplaceOnlyDead
)

$ErrorActionPreference = 'Stop'
if (-not $Catalog) { $Catalog = Join-Path (Split-Path $PSScriptRoot -Parent) 'RadioStationsData.json' }
$Catalog = (Resolve-Path $Catalog).Path
$probeScript = Join-Path $PSScriptRoot 'Test-StationStreams.ps1'
$probeSettings = @{ TimeoutSeconds = $TimeoutSeconds; ThrottleLimit = $ThrottleLimit }
$userAgent = 'RoRadio-station-refresh (+https://github.com/ventura8/RoRadioResources)'
$scratch = Join-Path ([IO.Path]::GetTempPath()) "roradio-refresh-$PID"
# Scratch files are written even under -WhatIf, which only guards the catalogue (a dry run failed without them).
New-Item -ItemType Directory -Force -Path $scratch -WhatIf:$false | Out-Null

function ConvertTo-PlainTitle([string]$Text) {
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $kept = $decomposed.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' }
    (-join $kept).ToLowerInvariant().Trim()
}

function ConvertTo-Slug([string]$Text) {
    ((ConvertTo-PlainTitle $Text) -replace "['’]", '' -replace '[^a-z0-9]+', '-').Trim('-')
}

# What of a station's name must show up in a host name for that host to be the station's own: the whole name
# run together ("radionoise", "romanfm") and each distinctive word of four letters or more ("noise", "aquila").
function Get-NameMark([string]$Title) {
    $generic = 'radio', 'online', 'romania', 'music', 'muzica', 'live', 'stream', 'best', 'hits', 'station'
    $words = @((ConvertTo-PlainTitle $Title) -split '[^a-z0-9]+' | Where-Object { $_ })
    @(-join $words) + @($words | Where-Object { $_.Length -ge 4 -and $generic -notcontains $_ }) | Select-Object -Unique
}

# Probes an arbitrary list of { Title, Url, Guid } through a throw-away catalogue, so the verdicts come from
# exactly the same code as the catalogue-wide probe.
function Invoke-StreamProbe([object[]]$Entries, [string]$Name) {
    $path = Join-Path $scratch "$Name.json"
    $list = @($Entries | ForEach-Object { [ordered]@{ GUID = $_.Guid; Title = $_.Title; Url = $_.Url } })
    ConvertTo-Json -InputObject @([ordered]@{ Name = $Name; List = $list }) -Depth 5 | Set-Content -Path $path -Encoding utf8 -WhatIf:$false
    @(& $probeScript -Catalog $path @probeSettings)
}

function Get-Text([string]$Url) {
    try {
        $content = (Invoke-WebRequest -Uri $Url -UserAgent $userAgent -TimeoutSec 30 -MaximumRetryCount 2).Content
        # A playlist (.pls, audio/x-scpls) is not a text content type to PowerShell: it comes back as bytes.
        if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { $content }
    } catch {
        Write-Warning "Could not read ${Url}: $($_.Exception.Message)"
        ''
    }
}

# A lookup that is allowed to find nothing (a status page most servers do not have): no retries, no warning.
function Get-OptionalJson([string]$Url) {
    try {
        (Invoke-WebRequest -Uri $Url -UserAgent $userAgent -TimeoutSec 10).Content | ConvertFrom-Json
    } catch {
        $null
    }
}

# True when the text carries one of the station's name marks (spaces and dashes ignored).
function Test-NameMark([string[]]$Marks, [string]$Text) {
    $plain = (ConvertTo-PlainTitle $Text) -replace '[\s\-_]', ''
    [bool]($Marks | Where-Object { $plain.Contains($_) })
}

# c. The old server itself. A station that moved its mount or port on the same Icecast / Shoutcast server lists
#    its current mounts on the server's status page (Radio Caprice's channels moved from ports 9085/9029/9135 to
#    mounts on :8000, 2026-09-29). Only mounts whose name or url carry the station's name count.
function Get-SameServerCandidates([string]$OldUrl, [string[]]$Marks) {
    try { $old = [Uri]$OldUrl } catch { return }
    $bases = @("$($old.Scheme)://$($old.Host):$($old.Port)")
    if ($old.Port -ne 8000) { $bases += "http://$($old.Host):8000" }
    foreach ($base in $bases) {
        $icecast = Get-OptionalJson "$base/status-json.xsl"
        foreach ($source in @($icecast.icestats.source)) {
            if ($source.listenurl -and (Test-NameMark $Marks "$($source.server_name) $($source.listenurl)")) {
                [pscustomobject]@{ Url = $source.listenurl; Source = "same server, Icecast status ($base)"; Strong = $true }
            }
        }

        $shoutcast = Get-OptionalJson "$base/statistics?json=1"
        foreach ($stream in @($shoutcast.streams)) {
            if ($stream.streampath -and (Test-NameMark $Marks "$($stream.servertitle) $($stream.streampath)")) {
                [pscustomobject]@{ Url = "$base$($stream.streampath)"; Source = "same server, Shoutcast status ($base)"; Strong = $true }
            }
        }
    }
}

# d. The Shoutcast directory: most Romanian manele web radios are listed there and nowhere else (Dip Music, Radio
#    Amma, 2026-09-29). It has no country, so a name match is only a suggestion for the owner.
function Get-ShoutcastCandidates([string]$Title) {
    $plainTitle = ConvertTo-PlainTitle $Title
    try {
        $found = Invoke-RestMethod -Method Post -Uri 'https://directory.shoutcast.com/Search/UpdateSearch' -Body @{ query = $Title } -UserAgent $userAgent -TimeoutSec 20
    } catch {
        return
    }

    foreach ($entry in @($found | Where-Object { (ConvertTo-PlainTitle $_.Name).Contains($plainTitle) } | Select-Object -First 3)) {
        $playlist = Get-Text "https://yp.shoutcast.com/sbin/tunein-station.pls?id=$($entry.ID)"
        if ($playlist -match '(?m)^File1=(\S+)') {
            [pscustomobject]@{ Url = $Matches[1]; Source = "Shoutcast directory: $($entry.Name) (id $($entry.ID))"; Strong = $false }
        }
    }
}

# e. radio.net: the exact name, in Romania or Moldova. Its search is fuzzy and its stream hosts are often CDNs
#    without the station's name, so this too is only a suggestion.
function Get-RadioNetCandidates([string]$Title) {
    $plainTitle = ConvertTo-PlainTitle $Title
    $found = Get-OptionalJson "https://prod.radio-api.net/stations/search?count=10&query=$([Uri]::EscapeDataString($Title))"
    foreach ($entry in @($found.playables)) {
        if ((ConvertTo-PlainTitle $entry.name) -ne $plainTitle -or $entry.country -notin 'Romania', 'Moldova') { continue }
        foreach ($stream in @($entry.streams | Select-Object -First 1)) {
            [pscustomobject]@{ Url = $stream.url; Source = "radio.net ($($entry.id))"; Strong = $false }
        }
    }
}

# 1 and 2: what is broken now, and still broken a minute later.
$stations = foreach ($category in (Get-Content $Catalog -Raw -Encoding utf8 | ConvertFrom-Json)) {
    foreach ($station in $category.List) { [pscustomobject]@{ Title = $station.Title; Url = $station.Url; Guid = $station.GUID } }
}
$toProbe = $stations
if ($Title) {
    $wanted = @($Title | ForEach-Object { ConvertTo-PlainTitle $_ })
    $toProbe = @($stations | Where-Object { $wanted -contains (ConvertTo-PlainTitle $_.Title) })
}
$firstPass = Invoke-StreamProbe $toProbe 'all'
$failing = @($firstPass | Where-Object Verdict -ne 'alive')
if ($failing) {
    Write-Host "$($failing.Count) failing; probing them again in $RetryDelaySeconds s."
    Start-Sleep -Seconds $RetryDelaySeconds
    $failing = @(Invoke-StreamProbe $failing 'retry' | Where-Object Verdict -ne 'alive')
}
Write-Host "$($failing.Count) station(s) failed both probes."

# 3: candidates.
$slugs = @()
if ($failing) {
    $sitemap = Get-Text 'https://myradioonline.ro/sitemap.xml'
    $slugs = @([regex]::Matches($sitemap, '<loc>https://myradioonline\.ro/([a-z0-9-]+)</loc>') | ForEach-Object { $_.Groups[1].Value })
    Write-Host "myradioonline.ro lists $($slugs.Count) stations."
}

$notStream = '\.(png|jpe?g|webp|gif|svg|ico|css|js|json|html?)(\?|$)|google|facebook|apple\.com|twitter|instagram|youtube|myradioonline|schema\.org|w3\.org'
$results = foreach ($station in $failing) {
    $candidates = [Collections.Generic.List[object]]::new()
    $slug = ConvertTo-Slug $station.Title
    $pageSlugs = @($slug, ($slug -replace '^radio-', ''), "radio-$slug") | Select-Object -Unique | Where-Object { $slugs -contains $_ }
    foreach ($pageSlug in $pageSlugs) {
        $page = Get-Text "https://myradioonline.ro/$pageSlug"
        foreach ($match in [regex]::Matches($page, '(?:src|url)="(https?://[^"]+)"')) {
            $url = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) -replace '[?&]time=\d+$', ''
            if ($url -notmatch $notStream) { $candidates.Add([pscustomobject]@{ Url = $url; Source = "myradioonline.ro/$pageSlug"; Strong = $true }) }
        }
    }

    # A directory entry with the same name is often another station: the first dry run (2026-09-29) matched
    # "Flash FM" to a GTA game radio, "One FM" to a Swiss one and "Radio Campus" to a Belgian one. So an entry
    # counts only when it is Romanian or Moldovan AND its homepage or stream host carries the station's name.
    $plainTitle = ConvertTo-PlainTitle $station.Title
    $marks = Get-NameMark $station.Title
    $directory = Get-Text "https://de1.api.radio-browser.info/json/stations/search?hidebroken=true&limit=50&name=$([Uri]::EscapeDataString($station.Title))"
    if ($directory) {
        foreach ($entry in ($directory | ConvertFrom-Json)) {
            if ((ConvertTo-PlainTitle $entry.name) -ne $plainTitle -or -not $entry.url_resolved) { continue }
            if ($entry.countrycode -notin 'RO', 'MD') { continue }
            $hosts = @($entry.homepage, $entry.url_resolved) | Where-Object { $_ } | ForEach-Object { try { ([Uri]$_).Host.ToLowerInvariant() } catch { '' } }
            if (-not ($marks | Where-Object { $mark = $_; $hosts | Where-Object { $_.Replace('-', '').Contains($mark) } })) { continue }
            $candidates.Add([pscustomobject]@{ Url = $entry.url_resolved; Source = "radio-browser.info ($($entry.homepage))"; Strong = $true })
        }
    }

    foreach ($candidate in @(Get-SameServerCandidates $station.Url $marks) + @(Get-ShoutcastCandidates $station.Title) + @(Get-RadioNetCandidates $station.Title)) {
        if ($candidate) { $candidates.Add($candidate) }
    }

    # RoRadio's unit tests require every url to be unique and none to contain another: a candidate that is
    # another station's stream means the broadcaster merged the two channels, which is the owner's call.
    # A script block, not `ForEach-Object Url`: under -WhatIf the member form only reports what it would do and
    # returns nothing, which switched this check off in dry runs.
    $others = @($stations | Where-Object Guid -ne $station.Guid | ForEach-Object { $_.Url })
    $unique = @($candidates |
        Where-Object { $url = $_.Url; $url -ne $station.Url -and -not ($others | Where-Object { $_.Contains($url) -or $url.Contains($_) }) } |
        Group-Object Url | ForEach-Object { $_.Group[0] })
    # The first live strong candidate replaces the url; a live weak one (a name match in a directory without a
    # country) is only suggested: the same name is often another station (round one, 2026-09-29).
    $newUrl = $null
    $source = $null
    $weakOnly = $false
    if ($unique) {
        $entries = for ($i = 0; $i -lt $unique.Count; $i++) {
            [pscustomobject]@{ Title = "candidate $i"; Url = $unique[$i].Url; Guid = "$i" }
        }
        $verdicts = Invoke-StreamProbe $entries "candidates-$($station.Guid)"
        $alive = @(for ($i = 0; $i -lt $unique.Count; $i++) {
            if (($verdicts | Where-Object Guid -eq "$i").Verdict -eq 'alive') { $unique[$i] }
        })
        $best = @($alive | Where-Object Strong) + @($alive | Where-Object { -not $_.Strong }) | Select-Object -First 1
        if ($best) {
            $newUrl = $best.Url
            $source = $best.Source
            $weakOnly = -not $best.Strong
        }
    }

    $held = $newUrl -and ($weakOnly -or ($ReplaceOnlyDead -and $station.Verdict -ne 'dead'))
    [pscustomobject]@{
        Title      = $station.Title
        Guid       = $station.Guid
        OldUrl     = $station.Url
        OldVerdict = $station.Verdict
        NewUrl     = if ($held) { $null } else { $newUrl }
        Suggested  = if ($held) { $newUrl } else { $null }
        Source     = $source
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
if ($fixed -and $PSCmdlet.ShouldProcess($Catalog, "Update $($fixed.Count) station url(s)")) {
    $null = $text | ConvertFrom-Json
    [IO.File]::WriteAllText($Catalog, $text, [Text.UTF8Encoding]::new($hasBom))
}

# 5: the report.
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Probed $(@($toProbe).Count) stations; $($results.Count) failed twice; $($fixed.Count) fixed.")
$lines.Add('')
if ($fixed) {
    $lines.Add('## Fixed')
    $lines.Add('')
    $lines.Add('| Station | Was | Old url | New url | Found on |')
    $lines.Add('| :--- | :--- | :--- | :--- | :--- |')
    foreach ($fix in $fixed) { $lines.Add("| $($fix.Title) | $($fix.OldVerdict) | ``$($fix.OldUrl)`` | ``$($fix.NewUrl)`` | $($fix.Source) |") }
    $lines.Add('')
}
$review = @($results | Where-Object Suggested)
if ($review) {
    $lines.Add('## Needs review (url kept): not an outright failure from here, or found only by name in a directory')
    $lines.Add('')
    $lines.Add('| Station | Verdict here | Url | Candidate | Found on |')
    $lines.Add('| :--- | :--- | :--- | :--- | :--- |')
    foreach ($item in $review) { $lines.Add("| $($item.Title) | $($item.OldVerdict) | ``$($item.OldUrl)`` | ``$($item.Suggested)`` | $($item.Source) |") }
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
$report = $lines -join "`n"
if ($ReportPath) { Set-Content -Path $ReportPath -Value $report -Encoding utf8 }
Write-Host $report
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
$results
