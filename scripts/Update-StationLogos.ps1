#Requires -Version 7.0
<#
.SYNOPSIS
    Finds a logo for every station that has none and adds it to RadioLogos/ and the catalogue.

.DESCRIPTION
    The weekly refresh (.github/workflows/refresh-stations.yml) runs this after the url refresh:

      1. List the stations without a logo: no ImageUrl, or an ImageUrl that names no file of RadioLogos (the
         name compared with its case: GitHub Pages serves these files to the apps, and it is case-sensitive).
      2. Collect candidate images, each tied to the station by more than its name:
           a. radio-browser.info entries whose stream url is the station's url, or whose name is the station's
              title, whose country is Romania or Moldova and whose homepage or stream host carries the station's
              name (the rule Update-StationUrls.ps1 uses): their favicon, and the icons the homepage declares
              (apple-touch-icon, icons of at least -MinSize px)
           b. the station's page on myradioonline.ro (its logo, 250x250): strong when the page's player streams
              from the station's own host, a suggestion only otherwise - a page with the same name is not proof
              (round one of the url search matched "Flash FM" to a game radio)
      3. Download each one (every hop checked and pinned, lib/Net.ps1) and check it (lib/normalize_logo.py): an
         image, at least -MinSize px on its short side, logo-shaped, not blank. The first good strong candidate
         becomes the station's logo: a PNG of at most 400 px, named after the station (<slug>.png).
      4. The same image found for several stations is a directory's placeholder, not their logo: none of them
         gets it.
      5. Write the files and the ImageUrl lines, and a Markdown report (-ReportPath).

    An existing logo is never replaced or renamed: released apps older than the Pages fallback (RoRadio 2.0.1,
    1.6.x) only know the logos they bundle, by name. Only ImageUrl changes, inside the station's own block; the
    file keeps its encoding and line endings.

    Needs Python 3 with Pillow (pip install pillow) and curl.

.PARAMETER Catalog
    The station list. Default: RadioStationsData.json next to this folder.

.PARAMETER LogoFolder
    The logo folder. Default: RadioLogos next to this folder.

.PARAMETER ReportPath
    Where to write the Markdown report. Default: none (the report is written to the output only).

.PARAMETER ImageBase
    What the report puts before a logo's file name to show it. Default: ../../RadioLogos/, right for a report kept
    in docs/releases/; the workflow gives the pull request body the commit's raw url instead.

.PARAMETER Title
    Consider only these stations (titles, compared without diacritics and case). Default: all of them.

.PARAMETER MinSize
    The smallest short side, in pixels, of an image taken as a logo. Station tiles show logos at about 150 px.

.PARAMETER Python
    The Python 3 command. Default: python on Windows, python3 elsewhere.

