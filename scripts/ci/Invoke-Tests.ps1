#Requires -Version 7.0
<#
.SYNOPSIS
    Runs every test of this repository: the station list's integrity (tests/Catalogue.Tests.ps1), the scripts'
    helpers (tests/Helpers.Tests.ps1), the logo checks (tests/test_*.py) and the Cast receiver's script
    (tests/receiver.test.js, on Node's own test runner, no packages), and the receiver page itself in headless Chrome
    with Google's real Cast receiver framework (tests/receiver.browser.test.js: Chrome from CHROME_PATH or its usual
    install path, and network access to www.gstatic.com).

.DESCRIPTION
    The CI's test job, the weekly refresh (before it commits: pull requests opened by GitHub Actions do not start
    CI) and a local run all call this. It needs Pester 6.2.0 (Install-Module Pester -RequiredVersion 6.2.0
    -Scope CurrentUser -SkipPublisherCheck) and Python 3 with Pillow (scripts/ci/requirements.txt).

.PARAMETER Python
    The Python 3 command. Default: python on Windows, python3 elsewhere.

.PARAMETER ResultPath
    Where to write the Pester results (NUnit XML) for the CI summary. Default: none.
#>
[CmdletBinding()]
param(
    [string]$Python,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Python) { $Python = if ($IsWindows) { 'python' } else { 'python3' } }

$pester = Get-Module -ListAvailable Pester | Where-Object Version -eq '6.2.0' | Select-Object -First 1
if (-not $pester) { throw 'Pester 6.2.0 is needed: Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -SkipPublisherCheck' }
Import-Module $pester

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $root 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
if ($ResultPath) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $ResultPath
}
# The weekly refresh's code is measured, and every command of it must run under the tests (100%): the unit tests,
# tests/Probe.Tests.ps1 and the end-to-end run against the fake station server (tests/Refresh.E2E.Tests.ps1).
$updater = @(
    'scripts/Test-StationStreams.ps1', 'scripts/Update-StationUrls.ps1', 'scripts/Update-StationLogos.ps1',
    'scripts/New-RefreshNote.ps1', 'scripts/Publish-Refresh.ps1', 'scripts/lib/Net.ps1', 'scripts/lib/Names.ps1',
    'scripts/lib/Probe.ps1'
)
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = @($updater | ForEach-Object { Join-Path $root $_ })
$configuration.CodeCoverage.OutputPath = Join-Path ([IO.Path]::GetTempPath()) "roradio-coverage-$PID.xml"
$configuration.CodeCoverage.CoveragePercentTarget = 100
# The end-to-end tests run the fake server and draw their logos with this same Python (Greptile and CodeRabbit, #38).
$env:RORADIO_TEST_PYTHON = $Python
$pesterResult = Invoke-Pester -Configuration $configuration
$updaterCoverage = $pesterResult.CodeCoverage
$missed = @($updaterCoverage.CommandsMissed)
foreach ($command in $missed) { Write-Information "  not covered: $($command.File):$($command.Line) $($command.Command)" -InformationAction Continue }

Push-Location $root
try {
    # The Python tests, and the updater's Python (scripts/lib: the logo check) measured at 100%.
    & $Python -m pytest tests --cov=scripts/lib --cov-report=term-missing --cov-fail-under=100 -q
    $pythonFailed = $LASTEXITCODE -ne 0
    # The Cast receiver (receiver/*.js): unit tests and the real framework in Chrome. Below 100 % line, branch or
    # function coverage of its scripts, Node's runner fails the run.
    $coverage = @(
        '--experimental-test-coverage', '--test-coverage-include=receiver/*.js',
        '--test-coverage-lines=100', '--test-coverage-branches=100', '--test-coverage-functions=100'
    )
    & node --test @coverage (Get-ChildItem tests -Filter '*.test.js' | ForEach-Object FullName)
    $nodeFailed = $LASTEXITCODE -ne 0
} finally {
    Pop-Location
}

$failures = $pesterResult.FailedCount + $pesterResult.FailedBlocksCount + $pesterResult.FailedContainersCount
if ($failures -gt 0 -or $missed.Count -gt 0 -or $pythonFailed -or $nodeFailed) {
    $python = if ($pythonFailed) { 'failed (or below 100% coverage)' } else { 'passed' }
    $receiver = if ($nodeFailed) { 'failed' } else { 'passed' }
    Write-Error "Tests failed: $failures Pester failure(s), $($missed.Count) updater command(s) not covered, Python tests $python, receiver tests $receiver."
}
Write-Information "All tests passed ($($pesterResult.PassedCount) Pester, updater coverage $([Math]::Round($updaterCoverage.CoveragePercent, 2))% of $($updaterCoverage.CommandsAnalyzedCount) commands, the Python tests and the receiver tests)." -InformationAction Continue
