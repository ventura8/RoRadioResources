# PSScriptAnalyzer settings for scripts/ and tests/: every default rule at every severity (Information included:
# several rules that matter for these scripts report at that level). No exemptions; inline suppressions are banned
# (scripts/ci/Invoke-Lint.ps1).
@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning', 'Information')
}