.OUTPUTS
    One object per station without a logo: Title, Guid, File, Source, Suggested, Tried, Reasons.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Catalog,
    [string]$LogoFolder,
    [string]$ReportPath,
    [string]$ImageBase = '../../RadioLogos/',
    [string[]]$Title,
    [int]$MinSize = 128,
    [string]$Python
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Catalog) { $Catalog = Join-Path $root 'RadioStationsData.json' }
if (-not $LogoFolder) { $LogoFolder = Join-Path $root 'RadioLogos' }
$Catalog = (Resolve-Path $Catalog).Path
$LogoFolder = (Resolve-Path $LogoFolder).Path
# Not "python3" on Windows: there it is the Microsoft Store's installer stub unless Python came from the Store.
if (-not $Python) { $Python = if ($IsWindows) { 'python' } else { 'python3' } }
$normalizer = Join-Path $PSScriptRoot 'lib/normalize_logo.py'
& $Python -c 'import PIL' 2>$null
if ($LASTEXITCODE -ne 0) { throw "Python 3 with Pillow is needed: '$Python -m pip install pillow'." }
. (Join-Path $PSScriptRoot 'lib/Net.ps1')
. (Join-Path $PSScriptRoot 'lib/Names.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) "roradio-logos-$PID"
New-Item -ItemType Directory -Force -Path $scratch -WhatIf:$false | Out-Null

# A web page from a host the directories named (a station's homepage): read like a stream, every hop checked.
function Get-PublicPage([string]$Url) {
    $file = Join-Path $scratch 'page.html'
    $final = Save-PublicFile $Url $file -MaxBytes 2MB
    $text = if ($final) { [IO.File]::ReadAllText($file) } else { '' }
    Remove-Item $file -ErrorAction SilentlyContinue -WhatIf:$false
    [pscustomobject]@{ Text = $text; Final = $final }
}

# The icons a page declares that can be a logo: apple-touch-icon (180 px, the site's own logo), and icons whose
# declared size reaches -MinSize. og:image is left out: on radio sites it is a show's photo or a banner.
function Get-DeclaredIcon([string]$Html, [string]$Base) {
    # Script blocks, never `ForEach-Object Value`: under -WhatIf the member form only says what it would do and
    # returns nothing (the first dry run found no icon at all).
    foreach ($tag in [regex]::Matches($Html, '<link\b[^>]*>', 'IgnoreCase') | ForEach-Object { $_.Value }) {
        if ($tag -notmatch '\brel\s*=\s*["'']([^"'']+)' ) { continue }
        $rel = $Matches[1].ToLowerInvariant()
        if ($tag -notmatch '\bhref\s*=\s*["'']([^"'']+)') { continue }
        $href = [Net.WebUtility]::HtmlDecode($Matches[1])
        $large = $tag -match '\bsizes\s*=\s*["'']?(\d+)x\d+' -and [int]$Matches[1] -ge $MinSize
        if ($rel -match 'apple-touch-icon' -or ($rel -match '\bicon\b' -and $large)) {
            try { [Uri]::new([Uri]$Base, $href).AbsoluteUri } catch { Write-Verbose "Unusable icon url '$href' on $Base" }
        }
    }
}

function ConvertTo-Candidate([string]$Url, [string]$Source, [bool]$Strong) {
    [pscustomobject]@{ Url = $Url; Source = $Source; Strong = $Strong }
}

# 1: the stations without a logo.
$files = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem $LogoFolder -File) { $null = $files.Add($file.Name) }
$stations = foreach ($category in (Get-Content $Catalog -Raw -Encoding utf8 | ConvertFrom-Json)) {
    foreach ($station in $category.List) {
        [pscustomobject]@{ Title = $station.Title; Url = $station.Url; Guid = $station.GUID; ImageUrl = $station.ImageUrl }
    }
}
$missing = @($stations | Where-Object { -not $_.ImageUrl -or -not $files.Contains($_.ImageUrl) })
if ($Title) {
    $wanted = @($Title | ForEach-Object { ConvertTo-PlainTitle $_ })
    $missing = @($missing | Where-Object { $wanted -contains (ConvertTo-PlainTitle $_.Title) })
}
Write-Information "$($missing.Count) of $(@($stations).Count) station(s) have no logo." -InformationAction Continue

$slugs = if ($missing) { Get-MyRadioOnlineSitemap } else { @() }
$notStream = '\.(png|jpe?g|webp|gif|svg|ico|css|js|json|html?)(\?|$)|google|facebook|apple\.com|twitter|instagram|youtube|myradioonline|schema\.org|w3\.org'
$counter = 0

