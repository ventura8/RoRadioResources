#Requires -Version 7.0
# A stand-in for the GitHub CLI in the end-to-end tests: Publish-Refresh.ps1 and Invoke-Refresh.ps1 run it as -Gh. It
# writes every call, one line each, to FAKE_GH_LOG and answers from the environment:
#
#   FAKE_GH_PR_STATE   what "gh pr view" prints (none: there is no pull request, exit 1)
#   FAKE_GH_ISSUES     what "gh issue list" prints (default: [])
#   FAKE_GH_CHECKS     what "gh pr checks" prints (default: [])
#   FAKE_GH_RUNS       what "gh run list" prints (default: [])
#   FAKE_GH_API_EXIT   the exit code of "gh api -X POST" (the Pages build; default: 0)
#   FAKE_GH_AUTH_EXIT  1: "gh api repos/..." (the token check) fails (default: it works)
#   FAKE_GH_BAD_TOKEN  a GH_TOKEN value the token check refuses (an expired REFRESH_TOKEN)
#   FAKE_GH_FAIL       a command ("pr merge") that always fails with exit 1
#   FAKE_GH_FLAKY      a command that fails once, then works (its first failure is noted in FAKE_GH_LOG.flaky)

Add-Content -Path $env:FAKE_GH_LOG -Value ($args -join ' ') -Encoding utf8
$command = "$($args[0]) $($args[1])"
if ($command -eq $env:FAKE_GH_FAIL) { exit 1 }
$flaky = "$env:FAKE_GH_LOG.flaky"
if ($command -eq $env:FAKE_GH_FLAKY -and -not (Test-Path $flaky)) {
    Set-Content -Path $flaky -Value $command
    exit 1
}
if ($command -eq 'pr view') {
    if (-not $env:FAKE_GH_PR_STATE) { exit 1 }
    $env:FAKE_GH_PR_STATE
}
if ($command -eq 'issue list') { @($env:FAKE_GH_ISSUES, '[]') | Where-Object { $_ } | Select-Object -First 1 }
if ($command -eq 'pr checks') { @($env:FAKE_GH_CHECKS, '[]') | Where-Object { $_ } | Select-Object -First 1 }
if ($command -eq 'run list') { @($env:FAKE_GH_RUNS, '[]') | Where-Object { $_ } | Select-Object -First 1 }
if ($command -eq 'api -X') { exit [int]$env:FAKE_GH_API_EXIT }
if ($args[0] -eq 'api') { exit [int]($env:FAKE_GH_AUTH_EXIT -eq '1' -or ($env:FAKE_GH_BAD_TOKEN -and $env:GH_TOKEN -eq $env:FAKE_GH_BAD_TOKEN)) }
exit 0
