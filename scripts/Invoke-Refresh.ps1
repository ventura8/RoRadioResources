#Requires -Version 7.0
<#
.SYNOPSIS
    The weekly refresh, from start to end: what .github/workflows/refresh-stations.yml runs.

.DESCRIPTION
    Three parts (-Stage), so that the GitHub token is given only to the part that publishes: the search runs the
    station scripts against untrusted broadcaster servers and needs none.

      Due      whether this run has work: the weekly run always; the daily retry (-RetryOnly) only when no refresh
               succeeded in the last -RetryWithinDays days. Writes due=true|false to -OutputPath.
      Search   data       fetches the refresh-data branch (anonymously): since when each station fails, earlier metrics
               urls       Update-StationUrls.ps1, its strong sources ranked by their hit rate over the last runs
               lifecycle  Update-StationLifecycle.ps1: retires the stations gone for 30 days, rechecks, restores
               logos      Update-StationLogos.ps1, with -Logos
               tests      the repository's tests on the changed list (a pull request of GITHUB_TOKEN starts no CI)
      Publish  token      checks that the token can read the repository; an expired REFRESH_TOKEN falls back to the
                          workflow's own token (FALLBACK_TOKEN), and Sentry and the summary say so
               publish    Publish-Refresh.ps1: the note, the pull request, the issue, the trend
               save       appends this run's metrics and pushes the data back
      All      Search, then Publish.

    Each stage is timed for the metrics, and a failure is reported to Sentry with its stage before the run fails.
    A run is safe to repeat: the pull request's branch is pushed with --force and its pull request reused, the issue
    rewritten, every file written whole or not at all, the data pushed last.

.PARAMETER Stage
    Due, Search, Publish or All.

.PARAMETER DryRun
    Report only: the list, the retired stations and the data are left alone; nothing is committed or published.

.PARAMETER RetryOnly
    With -Stage Due: due only when no refresh succeeded in the last -RetryWithinDays days.

.PARAMETER OutputPath
    With -Stage Due: the step's GITHUB_OUTPUT.

.PARAMETER Logos
    Also look for missing logos (the repository variable REFRESH_LOGOS).

.PARAMETER Merge
    Merge the pull request (see Publish-Refresh.ps1).

.PARAMETER AutoMerge
    Merge through GitHub's auto-merge, once the required checks pass.

.PARAMETER ReplaceOnlyDead
    See Update-StationUrls.ps1. The weekly run passes it.

.PARAMETER RetireAfterDays
    See Update-StationLifecycle.ps1.

.PARAMETER RunId
    The workflow run's id: a tag on every Sentry event and a field of the metrics.

.PARAMETER RunUrl
    The workflow run, linked from the note and the issue.

.PARAMETER Repository
    owner/name. Default: GH_REPO.

.PARAMETER WorkFolder
    Where the reports and the data branch go; Search and Publish must share it. Default: RUNNER_TEMP, else the
    system's temp folder.

.PARAMETER Python
    Python 3 for the logos and the tests.

.PARAMETER TestScript
    The tests to run before publishing. Default: scripts/ci/Invoke-Tests.ps1.

.PARAMETER SearchArguments
    Passed to Update-StationUrls.ps1 (and to the rechecks): -Catalog, timeouts, the sources' addresses.

.PARAMETER LifecycleArguments
    Passed to Update-StationLifecycle.ps1: -Catalog, -RetiredPath, -Date.

.PARAMETER LogoArguments
    Passed to Update-StationLogos.ps1: -Catalog, -LogoFolder, the sources' addresses.

.PARAMETER PublishArguments
    Passed to Publish-Refresh.ps1 (and its -Gh, -Remote and -RetryDelaySeconds to the other stages): the tests give
    fakes here.

.PARAMETER RetryWithinDays
    See -RetryOnly.