# 2 and 3: candidates, checked one by one.
$results = foreach ($station in $missing) {
    $candidates = [Collections.Generic.List[object]]::new()
    $stationHost = Get-UrlHost $station.Url
    $plainTitle = ConvertTo-PlainTitle $station.Title
    $marks = Get-NameMark $station.Title

    $byUrl = Get-OptionalJson "https://de1.api.radio-browser.info/json/stations/byurl?url=$([Uri]::EscapeDataString($station.Url))"
    $byName = Get-OptionalJson "https://de1.api.radio-browser.info/json/stations/search?hidebroken=true&limit=50&name=$([Uri]::EscapeDataString($station.Title))"
    $entries = @(@($byUrl) | Where-Object { $_ }) + @(@($byName) | Where-Object {
        $_ -and (ConvertTo-PlainTitle $_.name) -eq $plainTitle -and $_.countrycode -in 'RO', 'MD' -and
            ($marks | Where-Object { $mark = $_; @($_.homepage, $_.url_resolved) | Where-Object { $_ -and (Get-UrlHost $_).Replace('-', '').Contains($mark) } })
    })
    foreach ($entry in ($entries | Group-Object stationuuid | ForEach-Object { $_.Group[0] })) {
        if ($entry.favicon) { $candidates.Add((ConvertTo-Candidate -Url $entry.favicon -Source "radio-browser.info favicon ($($entry.name))" -Strong $true)) }
        if ($entry.homepage) {
            $page = Get-PublicPage $entry.homepage
            foreach ($icon in @(Get-DeclaredIcon $page.Text $page.Final)) {
                $candidates.Add((ConvertTo-Candidate -Url $icon -Source "homepage icon ($(Get-UrlHost $page.Final))" -Strong $true))
            }
        }
    }

    foreach ($pageSlug in Get-MyRadioOnlineSlug $station.Title $slugs) {
        $page = Get-Text "https://myradioonline.ro/$pageSlug"
        $streamHosts = @([regex]::Matches($page, '(?:src|url)="(https?://[^"]+)"') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } |
            Where-Object { $_ -notmatch $notStream } | ForEach-Object { Get-UrlHost $_ })
        $own = $stationHost -and $streamHosts -contains $stationHost
        foreach ($logo in [regex]::Matches($page, '<link itemprop="logo" href="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) {
            $candidates.Add((ConvertTo-Candidate -Url $logo -Source "myradioonline.ro/$pageSlug" -Strong $own))
        }
    }

    $ordered = @($candidates | Where-Object Strong) + @($candidates | Where-Object { -not $_.Strong }) | Group-Object Url | ForEach-Object { $_.Group[0] }
    $chosen = $null
    $suggested = $null
    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $ordered) {
        if ($chosen -or ($suggested -and -not $candidate.Strong)) { break }
        $counter++
        $raw = Join-Path $scratch "raw-$counter"
        $png = Join-Path $scratch "logo-$counter.png"
        if (-not (Save-PublicFile $candidate.Url $raw)) { $reasons.Add("$($candidate.Source): not downloaded"); continue }
        $check = & $Python $normalizer $raw $png $MinSize | ConvertFrom-Json
        if (-not $check.ok) { $reasons.Add("$($candidate.Source): $($check.reason)"); continue }
        $found = [pscustomobject]@{ Url = $candidate.Url; Source = $candidate.Source; Png = $png; Sha = $check.sha256; Size = "$($check.width)x$($check.height)" }
        if ($candidate.Strong) { $chosen = $found } else { $suggested = $found }
    }

    [pscustomobject]@{
        Title     = $station.Title
        Guid      = $station.Guid
        OldImage  = $station.ImageUrl
        Chosen    = $chosen
        Suggested = $suggested
        Tried     = @($ordered).Count
        Reasons   = $reasons -join '; '
        File      = $null
    }
}
$results = @($results)

# 4: one image for several stations is a placeholder.
$shared = @($results | Where-Object Chosen | Group-Object { $_.Chosen.Sha } | Where-Object Count -gt 1 | ForEach-Object { $_.Name })
foreach ($result in $results | Where-Object { $_.Chosen -and $shared -contains $_.Chosen.Sha }) {
    $result.Reasons = "$($result.Chosen.Source): the same image as other stations (a placeholder)"
    $result.Chosen = $null
}

# 5: file names, then the files and the ImageUrl lines, each inside the station's own block (found by its GUID).
$taken = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $files) { $null = $taken.Add($name) }
$added = @($results | Where-Object Chosen)
foreach ($result in $added) {
    $slug = ConvertTo-Slug $result.Title
    $name = "$slug.png"
    for ($n = 2; $taken.Contains($name); $n++) { $name = "$slug-$n.png" }
    $null = $taken.Add($name)
    $result.File = $name
}

