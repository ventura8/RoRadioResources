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
      4. Probe the candidates. The first one that is alive replaces the url. Nothing is written on a guess:
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
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

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
    ConvertTo-Json -InputObject @([ordered]@{ Name = $Name; List = $list }) -Depth 5 | Set-Content -Path $path -Encoding utf8
    @(& $probeScript -Catalog $path @probeSettings)
}

function Get-Text([string]$Url) {
    try {
        (Invoke-WebRequest -Uri $Url -UserAgent $userAgent -TimeoutSec 30 -MaximumRetryCount 2).Content
    } catch {
        Write-Warning "Could not read ${Url}: $($_.Exception.Message)"
        ''
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
            if ($url -notmatch $notStream) { $candidates.Add([pscustomobject]@{ Url = $url; Source = "myradioonline.ro/$pageSlug" }) }
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
            $candidates.Add([pscustomobject]@{ Url = $entry.url_resolved; Source = "radio-browser.info ($($entry.homepage))" })
        }
    }

    # RoRadio's unit tests require every url to be unique and none to contain another: a candidate that is
    # another station's stream means the broadcaster merged the two channels, which is the owner's call.
    $others = @($stations | Where-Object Guid -ne $station.Guid | ForEach-Object Url)
    $unique = @($candidates |
        Where-Object { $url = $_.Url; $url -ne $station.Url -and -not ($others | Where-Object { $_.Contains($url) -or $url.Contains($_) }) } |
        Group-Object Url | ForEach-Object { $_.Group[0] })
    $newUrl = $null
    $source = $null
    if ($unique) {
        $entries = for ($i = 0; $i -lt $unique.Count; $i++) {
            [pscustomobject]@{ Title = "candidate $i"; Url = $unique[$i].Url; Guid = "$i" }
        }
        $verdicts = Invoke-StreamProbe $entries "candidates-$($station.Guid)"
        for ($i = 0; $i -lt $unique.Count -and -not $newUrl; $i++) {
            if (($verdicts | Where-Object Guid -eq "$i").Verdict -eq 'alive') {
                $newUrl = $unique[$i].Url
                $source = $unique[$i].Source
            }
        }
    }

    $held = $newUrl -and $ReplaceOnlyDead -and $station.Verdict -ne 'dead'
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
    $lines.Add('## Needs review from Romania (not an outright failure; url kept)')
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