#>
[CmdletBinding()]
param(
    [ValidateSet('Due', 'Search', 'Publish', 'All')] [string]$Stage = 'All',
    [switch]$DryRun,
    [switch]$RetryOnly,
    [string]$OutputPath,
    [switch]$Logos,
    [switch]$Merge,
    [switch]$AutoMerge,
    [switch]$ReplaceOnlyDead,
    [int]$RetireAfterDays = 30,
    [string]$RunId = $env:GITHUB_RUN_ID,
    [string]$RunUrl,
    [string]$Repository = $env:GH_REPO,
    [string]$WorkFolder,
    [string]$Python,
    [string]$TestScript,
    [hashtable]$SearchArguments = @{},
    [hashtable]$LifecycleArguments = @{},
    [hashtable]$LogoArguments = @{},
    [hashtable]$PublishArguments = @{},
    [int]$RetryWithinDays = 6
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Resilience.ps1')
. (Join-Path $PSScriptRoot 'lib/Telemetry.ps1')
$WorkFolder = @($WorkFolder, $env:RUNNER_TEMP, [IO.Path]::GetTempPath()) | Where-Object { $_ } | Select-Object -First 1
$Python = @($Python, ('python3', 'python')[[int][bool]$IsWindows]) | Where-Object { $_ } | Select-Object -First 1
$TestScript = @($TestScript, (Join-Path $PSScriptRoot 'ci/Invoke-Tests.ps1')) | Where-Object { $_ } | Select-Object -First 1
$gh = @($PublishArguments.Gh, 'gh') | Where-Object { $_ } | Select-Object -First 1
$delay = @($PublishArguments.RetryDelaySeconds, 5) | Where-Object { $null -ne $_ } | Select-Object -First 1
$script:SentryTags = @{ run_id = "$RunId"; dry_run = "$([bool]$DryRun)"; part = $Stage }
$dataPath = Join-Path $WorkFolder 'refresh-data'
$urlReport = Join-Path $WorkFolder 'urls.md'
$logoReport = Join-Path $WorkFolder 'logos.md'
$runFile = Join-Path $WorkFolder 'refresh-run.json'
# What the stage functions below read.
$options = @{
    Logos = [bool]$Logos; Merge = [bool]$Merge; AutoMerge = [bool]$AutoMerge; ReplaceOnlyDead = [bool]$ReplaceOnlyDead
    RetireAfterDays = $RetireAfterDays; RunUrl = $RunUrl; Search = $SearchArguments; Lifecycle = $LifecycleArguments; Logo = $LogoArguments
}
$metricsPath = Join-Path $dataPath 'metrics/runs.jsonl'
# The search reads the public data branch without a token; the publish part pushes it with one.
$syncArguments = @{ Path = $dataPath; Repository = $Repository; RetryDelaySeconds = $delay }
if ($PublishArguments.Remote) { $syncArguments.Remote = $PublishArguments.Remote }

# Runs gh (the fake one in the tests) and returns its output, or throws.
function Invoke-GhCommand([string[]]$Arguments) {
    $output = & $gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments[0..1] -join ' ') failed (exit $LASTEXITCODE)." }
    $output
}

