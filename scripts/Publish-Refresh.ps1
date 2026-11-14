#Requires -Version 7.0
<#
.SYNOPSIS
    Publishes a weekly refresh: the release note, the pull request (opened and merged), and the issue that lists the
    stations the refresh could not fix.

.DESCRIPTION
    The last step of .github/workflows/refresh-stations.yml, after Update-StationUrls.ps1, Update-StationLogos.ps1
    and the tests:

      1. Writes the release note docs/releases/<date>-refresh.md from the reports (New-RefreshNote.ps1) and adds it
         to the run's summary.
      2. Keeps the issue "Stations the weekly refresh could not fix" current: the stations that need review, the
         unresolved ones and the sources that could not be read, or closes it when there are none. Before
         2026-11-14 those lists lived only in the run's summary, where nobody read them: the same stations stayed
         dead for weeks.
      3. When something changed: commits the list, the logos and the note to -Branch, pushes it, opens (or updates)
         the pull request whose body is the note with the logos read from that commit, and squash-merges it when
         -Merge is set and the change is small enough (-MaxUrls, -MaxLogos); otherwise it says why on the pull
         request. After the merge it asks GitHub Pages to rebuild.

    Every git and gh command is checked: a failure stops the step and fails the run.

.PARAMETER UrlReport
    The Markdown report of Update-StationUrls.ps1.

.PARAMETER LogoReport
    The Markdown report of Update-StationLogos.ps1; none when the logo refresh did not run.

.PARAMETER UrlCount
    How many urls Update-StationUrls.ps1 changed.

.PARAMETER LogoCount
    How many logos Update-StationLogos.ps1 added.

.PARAMETER Merge
    Merge the pull request when the change is small enough.

.PARAMETER AutoMerge
    With -Merge: turn on GitHub's auto-merge instead of merging at once, so that the merge waits for the checks
    master's branch protection requires (Lint, Tests). The workflow passes it when it pushes with the REFRESH_TOKEN
    secret: a pull request pushed with GITHUB_TOKEN starts no CI, and its required checks would never report. GitHub
    Pages rebuilds from the merge on its own.

.PARAMETER MaxUrls
    More url fixes than this in one run means the runner's network, not the stations, is the problem: the pull
    request stays open for a human.

.PARAMETER MaxLogos
    More new logos than this at once is worth a look before every listener sees them.

.PARAMETER Repository
    owner/name. Default: GH_REPO.

.PARAMETER RunUrl
    The workflow run, linked from the note.

.PARAMETER Date
    The refresh's date (yyyy-MM-dd). Default: today, UTC.

.PARAMETER Branch
    The pull request's branch.

.PARAMETER Base
    The branch it merges into.

.PARAMETER RepositoryPath
    The checkout. Default: the folder above this one.

.PARAMETER Remote
    Where the branch is pushed. Default: the repository on github.com, with GH_TOKEN.

.PARAMETER SummaryPath
    The run's summary. Default: GITHUB_STEP_SUMMARY.

.PARAMETER TempFolder
    Where the pull request body and the issue body are written. Default: RUNNER_TEMP, else the system's temp folder.

.PARAMETER Gh
    The GitHub CLI (the tests give a fake one).

.PARAMETER Git
    git.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$UrlReport,
    [string]$LogoReport,
    [int]$UrlCount,
    [int]$LogoCount,
    [switch]$Merge,
    [switch]$AutoMerge,
    [int]$MaxUrls = 15,
    [int]$MaxLogos = 20,
    [string]$Repository = $env:GH_REPO,
    [string]$RunUrl,
    [string]$Date = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture),
    [string]$Branch = 'automation/station-refresh',
    [string]$Base = 'master',
    [string]$RepositoryPath,
    [string]$Remote,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$TempFolder,
    [string]$Gh = 'gh',
    [string]$Git = 'git'
)

$ErrorActionPreference = 'Stop'
$RepositoryPath = @($RepositoryPath, (Split-Path $PSScriptRoot -Parent)) | Where-Object { $_ } | Select-Object -First 1
$TempFolder = @($TempFolder, $env:RUNNER_TEMP, [IO.Path]::GetTempPath()) | Where-Object { $_ } | Select-Object -First 1
$issueTitle = 'Stations the weekly refresh could not fix'
if (-not $Remote) { $Remote = "https://x-access-token:$($env:GH_TOKEN)@github.com/$Repository.git" }

# Runs git or gh and stops on a failure. The message names the command and its first two arguments after git's -C
# folder, nothing more: the push url carries the token.
function Invoke-Tool([string]$Command, [string[]]$Arguments) {
    $output = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        $shown = @($Arguments | Select-Object -Skip (2 * [int]($Arguments[0] -eq '-C')) -First 2)
        throw "$(Split-Path $Command -Leaf) $($shown -join ' ') failed (exit $LASTEXITCODE)."
    }
    $output
}

$summaryFile = $SummaryPath
$noteArguments = @{ UrlReport = $UrlReport; Date = $Date; RunUrl = $RunUrl }
if ($LogoReport -and (Test-Path $LogoReport)) { $noteArguments.LogoReport = $LogoReport }

function Add-Summary([string]$Text) {
    if ($summaryFile) { Add-Content -Path $summaryFile -Value $Text -Encoding utf8 }
    Write-Information $Text -InformationAction Continue
}

