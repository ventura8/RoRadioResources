#Requires -Version 7.0
<#
.SYNOPSIS
    Publishes a weekly refresh: the release note, the pull request (opened and merged), and the issue that lists the
    stations the refresh could not fix.

.DESCRIPTION
    The last stage of scripts/Invoke-Refresh.ps1, after the urls, the logos, the retirements and the tests:

      1. Writes the release note docs/releases/<date>-refresh.md from the reports (New-RefreshNote.ps1) and adds it
         to the run's summary.
      2. Keeps the issue "Stations the weekly refresh could not fix" current: the stations that need review, the
         unresolved and failing ones, the retired, restored and rechecked ones, the sources that could not be read,
         the refresh's own pull request when its CI fails, and the trend of the last runs (-MetricsPath). It is
         closed when there is nothing left.
      3. When something changed: commits the list, RetiredStations.json, the logos and the note to -Branch on top of
         the newest -Base (a base that moved is rebased onto), pushes it, opens (or updates) the pull request whose
         body is the note with the logos read from that commit, and merges it when -Merge is set and the change is
         small enough (-MaxUrls, -MaxLogos); otherwise it says why on the pull request.
      4. When nothing changed and a refresh pull request from an earlier run is still open: closes it, since master
         needs nothing from it any more.

    Every git and gh command is checked; gh commands are tried three times with a growing pause (the API can be
    rate-limited or down for a moment). A token that cannot read the repository stops the stage with that reason.