function Invoke-SearchStage {
    $pull = $syncArguments.Clone()
    $pull.Remote = @("https://github.com/$Repository.git", $pull.Remote)[[int][bool]$pull.Remote]
    Measure-Stage 'data' { & (Join-Path $PSScriptRoot 'Sync-RefreshData.ps1') -Mode Pull @pull }
    $ranking = @(Get-SourceRanking $metricsPath)
    Add-Breadcrumb 'sources' "order: $($ranking -join ', ')"

    $urlMetrics = Join-Path $WorkFolder 'url-metrics.json'
    $urlResults = Join-Path $WorkFolder 'url-results.json'
    $search = $options.Search
    $lifecycleArguments = $options.Lifecycle
    $logoArguments = $options.Logo
    Measure-Stage 'urls' {
        $null = & (Join-Path $PSScriptRoot 'Update-StationUrls.ps1') -ReplaceOnlyDead:$options.ReplaceOnlyDead -SourceOrder $ranking -ReportPath $urlReport `
            -ResultsPath $urlResults -MetricsPath $urlMetrics -WhatIf:$DryRun @search 6>$null
    }
    $found = Get-Content $urlMetrics -Raw -Encoding utf8 | ConvertFrom-Json

    $lifecycleReport = Join-Path $WorkFolder 'lifecycle.md'
    Measure-Stage 'lifecycle' {
        $script:lifecycle = & (Join-Path $PSScriptRoot 'Update-StationLifecycle.ps1') -StatePath (Join-Path $dataPath 'state/failing.json') `
            -ResultsPath $urlResults -Probed $found.Probed -RetireAfterDays $options.RetireAfterDays -SearchArguments $search `
            -ReportPath $lifecycleReport -WhatIf:$DryRun @lifecycleArguments 6>$null
    }
    Add-Content -Path $urlReport -Value ("`n" + (Get-Content $lifecycleReport -Raw -Encoding utf8)) -Encoding utf8

    $script:logoResults = @()
    if ($options.Logos) {
        Measure-Stage 'logos' {
            $script:logoResults = & (Join-Path $PSScriptRoot 'Update-StationLogos.ps1') -Python $Python -ReportPath $logoReport -WhatIf:$DryRun @logoArguments 6>$null
        }
    }

    $metrics = $script:RunMetrics
    $metrics.Date = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $metrics.RunId = $RunId
    foreach ($name in 'Probed', 'Failing', 'Dead', 'Fixed', 'Suggested', 'Unresolved', 'Blocked', 'Sources') { $metrics[$name] = $found.$name }
    $metrics.Logos = @($script:logoResults | Where-Object File).Count
    $metrics.Retired = $script:lifecycle.Retired.Count
    $metrics.Restored = $script:lifecycle.Restored.Count
    $metrics.MassFailure = $script:lifecycle.MassFailure
    $metrics.FailingDays = [ordered]@{}
    foreach ($item in $script:lifecycle.Failing) { $metrics.FailingDays[$item.Title] = $item.Days }

    if ($DryRun) {
        Write-Information (Get-Content $urlReport -Raw -Encoding utf8) -InformationAction Continue
        return
    }
    Measure-Stage 'tests' { & $TestScript -Python $Python }
    $metrics.Retries = $found.Retries + $script:RetryCount
    Set-Content -Path $runFile -Value ($metrics | ConvertTo-Json -Depth 6) -Encoding utf8
}

function Invoke-PublishStage {
    Measure-Stage 'token' {
        try {
            $null = Invoke-WithRetry -What 'gh api' -BaseDelaySeconds $delay { Invoke-GhCommand @('api', "repos/$Repository", '--jq', '.full_name') }
        } catch {
            if (-not $env:FALLBACK_TOKEN -or $env:FALLBACK_TOKEN -eq $env:GH_TOKEN) {
                throw "The GitHub token cannot read $Repository (missing, expired or without access). Set the REFRESH_TOKEN secret again."
            }
            # REFRESH_TOKEN expired: the workflow's own token still publishes, but its pull request starts no CI, so
            # an auto-merge waits for a human. Sentry and the warning say so.
            $env:GH_TOKEN = $env:FALLBACK_TOKEN
            $null = Send-SentryEvent -Level 'warning' -Message 'REFRESH_TOKEN cannot read the repository (expired?): the refresh fell back to GITHUB_TOKEN, and its pull request starts no CI.' -Tags @{ stage = 'token' }
            Write-Warning 'REFRESH_TOKEN cannot read the repository: using the workflow token; set REFRESH_TOKEN again.'
        }
    }
    $saved = Get-Content $runFile -Raw -Encoding utf8 | ConvertFrom-Json
    # The search's numbers; its stage times join this part's own (Stages stays a table the stages add to).
    foreach ($property in $saved.PSObject.Properties | Where-Object Name -ne 'Stages') { $script:RunMetrics[$property.Name] = $property.Value }
    foreach ($property in $saved.Stages.PSObject.Properties) { $script:RunMetrics.Stages[$property.Name] = $property.Value }
    Write-RunMetric $metricsPath
    Measure-Stage 'publish' {
        $publish = @{
            UrlReport = $urlReport; UrlCount = $saved.Fixed; LogoCount = $saved.Logos; StationCount = $saved.Retired + $saved.Restored
            Merge = $options.Merge; AutoMerge = $options.AutoMerge; MetricsPath = $metricsPath; Repository = $Repository; RunUrl = $options.RunUrl
        }
        if (Test-Path $logoReport) { $publish.LogoReport = $logoReport }
        foreach ($name in $PublishArguments.Keys) { $publish[$name] = $PublishArguments[$name] }
        & (Join-Path $PSScriptRoot 'Publish-Refresh.ps1') @publish
    }
    Measure-Stage 'save' { & (Join-Path $PSScriptRoot 'Sync-RefreshData.ps1') -Mode Push @syncArguments }
}

# Due: whether this run has work.
if ($Stage -eq 'Due') {
    $due = $true
    if ($RetryOnly) {
        $since = [DateTime]::UtcNow.AddDays(-$RetryWithinDays).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $runs = @(Invoke-WithRetry -What 'gh run list' -BaseDelaySeconds $delay {
            Invoke-GhCommand @('run', 'list', '--workflow', 'refresh-stations.yml', '--status', 'success', '--created', ">=$since", '--json', 'databaseId', '--repo', $Repository)
        } | ConvertFrom-Json)
        $due = -not $runs
        Write-Information (@("A refresh succeeded since $since; the retry has nothing to do.", "No refresh succeeded since ${since}: running it again.")[[int]$due]) -InformationAction Continue
    }
    if ($OutputPath) { Add-Content -Path $OutputPath -Value "due=$($due.ToString().ToLowerInvariant())" -Encoding utf8 }
    return $due
}

try {
    if ($Stage -ne 'Publish') { Invoke-SearchStage }
    if ($Stage -ne 'Search' -and -not $DryRun) { Invoke-PublishStage }
} catch {
    # Measure-Stage reported the stage that failed; this covers what failed between stages.
    if (-not ($script:Breadcrumbs | Where-Object { $_.message -like 'failed *' })) {
        $null = Send-SentryEvent -Message "The refresh failed: $($_.Exception.Message)" -ErrorRecord $_
    }
    throw
}
