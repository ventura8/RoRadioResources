#Requires -Version 7.0
<#
.SYNOPSIS
    Runs every linter of this repository, each at its strictest setting, and fails when any of them finds
    anything. Inline suppressions are not allowed: a finding is fixed in the file.

.DESCRIPTION
    The CI's lint job and a local run call this. Every check runs even when an earlier one fails; the summary
    lists the failures. The tools and their pinned versions:

      PowerShell    PSScriptAnalyzer 1.25.0, every rule at every severity (PSScriptAnalyzerSettings.psd1)
      Python        ruff (every rule, ruff.toml; lint and format), from scripts/ci/requirements.txt
      YAML          yamllint (strict, .yamllint), from scripts/ci/requirements.txt
      Workflows     actionlint, and zizmor (workflow security) from scripts/ci/requirements.txt
      Markdown      markdownlint-cli2 (.markdownlint-cli2.jsonc), from scripts/ci/package.json
      Spelling      cspell (cspell.json, scripts/ci/words.txt), from scripts/ci/package.json
      Whitespace    editorconfig-checker (.editorconfig), from scripts/ci/package.json
      Secrets       gitleaks, the working tree and the whole history
      Suppressions  this script: no inline suppression comment or attribute of any of the tools above

    Install once: `python -m pip install -r scripts/ci/requirements.txt`, `npm ci --prefix scripts/ci`,
    `Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser`, and actionlint and gitleaks
    (winget install rhysd.actionlint Gitleaks.Gitleaks; the CI downloads its pinned releases).

.PARAMETER Python
    The Python 3 command. Default: python on Windows, python3 elsewhere.
#>
[CmdletBinding()]
param(
    [string]$Python
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Python) { $Python = if ($IsWindows) { 'python' } else { 'python3' } }
$nodeBin = Join-Path (Join-Path (Join-Path $PSScriptRoot 'node_modules') '.bin') ''
$summary = [Collections.Generic.List[string]]::new()
$failed = 0

function Invoke-Check([string]$Name, [scriptblock]$Check) {
    Write-Information "`n==> lint: $Name" -InformationAction Continue
    $ok = $false
    try {
        $global:LASTEXITCODE = 0
        $output = & $Check
        $ok = $LASTEXITCODE -eq 0 -and $output -ne $false
    } catch {
        Write-Information "  $($_.Exception.Message)" -InformationAction Continue
    }
    $script:summary.Add("  ${Name}: $(if ($ok) { 'ok' } else { 'FAILED' })")
    if (-not $ok) { $script:failed++ }
}

function Get-NodeTool([string]$Name) {
    $candidates = @("$nodeBin$Name.cmd", "$nodeBin$Name") | Where-Object { Test-Path $_ }
    if (-not $candidates) { throw "$Name is not installed: npm ci --prefix scripts/ci" }
    $candidates | Select-Object -First 1
}

# A tool on PATH (the CI installs pinned release binaries there), else its npm wrapper from scripts/ci.
function Get-Tool([string]$Name) {
    $installed = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($installed) { $installed.Source } else { Get-NodeTool $Name }
}

Push-Location $root
try {
    Invoke-Check 'PSScriptAnalyzer' {
        Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
        $findings = @(Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1)
        $findings | ForEach-Object { Write-Information "  $($_.ScriptName):$($_.Line) $($_.RuleName): $($_.Message)" -InformationAction Continue }
        $findings.Count -eq 0
    }
    Invoke-Check 'ruff (lint)' { & $Python -m ruff check . | Out-Host }
    Invoke-Check 'ruff (format)' { & $Python -m ruff format --check . | Out-Host }
    Invoke-Check 'yamllint' { & $Python -m yamllint --strict . | Out-Host }
    Invoke-Check 'actionlint' { & actionlint | Out-Host }
    # --min-severity low leaves out only zizmor's informational notes.
    Invoke-Check 'zizmor (workflow security)' { & zizmor --persona regular --min-severity low .github/workflows | Out-Host }
    Invoke-Check 'markdownlint' { & (Get-NodeTool 'markdownlint-cli2') | Out-Host }
    Invoke-Check 'cspell' { & (Get-NodeTool 'cspell') --no-progress --config cspell.json '**' | Out-Host }
    Invoke-Check 'editorconfig-checker' { & (Get-Tool 'editorconfig-checker') | Out-Host }
    Invoke-Check 'gitleaks (working tree)' { & gitleaks dir --redact --no-banner . | Out-Host }
    Invoke-Check 'gitleaks (history)' { & gitleaks git --redact --no-banner . | Out-Host }
    Invoke-Check 'inline suppression ban' {
        # A suppression hides a finding instead of fixing it. The patterns are built from parts so that this file
        # does not match itself.
        $markers = @(
            ('no' + 'qa'), ('type: ' + 'ignore'), ('Suppress' + 'Message'), ('markdownlint-' + 'disable'),
            ('cspell:' + 'disable'), ('cspell:' + 'ignore'), ('yamllint ' + 'disable'), ('zizmor: ' + 'ignore'),
            ('gitleaks:' + 'allow'), ('editorconfig-checker-' + 'disable'), ('pylint: ' + 'disable')
        )
        $pattern = ($markers | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $files = @(git ls-files --cached --others --exclude-standard | Where-Object { $_ -notmatch '^(RadioLogos/|.*package-lock\.json$)' })
        $hits = @(foreach ($file in $files) {
            if (-not (Test-Path $file -PathType Leaf)) { continue }
            Select-String -Path $file -Pattern $pattern -CaseSensitive | ForEach-Object { "  $($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
        })
        $hits | ForEach-Object { Write-Information $_ -InformationAction Continue }
        $hits.Count -eq 0
    }
} finally {
    Pop-Location
}

Write-Information "`n==> lint summary`n$($summary -join "`n")" -InformationAction Continue
if ($failed -gt 0) { Write-Error "$failed lint check(s) failed." }