.PARAMETER UrlReport
    The Markdown report of Update-StationUrls.ps1 (with Update-StationLifecycle.ps1's report after it).

.PARAMETER LogoReport
    The Markdown report of Update-StationLogos.ps1; none when the logo refresh did not run.

.PARAMETER UrlCount
    How many urls Update-StationUrls.ps1 changed.

.PARAMETER LogoCount
    How many logos Update-StationLogos.ps1 added.

.PARAMETER StationCount
    How many stations Update-StationLifecycle.ps1 retired, restored or rechecked. A failed recheck changes only the
    date of the next one in RetiredStations.json, and that change is published too: otherwise the next run, from a
    fresh checkout, would recheck again at once instead of waiting 60, 90 or 120 days (Greptile, #44).

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

.PARAMETER MetricsPath
    The runs' metrics (metrics/runs.jsonl): their trend goes into the issue and the summary.

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

.PARAMETER RetryDelaySeconds
    The first pause before a gh command is tried again (then twice as long).

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
    [int]$StationCount,
    [switch]$Merge,
    [switch]$AutoMerge,
    [int]$MaxUrls = 15,
    [int]$MaxLogos = 20,
    [string]$MetricsPath,
    [string]$Repository = $env:GH_REPO,
    [string]$RunUrl,
    [string]$Date = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture),
    [string]$Branch = 'automation/station-refresh',
    [string]$Base = 'master',
    [string]$RepositoryPath,
    [string]$Remote,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$TempFolder,
    [double]$RetryDelaySeconds = 5,
    [string]$Gh = 'gh',
    [string]$Git = 'git'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Resilience.ps1')
. (Join-Path $PSScriptRoot 'lib/Telemetry.ps1')
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

# Every issue and pull request command names -Repository: gh would otherwise take GH_REPO or the current folder's
# remote, while git works on -RepositoryPath (Greptile and CodeRabbit, #38). Tried three times: the API can be down or
# rate-limited for a moment.
function Invoke-Gh([string[]]$Arguments) {
    $all = $Arguments + @('--repo', $Repository)
    Invoke-WithRetry -What "gh $($Arguments[0..1] -join ' ')" -BaseDelaySeconds $RetryDelaySeconds { Invoke-Tool $Gh $all }
}

function Invoke-Git([string[]]$Arguments) {
    Invoke-Tool $Git (@('-C', $RepositoryPath) + $Arguments)
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

# 0: a token that cannot read the repository stops here, with that reason, before anything is written.
try {
    $null = Invoke-WithRetry -What 'gh api' -BaseDelaySeconds $RetryDelaySeconds { Invoke-Tool $Gh @('api', "repos/$Repository", '--jq', '.full_name') }
} catch {
    throw "The GitHub token cannot read $Repository (missing, expired or without access): $($_.Exception.Message) Set the REFRESH_TOKEN secret again."
}

# 1: the release note.
$note = "docs/releases/$Date-refresh.md"
Write-Note (Join-Path $RepositoryPath $note) ''
Add-Summary (Get-Content -Path (Join-Path $RepositoryPath $note) -Raw -Encoding utf8)

# The refresh's own pull request from an earlier run, and whether its CI fails.
$state = "$(& $Gh pr view $Branch --json state --jq .state --repo $Repository 2>$null)".Trim()
$failingChecks = @()
if ($state -eq 'OPEN') {
    $failingChecks = @(Invoke-Gh @('pr', 'checks', $Branch, '--json', 'name,bucket') | ConvertFrom-Json | Where-Object bucket -eq 'fail' | ForEach-Object { $_.name })
}

# 2: the issue.
$open = @(Invoke-Gh @('issue', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title') | ConvertFrom-Json |
    Where-Object title -eq $issueTitle)
$work = @(Get-OpenWork)
if ($failingChecks) {
    $work += "## The refresh's own pull request fails CI`n`nChecks failing on ``$Branch``: $($failingChecks -join ', '). It stays open; the next run pushes a new commit to it, and its checks run again."
    Add-Summary "The open refresh pull request fails: $($failingChecks -join ', ')."
}
$trend = @(Format-RunTrend $MetricsPath)
if ($trend) { Add-Summary $trend[0] }
if ($work) {
    $issueBody = Join-Path $TempFolder 'refresh-issue.md'
    $run = @('the weekly refresh', "the weekly refresh ([run]($RunUrl))")[[int][bool]$RunUrl]
    $intro = "What $run of $Date could not fix, and what it retired or restored. A failing station is retired by itself after its days are up, and retired stations are rechecked on a growing schedule; one no source can fix can be fixed by hand: RoRadio's fix-failing-stations skill, or a pull request that changes RadioStationsData.json. This issue is rewritten by every refresh and closed by the first one that leaves nothing here."
    [IO.File]::WriteAllText($issueBody, ((@($intro) + $work + $trend) -join "`n`n") + "`n", [Text.UTF8Encoding]::new($false))
    if ($open) {
        Invoke-Gh @('issue', 'edit', "$($open[0].number)", '--body-file', $issueBody) | Out-Null
    } else {
        Invoke-Gh @('issue', 'create', '--title', $issueTitle, '--body-file', $issueBody) | Out-Null
    }
    Add-Summary "Stations left for a human: issue '$issueTitle'."
} elseif ($open) {
    Invoke-Gh @('issue', 'close', "$($open[0].number)", '--comment', "The refresh of $Date left nothing to fix.") | Out-Null
}

if ($UrlCount -eq 0 -and $LogoCount -eq 0 -and $StationCount -eq 0) {
    # A pull request an earlier run left open has nothing master still needs: the stations it fixed were fixed
    # since, or are failing again and in the issue.
    if ($state -eq 'OPEN') {
        Invoke-Gh @('pr', 'close', $Branch, '--delete-branch', '--comment', "The refresh of $Date found nothing to change: this pull request is no longer needed.") | Out-Null
        Add-Summary 'Closed the refresh pull request an earlier run left open.'
    }
    Add-Summary 'Nothing changed.'
    return
}

# 3: the pull request, on top of the newest base.
$title = "Refresh $UrlCount station url(s), $LogoCount logo(s), $StationCount station(s) retired, restored or rechecked ($Date)"
Invoke-Git @('config', 'user.name', 'github-actions[bot]') | Out-Null
Invoke-Git @('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com') | Out-Null
Invoke-Git @('switch', '-q', '-C', $Branch) | Out-Null
$changed = @('RadioStationsData.json', 'RetiredStations.json', 'RadioLogos', $note) | Where-Object { Test-Path (Join-Path $RepositoryPath $_) }
Invoke-Git (@('add') + $changed) | Out-Null
Invoke-Git @('commit', '-q', '-m', $title) | Out-Null
# master may have moved while the refresh ran: the commit is put on top of it, so the pull request does not conflict.
# A real conflict (someone changed the same station) leaves the commit where it was and the pull request says so.
Invoke-WithRetry -What 'git fetch' -BaseDelaySeconds $RetryDelaySeconds { Invoke-Git @('fetch', '-q', $Remote, $Base) } | Out-Null
& $Git -C $RepositoryPath rebase -q FETCH_HEAD 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $Git -C $RepositoryPath rebase --abort 2>$null | Out-Null
    Add-Summary "master changed the same lines since this run started: the pull request may need a rebase."
}
Invoke-WithRetry -What 'git push' -BaseDelaySeconds $RetryDelaySeconds { Invoke-Git @('push', '-q', '--force', $Remote, "HEAD:refs/heads/$Branch") } | Out-Null

# The pull request body is the same note, its logos read from this commit (a relative path does not render there;
# the commit stays reachable through the pull request after the branch is deleted).
$sha = "$(Invoke-Git @('rev-parse', 'HEAD'))".Trim()
$body = Join-Path $TempFolder 'refresh-body.md'
Write-Note $body "https://raw.githubusercontent.com/$Repository/$sha/RadioLogos/"
if ($state -eq 'OPEN') {
    Invoke-Gh @('pr', 'edit', $Branch, '--title', $title, '--body-file', $body) | Out-Null
    # An earlier run may have left auto-merge on: this run decides again, from its own change (CodeRabbit, #38).
    # gh fails when auto-merge was off, which is fine.
    & $Gh pr merge $Branch --disable-auto --repo $Repository 2>$null | Out-Null
} else {
    Invoke-Gh @('pr', 'create', '--base', $Base, '--head', $Branch, '--title', $title, '--body-file', $body) | Out-Null
}

if (-not $Merge) {
    Add-Summary 'Merge not requested: the pull request stays open.'
} elseif ($UrlCount -gt $MaxUrls -or $LogoCount -gt $MaxLogos) {
    $reason = "$UrlCount urls and $LogoCount logos changed, more than $MaxUrls urls or $MaxLogos logos: not merged automatically."
    Invoke-Gh @('pr', 'comment', $Branch, '--body', "$reason Check the urls from Romania and look at the logos before merging.") | Out-Null
    Add-Summary $reason
} elseif ($AutoMerge) {
    Invoke-Gh @('pr', 'merge', $Branch, '--auto', '--squash', '--delete-branch') | Out-Null
    Add-Summary 'Auto-merge is on: GitHub merges the pull request once the required checks (Lint, Tests) pass.'
} else {
    Invoke-Gh @('pr', 'merge', $Branch, '--squash', '--delete-branch') | Out-Null
    & $Gh api -X POST "repos/$Repository/pages/builds" --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Could not request a Pages build.'
        Add-Summary 'Could not request a Pages build: GitHub Pages rebuilds from the merge on its own, a few minutes later.'
    }
    Add-Summary 'Merged.'
}
