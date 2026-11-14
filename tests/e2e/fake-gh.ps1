#Requires -Version 7.0
# A stand-in for the GitHub CLI in tests/Refresh.E2E.Tests.ps1: Publish-Refresh.ps1 runs it as -Gh. It writes every
# call, one line each, to FAKE_GH_LOG and answers from the environment:
#
#   FAKE_GH_PR_STATE  what "gh pr view" prints (none: there is no pull request, exit 1)
#   FAKE_GH_ISSUES    what "gh issue list" prints (default: [])
#   FAKE_GH_API_EXIT  the exit code of "gh api" (default: 0)
#   FAKE_GH_FAIL      a command ("pr merge") that fails with exit 1

Add-Content -Path $env:FAKE_GH_LOG -Value ($args -join ' ') -Encoding utf8
$command = "$($args[0]) $($args[1])"
if ($command -eq $env:FAKE_GH_FAIL) { exit 1 }
if ($command -eq 'pr view') {
    if (-not $env:FAKE_GH_PR_STATE) { exit 1 }
    $env:FAKE_GH_PR_STATE
}
if ($command -eq 'issue list') { @($env:FAKE_GH_ISSUES, '[]') | Where-Object { $_ } | Select-Object -First 1 }
if ($args[0] -eq 'api') { exit [int]$env:FAKE_GH_API_EXIT }
exit 0