$bytes = [IO.File]::ReadAllBytes($Catalog)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [Text.UTF8Encoding]::new($false).GetString($bytes).TrimStart([char]0xFEFF)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
foreach ($result in $added) {
    $block = '("GUID":\s*"' + [regex]::Escape($result.Guid) + '"[^}]*?'
    $value = ($result.File | ConvertTo-Json).Replace('$', '$$')
    $updated = if ($result.OldImage) {
        [regex]::Replace($text, $block + '"ImageUrl":\s*)"(?:[^"\\]|\\.)*"', '${1}' + $value)
    } else {
        # A new line after the Url line, with its indentation: '"Url": "...",' + '"ImageUrl": "...",' + the rest.
        [regex]::Replace($text, $block + '(?<indent>[ \t]*)"Url":\s*"(?:[^"\\]|\\.)*")', '${1}' + ",$newline" + '${indent}"ImageUrl": ' + $value)
    }
    if ($updated -eq $text) { throw "Could not write the ImageUrl of '$($result.Title)' ($($result.Guid))." }
    $text = $updated
}
if ($added -and $PSCmdlet.ShouldProcess($Catalog, "Add $($added.Count) station logo(s)")) {
    $null = $text | ConvertFrom-Json
    foreach ($result in $added) { Copy-Item $result.Chosen.Png (Join-Path $LogoFolder $result.File) }
    [IO.File]::WriteAllText($Catalog, $text, [Text.UTF8Encoding]::new($hasBom))
}

# The report.
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("$($missing.Count) station(s) without a logo; $($added.Count) logo(s) added.")
$lines.Add('')
if ($added) {
    $lines.Add('## Logos added')
    $lines.Add('')
    $lines.Add('| Logo | Station | File | Size | Found on |')
    $lines.Add('| :---: | :--- | :--- | :--- | :--- |')
    foreach ($result in $added) {
        $image = "<img src=""$ImageBase$($result.File)"" width=""64"" alt=""$($result.Title)"">"
        $lines.Add("| $image | $($result.Title) | ``$($result.File)`` | $($result.Chosen.Size) | [$($result.Chosen.Source)]($($result.Chosen.Url)) |")
    }
    $lines.Add('')
}
$review = @($results | Where-Object { -not $_.Chosen -and $_.Suggested })
if ($review) {
    $lines.Add('## Suggested logos (not added: found by the name only)')
    $lines.Add('')
    $lines.Add('| Candidate | Station | Found on |')
    $lines.Add('| :---: | :--- | :--- |')
    foreach ($result in $review) {
        $image = "<img src=""$($result.Suggested.Url)"" width=""64"" alt=""candidate for $($result.Title)"">"
        $lines.Add("| $image | $($result.Title) | [$($result.Suggested.Source)]($($result.Suggested.Url)) |")
    }
    $lines.Add('')
}
$none = @($results | Where-Object { -not $_.Chosen -and -not $_.Suggested })
if ($none) {
    $lines.Add('## No logo found')
    $lines.Add('')
    $lines.Add('| Station | Candidates | Why not |')
    $lines.Add('| :--- | :--- | :--- |')
    foreach ($result in $none) { $lines.Add("| $($result.Title) | $($result.Tried) | $($result.Reasons) |") }
    $lines.Add('')
}
$report = $lines -join "`n"
if ($ReportPath) { Set-Content -Path $ReportPath -Value $report -Encoding utf8 -WhatIf:$false }
Write-Information $report -InformationAction Continue
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue -WhatIf:$false
$results | ForEach-Object {
    [pscustomobject]@{
        Title     = $_.Title
        Guid      = $_.Guid
        File      = $_.File
        Source    = $_.Chosen.Source
        Suggested = $_.Suggested.Url
        Tried     = $_.Tried
        Reasons   = $_.Reasons
    }
}
