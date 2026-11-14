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
$pesterResult = Invoke-Pester -Configuration $configuration

Push-Location $root
try {
    & $Python -m unittest discover --start-directory tests --verbose
    $pythonFailed = $LASTEXITCODE -ne 0
    # The Cast receiver (receiver/receiver.js): unit tests and the real framework in Chrome. Below 100 % line, branch
    # or function coverage of the script, Node's runner fails the run.
    $coverage = @(
        '--experimental-test-coverage', '--test-coverage-include=receiver/receiver.js',
        '--test-coverage-lines=100', '--test-coverage-branches=100', '--test-coverage-functions=100'
    )
    & node --test @coverage (Get-ChildItem tests -Filter '*.test.js' | ForEach-Object FullName)
    $nodeFailed = $LASTEXITCODE -ne 0
} finally {
    Pop-Location
}

$failures = $pesterResult.FailedCount + $pesterResult.FailedBlocksCount + $pesterResult.FailedContainersCount
if ($failures -gt 0 -or $pythonFailed -or $nodeFailed) {
    $python = if ($pythonFailed) { 'failed' } else { 'passed' }
    $receiver = if ($nodeFailed) { 'failed' } else { 'passed' }
    Write-Error "Tests failed: $failures Pester failure(s), Python tests $python, receiver tests $receiver."
}
Write-Information "All tests passed ($($pesterResult.PassedCount) Pester, the Python tests and the receiver tests)." -InformationAction Continue