function Write-Note([string]$Path, [string]$ImageBase) {
    & (Join-Path $PSScriptRoot 'New-RefreshNote.ps1') @noteArguments -Path $Path -ImageBase $ImageBase
}

# The part of the url report a human has to act on: everything from its first section that is not "Fixed".
function Get-OpenWork {
    $text = (Get-Content -Path $noteArguments.UrlReport -Raw -Encoding utf8).Trim()
    $start = [regex]::Match($text, '(?m)^## (?!Fixed)')
    if ($start.Success) { $text.Substring($start.Index) }
}

# 1: the release note.
$note = "docs/releases/$Date-refresh.md"
Write-Note (Join-Path $RepositoryPath $note) ''
Add-Summary (Get-Content -Path (Join-Path $RepositoryPath $note) -Raw -Encoding utf8)

# 2: the issue.
$open = @(Invoke-Tool $Gh @('issue', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title') | ConvertFrom-Json |
    Where-Object title -eq $issueTitle)
$work = Get-OpenWork
if ($work) {
    $issueBody = Join-Path $TempFolder 'refresh-issue.md'
    $run = @('the weekly refresh', "the weekly refresh ([run]($RunUrl))")[[int][bool]$RunUrl]
    $intro = "What $run of $Date could not fix. A station here keeps its url until someone fixes it: RoRadio's fix-failing-stations skill, or a pull request that changes RadioStationsData.json. This issue is rewritten by every refresh and closed by the first one that leaves nothing here."
    [IO.File]::WriteAllText($issueBody, "$intro`n`n$work`n", [Text.UTF8Encoding]::new($false))
    if ($open) {
        Invoke-Tool $Gh @('issue', 'edit', "$($open[0].number)", '--body-file', $issueBody) | Out-Null
    } else {
        Invoke-Tool $Gh @('issue', 'create', '--title', $issueTitle, '--body-file', $issueBody) | Out-Null
    }
    Add-Summary "Stations left for a human: issue '$issueTitle'."
} elseif ($open) {
    Invoke-Tool $Gh @('issue', 'close', "$($open[0].number)", '--comment', "The refresh of $Date left nothing to fix.") | Out-Null
}

if ($UrlCount -eq 0 -and $LogoCount -eq 0) {
    Add-Summary 'Nothing changed.'
    return
}

# 3: the pull request.
$title = "Refresh $UrlCount station url(s) and $LogoCount logo(s) ($Date)"
Invoke-Tool $Git @('-C', $RepositoryPath, 'config', 'user.name', 'github-actions[bot]') | Out-Null
Invoke-Tool $Git @('-C', $RepositoryPath, 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com') | Out-Null
Invoke-Tool $Git @('-C', $RepositoryPath, 'switch', '-q', '-C', $Branch) | Out-Null
Invoke-Tool $Git @('-C', $RepositoryPath, 'add', 'RadioStationsData.json', 'RadioLogos', $note) | Out-Null
Invoke-Tool $Git @('-C', $RepositoryPath, 'commit', '-q', '-m', $title) | Out-Null
Invoke-Tool $Git @('-C', $RepositoryPath, 'push', '-q', '--force', $Remote, "HEAD:refs/heads/$Branch") | Out-Null

# The pull request body is the same note, its logos read from this commit (a relative path does not render there;
# the commit stays reachable through the pull request after the branch is deleted).
$sha = "$(Invoke-Tool $Git @('-C', $RepositoryPath, 'rev-parse', 'HEAD'))".Trim()
$body = Join-Path $TempFolder 'refresh-body.md'
Write-Note $body "https://raw.githubusercontent.com/$Repository/$sha/RadioLogos/"
$state = "$(& $Gh pr view $Branch --json state --jq .state 2>$null)".Trim()
if ($state -eq 'OPEN') {
    Invoke-Tool $Gh @('pr', 'edit', $Branch, '--title', $title, '--body-file', $body) | Out-Null
} else {
    Invoke-Tool $Gh @('pr', 'create', '--base', $Base, '--head', $Branch, '--title', $title, '--body-file', $body) | Out-Null
}

if (-not $Merge) {
    Add-Summary 'Merge not requested: the pull request stays open.'
} elseif ($UrlCount -gt $MaxUrls -or $LogoCount -gt $MaxLogos) {
    $reason = "$UrlCount urls and $LogoCount logos changed, more than $MaxUrls urls or $MaxLogos logos: not merged automatically."
    Invoke-Tool $Gh @('pr', 'comment', $Branch, '--body', "$reason Check the urls from Romania and look at the logos before merging.") | Out-Null
    Add-Summary $reason
} elseif ($AutoMerge) {
    Invoke-Tool $Gh @('pr', 'merge', $Branch, '--auto', '--squash', '--delete-branch') | Out-Null
    Add-Summary 'Auto-merge is on: GitHub merges the pull request once the required checks (Lint, Tests) pass.'
} else {
    Invoke-Tool $Gh @('pr', 'merge', $Branch, '--squash', '--delete-branch') | Out-Null
    & $Gh api -X POST "repos/$Repository/pages/builds" --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Could not request a Pages build.'
        Add-Summary 'Could not request a Pages build: GitHub Pages rebuilds from the merge on its own, a few minutes later.'
    }
    Add-Summary 'Merged.'
}
