#Requires -Version 7.0
<#
.SYNOPSIS
    Fetches or saves the weekly refresh's own data: the branch refresh-data, with state/failing.json (since when each
    station has failed) and metrics/runs.jsonl (one line per run).

.DESCRIPTION
    The data changes every run, also when the station list does not, so it lives on its own branch, outside master
    and its branch protection, and never in a pull request.

      -Mode Pull  clones the branch into -Path; when it does not exist yet, -Path becomes an empty repository whose
                  first push creates it.
      -Mode Push  commits what changed in -Path and pushes it. A push that loses a race (another run pushed first) is
                  rebased onto that run's data and tried again, three times with a growing pause.

.PARAMETER Mode
    Pull or Push.

.PARAMETER Path
    The data's working folder.

.PARAMETER Remote
    The repository. Default: github.com with GH_TOKEN.

.PARAMETER Repository
    owner/name, for the default remote. Default: GH_REPO.

.PARAMETER Branch
    The data branch.

.PARAMETER RetryDelaySeconds
    The first pause before a push is tried again.

.PARAMETER Git
    git.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Pull', 'Push')] [string]$Mode,
    [Parameter(Mandatory)] [string]$Path,
    [string]$Remote,
    [string]$Repository = $env:GH_REPO,
    [string]$Branch = 'refresh-data',
    [double]$RetryDelaySeconds = 5,
    [string]$Git = 'git'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Resilience.ps1')
if (-not $Remote) { $Remote = "https://x-access-token:$($env:GH_TOKEN)@github.com/$Repository.git" }

function Invoke-Git([string[]]$Arguments) {
    $output = & $Git -C $Path @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments[0]) failed (exit $LASTEXITCODE)." }
    $output
}

if ($Mode -eq 'Pull') {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-Git @('init', '-q') | Out-Null
    Invoke-Git @('config', 'user.name', 'github-actions[bot]') | Out-Null
    Invoke-Git @('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com') | Out-Null
    Invoke-Git @('checkout', '-q', '-B', $Branch) | Out-Null
    # "Couldn't find remote ref" is the first run: the branch is made by the first push.
    $exists = Invoke-WithRetry -What 'git ls-remote' -BaseDelaySeconds $RetryDelaySeconds { @(Invoke-Git @('ls-remote', '--heads', $Remote, $Branch)) }
    if ($exists) {
        Invoke-WithRetry -What 'git fetch' -BaseDelaySeconds $RetryDelaySeconds { Invoke-Git @('fetch', '-q', $Remote, $Branch) } | Out-Null
        Invoke-Git @('reset', '-q', '--hard', 'FETCH_HEAD') | Out-Null
    }
    return
}

Invoke-Git @('add', '-A') | Out-Null
& $Git -C $Path diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Information 'The refresh data did not change.' -InformationAction Continue
    return
}
$message = "Refresh data $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) UTC"
Invoke-Git @('commit', '-q', '-m', $message) | Out-Null

# Another run pushed first: this run's files are put on top of its data by hand, not by a rebase that picks one side
# of a conflict (which dropped the other run's metrics line; Greptile, #44). A .jsonl file keeps every line of both, the
# other run's first; any other file (the state) is this run's, the newer one.
function Merge-RemoteData {
    $mine = @{}
    foreach ($file in Get-ChildItem -Path $Path -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
        $mine[[IO.Path]::GetRelativePath($Path, $file.FullName)] = [IO.File]::ReadAllText($file.FullName)
    }
    Invoke-Git @('fetch', '-q', $Remote, $Branch) | Out-Null
    Invoke-Git @('reset', '-q', '--hard', 'FETCH_HEAD') | Out-Null
    foreach ($name in $mine.Keys) {
        $target = Join-Path $Path $name
        $text = $mine[$name]
        if ($name -like '*.jsonl' -and (Test-Path $target)) {
            $theirs = @([IO.File]::ReadAllLines($target))
            $added = @($text -split "\r?\n" | Where-Object { $_ -and $theirs -notcontains $_ })
            $text = ((@($theirs) + $added) -join "`n") + "`n"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        [IO.File]::WriteAllText($target, $text, [Text.UTF8Encoding]::new($false))
    }
    Invoke-Git @('add', '-A') | Out-Null
    Invoke-Git @('commit', '-q', '--allow-empty', '-m', $message) | Out-Null
}

Invoke-WithRetry -What 'git push of the refresh data' -BaseDelaySeconds $RetryDelaySeconds {
    & $Git -C $Path push -q $Remote "HEAD:refs/heads/$Branch" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Merge-RemoteData
        throw "The push of $Branch was refused: merged with the newer data, trying again."
    }
}
