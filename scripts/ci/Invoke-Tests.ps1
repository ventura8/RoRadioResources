#Requires -Version 7.0
<#
.SYNOPSIS
    Runs every test of this repository: the station list's integrity (tests/Catalogue.Tests.ps1), the scripts'
    helpers (tests/Helpers.Tests.ps1) and the logo checks (tests/test_normalize_logo.py).

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
} finally {
    Pop-Location
}

$failures = $pesterResult.FailedCount + $pesterResult.FailedBlocksCount + $pesterResult.FailedContainersCount
if ($failures -gt 0 -or $pythonFailed) {
    Write-Error "Tests failed: $failures Pester failure(s), Python tests $(if ($pythonFailed) { 'failed' } else { 'passed' })."
}
Write-Information "All tests passed ($($pesterResult.PassedCount) Pester, and the Python tests)." -InformationAction Continue
