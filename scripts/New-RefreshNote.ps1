#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the release note of a weekly refresh (docs/releases/<date>-refresh.md) from the url and logo reports,
    and the same text as the pull request body.

.DESCRIPTION
    Every change to the station list is described once, in docs/releases: what changed, where each url or logo
    was found, and the logos themselves. The note in the repository shows the logos by relative path
    (../../RadioLogos/<file>), which GitHub renders when the file is viewed; the pull request body cannot use a
    relative path, so its copy points at the commit's raw files instead (-ImageBase).

.PARAMETER UrlReport
    The Markdown report of Update-StationUrls.ps1.

.PARAMETER LogoReport
    The Markdown report of Update-StationLogos.ps1; none when the logo refresh did not run.

.PARAMETER Path
    Where to write the note.

.PARAMETER Date
    The refresh's date (yyyy-MM-dd). Default: today, UTC.

.PARAMETER RunUrl
    The workflow run the note came from.

.PARAMETER ImageBase
    What replaces ../../RadioLogos/ in the written copy. Default: nothing replaced (the repository's copy).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$UrlReport,
    [string]$LogoReport,
    [Parameter(Mandatory)] [string]$Path,
    [string]$Date = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture),
    [string]$RunUrl,
    [string]$ImageBase
)

$ErrorActionPreference = 'Stop'

# A report as a section of the note: its headings one level down, no blank line at either end.
function Get-Section([string]$Report) {
    $text = (Get-Content -Path $Report -Raw -Encoding utf8).Trim()
    ($text -split "`r?`n" | ForEach-Object { if ($_ -match '^#{2,5} ') { "#$_" } else { $_ } }) -join "`n"
}

$parts = [Collections.Generic.List[string]]::new()
$parts.Add("# Station refresh, $Date")
$source = if ($RunUrl) { "the weekly refresh ([run]($RunUrl))" } else { 'the weekly refresh' }
$parts.Add("What $source changed in the station list. Every RoRadio app downloads the list from GitHub Pages, so these changes reach listeners without an app update; logos the app does not bundle come from Pages too.")
$parts.Add('## Stream urls')
$parts.Add((Get-Section $UrlReport))
if ($LogoReport -and (Test-Path $LogoReport)) {
    $parts.Add('## Logos')
    $parts.Add((Get-Section $LogoReport))
}

$note = ($parts -join "`n`n") -replace "(`n){3,}", "`n`n"
if ($ImageBase) { $note = $note.Replace('../../RadioLogos/', $ImageBase) }
$folder = Split-Path $Path -Parent
if ($folder) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
[IO.File]::WriteAllText($Path, "$note`n", [Text.UTF8Encoding]::new($false))
