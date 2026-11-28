#Requires -Version 7.0
# The refresh's own life, end to end: stations retired after 30 days of failing, rechecked on a growing schedule and
# restored when they play again (Update-StationLifecycle.ps1); the whole run with its data branch, Sentry, metrics,
# the daily retry and every failure it must handle by itself (Invoke-Refresh.ps1, Sync-RefreshData.ps1); and the
# libraries under them. Against the fake station server and the fake GitHub CLI of tests/e2e, with real git remotes.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:scripts = Join-Path $root 'scripts'
    . (Join-Path $PSScriptRoot 'e2e/FakeServer.ps1')
    . (Join-Path $scripts 'lib/Catalog.ps1')
    . (Join-Path $scripts 'lib/Resilience.ps1')
    . (Join-Path $scripts 'lib/Telemetry.ps1')
    $script:fakeGh = Join-Path $PSScriptRoot 'e2e/fake-gh.ps1'
    $script:work = Join-Path ([IO.Path]::GetTempPath()) "roradio-life-$([Guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    $script:sentryLog = Join-Path $work 'sentry.log'
    $script:server = Open-FakeStationServer @(
        @{ path = '/stream/alive'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/back'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/hand'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/elsewhere'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/moved-new'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/flaky-source'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/once'; type = 'audio/mpeg'; audio = 8192; times = 1 }
        @{ path = '/sitemap.xml'; type = 'application/xml'; body = '<url><loc>{base}/radio-moved</loc></url><url><loc>{base}/radio-gamma</loc></url>' }
        @{ path = '/radio-moved'; body = '<audio src="{base}/stream/moved-new"></audio>' }
        @{ path = '/radio-gamma'; status = 503; body = 'busy'; times = 1 }
        @{ path = '/radio-gamma'; body = '<audio src="{base}/stream/flaky-source"></audio>' }
        @{ path = '/json/stations/search'; type = 'application/json'; body = '[]' }
        @{ path = '/stations/search'; type = 'application/json'; body = '{"playables": []}' }
        @{ path = '/Search/UpdateSearch'; method = 'POST'; type = 'application/json'; body = '[]' }
        @{ path = '/api/1/envelope/'; method = 'POST'; type = 'application/json'; body = '{"id": "1"}'; record = $sentryLog }
    )
    $script:base = $server.Base
    $script:dead = 'http://127.0.0.1:1'
    $script:search = @{
        MyRadioOnlineUrl = $base; RadioBrowserUrl = $base; ShoutcastDirectoryUrl = $base; ShoutcastPlaylistUrl = $base; RadioNetUrl = $base
        TimeoutSeconds = 5; RetryDelaySeconds = 0; ThrottleLimit = 8; MaxFailureRatio = 1
    }
    $script:dsn = "http://publickey@127.0.0.1:$(([Uri]$base).Port)/1"

    # A list of named categories: @{ Category = @( @{ Title; Url }, ... ) }, written like the real one.
    function Write-CategoryList([string]$Path, [System.Collections.Specialized.OrderedDictionary]$Categories) {
        $all = @(foreach ($name in $Categories.Keys) {
            [ordered]@{ Name = $name; List = @($Categories[$name] | ForEach-Object { [ordered]@{ GUID = [Guid]::NewGuid().ToString(); Title = $_.Title; Url = $_.Url } }) }
        })
        [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $all -Depth 5), [Text.UTF8Encoding]::new($true))
        $byTitle = @{}
        foreach ($category in $all) { foreach ($station in $category.List) { $byTitle[$station.Title] = $station.GUID } }
        $byTitle
    }

    function Invoke-Lifecycle([hashtable]$Arguments) {
        & (Join-Path $scripts 'Update-StationLifecycle.ps1') @Arguments 6>$null 3>$null
    }
}

AfterAll {
    Close-FakeStationServer $server
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Describe 'Retiring stations that are gone (Update-StationLifecycle.ps1)' {
    BeforeAll {
        $script:catalog = Join-Path $work 'life.json'
        $script:retiredPath = Join-Path $work 'RetiredStations.json'
        $script:statePath = Join-Path $work 'state/failing.json'
        $script:resultsPath = Join-Path $work 'results.json'
        $script:stationIds = Write-CategoryList $catalog ([ordered]@{
            Test = @(@{ Title = 'Radio Alive'; Url = "$base/stream/alive" }, @{ Title = 'Radio Gone'; Url = "$dead/gone" }, @{ Title = 'Radio Young'; Url = "$dead/young" }, @{ Title = 'Radio Last'; Url = "$dead/last" })
            Solo = @(@{ Title = 'Radio Solo'; Url = "$dead/solo" })
        })
        $results = @(
            @{ Guid = $stationIds['Radio Gone']; Title = 'Radio Gone'; OldUrl = "$dead/gone"; OldVerdict = 'dead'; Tried = 2 }
            @{ Guid = $stationIds['Radio Young']; Title = 'Radio Young'; OldUrl = "$dead/young"; OldVerdict = 'dead'; Tried = 0 }
            @{ Guid = $stationIds['Radio Last']; Title = 'Radio Last'; OldUrl = "$dead/last"; OldVerdict = 'dead'; Tried = 0 }
            @{ Guid = $stationIds['Radio Solo']; Title = 'Radio Solo'; OldUrl = "$dead/solo"; OldVerdict = 'dead'; Tried = 0 }
            @{ Guid = 'not-in-the-list'; Title = 'Radio Ghost'; OldUrl = "$dead/ghost"; OldVerdict = 'dead'; Tried = 0 }
            @{ Guid = 'x'; Title = 'Radio Suggested'; OldUrl = "$dead/s"; OldVerdict = 'dead'; Suggested = "$base/stream/alive" }
        )
        Set-Content -Path $resultsPath -Value (ConvertTo-Json -InputObject $results)
        New-Item -ItemType Directory -Force -Path (Split-Path $statePath) | Out-Null
        Set-Content -Path $statePath -Value (@{
            $stationIds['Radio Gone'] = @{ Title = 'Radio Gone'; FirstFailed = '2026-11-16' }
            $stationIds['Radio Last'] = @{ Title = 'Radio Last'; FirstFailed = '2026-11-01' }
            $stationIds['Radio Solo'] = @{ Title = 'Radio Solo'; FirstFailed = '2026-11-01' }
            'not-in-the-list'    = @{ Title = 'Radio Ghost'; FirstFailed = '2026-11-01' }
            'fixed-since'        = @{ Title = 'Radio Fixed'; FirstFailed = '2026-11-01' }
        } | ConvertTo-Json)
        $script:before = [IO.File]::ReadAllText($catalog)
        $script:outcome = Invoke-Lifecycle @{ Catalog = $catalog; RetiredPath = $retiredPath; StatePath = $statePath; ResultsPath = $resultsPath; Probed = 100; Date = '2026-12-16'; ReportPath = (Join-Path $work 'life.md') }
        $script:after = Read-TestCatalog $catalog
        $script:retired = @(Get-Content $retiredPath -Raw | ConvertFrom-Json)
        $script:state = Get-Content $statePath -Raw | ConvertFrom-Json
    }

    It 'retires a station that failed every check for 30 days: out of the list, into RetiredStations.json with its evidence' {
        @($outcome.Retired.Title) | Should -Be @('Radio Gone', 'Radio Last')
        $after.Keys | Should -Not -Contain 'Radio Gone'
        $gone = $retired | Where-Object Title -eq 'Radio Gone'
        $gone.Url | Should -Be "$dead/gone"
        $gone.Category | Should -Be 'Test'
        $gone.After | Should -Be $stationIds['Radio Alive']
        $gone.Block | Should -Match ([regex]::Escape($stationIds['Radio Gone']))
        $gone.FirstFailed | Should -Be '2026-11-16'
        $gone.Retired | Should -Be '2026-12-16'
        $gone.NextCheck | Should -Be '2027-01-15' -Because 'the first recheck is 30 days after retirement'
        $gone.Evidence | Should -Match 'for 30 counted days since 2026-11-16.*2 candidate'
        $state.($stationIds['Radio Gone']).Days | Should -Be 30 -Because 'the count stays until the retirement reaches master'
    }

    It 'keeps a station failing for less than 30 days, the last of its category, and one not in the list, and remembers since when' {
        $after.Keys | Should -Contain 'Radio Young'
        $after.Keys | Should -Contain 'Radio Solo'
        $state.($stationIds['Radio Young']).FirstFailed | Should -Be '2026-12-16'
        $state.($stationIds['Radio Solo']).FirstFailed | Should -Be '2026-11-01'
        $state.PSObject.Properties.Name | Should -Not -Contain 'fixed-since' -Because 'a station that no longer fails starts over'
        $state.PSObject.Properties.Name | Should -Not -Contain 'x' -Because 'a suggestion is not "nothing found"'
        $report = Get-Content (Join-Path $work 'life.md') -Raw
        $report | Should -Match '\| Radio Solo: the only station left in its category \|'
        $report | Should -Match '\| Radio Ghost: not found in the list \|'
        $report | Should -Match '\| Radio Young \| 2026-12-16 \| 0 \|'
    }

    It 'changes only the retired blocks, keeping the file''s format' {
        $text = [IO.File]::ReadAllText($catalog)
        $expected = Get-ListWithoutStation (Get-ListWithoutStation $before $stationIds['Radio Gone']) $stationIds['Radio Last']
        $text | Should -BeExactly $expected
        [IO.File]::ReadAllBytes($catalog)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'retires nothing and counts no day when too many stations fail at once' {
        $massState = Join-Path $work 'mass/failing.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $massState) | Out-Null
        Copy-Item $statePath $massState
        $stateBefore = Get-Content $massState -Raw
        $copy = Join-Path $work 'mass.json'
        Copy-Item $catalog $copy
        $listBefore = Get-Content $copy -Raw
        $outcome = Invoke-Lifecycle @{ Catalog = $copy; RetiredPath = (Join-Path $work 'mass-retired.json'); StatePath = $massState; ResultsPath = $resultsPath; Probed = 20; Date = '2027-03-01'; ReportPath = (Join-Path $work 'mass.md') }
        $outcome.MassFailure | Should -BeTrue
        $outcome.Retired | Should -BeNullOrEmpty
        Get-Content $copy -Raw | Should -Be $listBefore
        $paused = Get-Content $massState -Raw | ConvertFrom-Json
        $paused.PSObject.Properties.Name | Should -Be ((($stateBefore | ConvertFrom-Json).PSObject.Properties.Name))
        $paused.($stationIds['Radio Young']).LastCounted | Should -Be '2027-03-01' -Because 'the count is paused: the days of the outage are skipped'
        $paused.($stationIds['Radio Young']).Days | Should -Be 0
        Get-Content (Join-Path $work 'mass.md') -Raw | Should -Match 'too many failed at once'
    }

    It 'never counts or retires a station whose sources could not all be read, and skips the days of an outage' {
        $outageState = Join-Path $work 'outage/failing.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $outageState) | Out-Null
        $guid = $stationIds['Radio Young']
        Set-Content -Path $outageState -Value "{`"$guid`": {`"Title`": `"Radio Young`", `"FirstFailed`": `"2026-11-01`", `"LastCounted`": `"2026-11-25`", `"Days`": 25}}"
        $outageResults = Join-Path $work 'outage-results.json'
        Set-Content -Path $outageResults -Value "[{`"Guid`": `"$guid`", `"Title`": `"Radio Young`", `"OldUrl`": `"$dead/young`", `"OldVerdict`": `"dead`", `"Tried`": 0, `"Complete`": false}]"
        $copy = Join-Path $work 'outage.json'
        Copy-Item $catalog $copy
        $common = @{ Catalog = $copy; RetiredPath = (Join-Path $work 'outage-retired.json'); StatePath = $outageState; Probed = 100 }
        $outcome = Invoke-Lifecycle ($common + @{ ResultsPath = $outageResults; Date = '2026-12-20' })
        $outcome.Retired | Should -BeNullOrEmpty -Because 'a source was down: no evidence'
        $kept = Get-Content $outageState -Raw | ConvertFrom-Json
        $kept.$guid.Days | Should -Be 25 -Because 'the outage days are not counted'
        $kept.$guid.LastCounted | Should -Be '2026-12-20'
        Set-Content -Path $outageResults -Value "[{`"Guid`": `"$guid`", `"Title`": `"Radio Young`", `"OldUrl`": `"$dead/young`", `"OldVerdict`": `"dead`", `"Tried`": 0, `"Complete`": true}]"
        $outcome = Invoke-Lifecycle ($common + @{ ResultsPath = $outageResults; Date = '2026-12-23' })
        $outcome.Retired | Should -BeNullOrEmpty -Because '25 + 3 counted days is not 30'
        (Get-Content $outageState -Raw | ConvertFrom-Json).$guid.Days | Should -Be 28
    }

    It 'refuses a list with a GUID twice before doing anything' {
        $twice = Join-Path $work 'twice-life.json'
        $guid = [Guid]::NewGuid().ToString()
        $json = "[{`"Name`": `"Test`", `"List`": [{`"GUID`": `"$guid`", `"Title`": `"A`", `"Url`": `"$dead/a`"}, {`"GUID`": `"$guid`", `"Title`": `"B`", `"Url`": `"$dead/b`"}]}]"
        [IO.File]::WriteAllText($twice, $json)
        { Invoke-Lifecycle @{ Catalog = $twice; RetiredPath = (Join-Path $work 'twice-retired.json'); StatePath = (Join-Path $work 'twice/failing.json'); ResultsPath = $resultsPath; Probed = 100 } } | Should -Throw '*twice*'
        Get-Content $twice -Raw | Should -Be $json
    }

    It 'writes nothing when the result would not be the expected list (a retired block with another GUID)' {
        $odd = Join-Path $work 'odd-life.json'
        Write-CategoryList $odd ([ordered]@{ Test = @(@{ Title = 'Radio Alive'; Url = "$base/stream/alive" }) }) | Out-Null
        $before = Get-Content $odd -Raw
        $oddRetired = Join-Path $work 'odd-retired.json'
        $wrongBlock = "{`n        `"GUID`": `"not-the-entry`",`n        `"Title`": `"Radio Odd`",`n        `"Url`": `"$base/stream/hand`"`n      }"
        Set-Content -Path $oddRetired -Value (ConvertTo-Json -InputObject @([ordered]@{ GUID = 'odd-guid'; Title = 'Radio Odd'; Url = "$base/stream/hand"; Category = 'Test'; Block = $wrongBlock; NextCheck = '2026-12-01' }))
        $empty = Join-Path $work 'odd-results.json'
        Set-Content -Path $empty -Value '[]'
        { Invoke-Lifecycle @{ Catalog = $odd; RetiredPath = $oddRetired; StatePath = (Join-Path $work 'odd/failing.json'); ResultsPath = $empty; Probed = 100; Date = '2026-12-16'; SearchArguments = $search } } | Should -Throw '*nothing was written*'
        Get-Content $odd -Raw | Should -Be $before
    }
}

Describe 'Rechecking and restoring retired stations' {
    BeforeAll {
        $script:catalog = Join-Path $work 'recheck.json'
        $script:stationIds = Write-CategoryList $catalog ([ordered]@{
            Test  = @(@{ Title = 'Radio Alive'; Url = "$base/stream/alive" }, @{ Title = 'Radio Other'; Url = "$base/stream/elsewhere" })
            Moved = @(@{ Title = 'Radio Away'; Url = "$base/stream/away" })
        })
        $block = "{`n        `"GUID`": `"back-guid`",`n        `"Title`": `"Radio Back`",`n        `"Url`": `"$base/stream/back`",`n        `"ImageUrl`": `"back.png`"`n      }"
        $retired = @(
            [ordered]@{ GUID = 'back-guid'; Title = 'Radio Back'; Url = "$base/stream/back"; Category = 'Test'; After = $stationIds['Radio Alive']; Block = $block; Retired = '2026-11-01'; Checks = 0; NextCheck = '2026-12-01' }
            [ordered]@{ GUID = 'hand-guid'; Title = 'Radio Hand'; Url = "$base/stream/hand"; Category = 'Test'; NextCheck = '2026-12-01' }
            [ordered]@{ GUID = 'moved-guid'; Title = 'Radio Moved'; Url = "$dead/moved"; Category = 'Test'; After = 'gone-neighbor'; Retired = '2026-10-01'; Checks = 2; NextCheck = '2026-12-10' }
            [ordered]@{ GUID = 'still-guid'; Title = 'Radio Still'; Url = "$dead/still"; Category = 'Test'; Retired = '2026-10-01'; Checks = 1; NextCheck = '2026-12-10' }
            [ordered]@{ GUID = 'first-guid'; Title = 'Radio First'; Url = "$dead/first"; Category = 'Test'; Retired = '2026-11-16'; Checks = 0; NextCheck = '2026-12-16' }
            [ordered]@{ GUID = 'later-guid'; Title = 'Radio Later'; Url = "$dead/later"; Category = 'Test'; Retired = '2026-12-01'; Checks = 0; NextCheck = '2026-12-31' }
            [ordered]@{ GUID = 'homeless-guid'; Title = 'Radio Homeless'; Url = "$base/stream/back?homeless"; Category = 'Gone category'; NextCheck = '2026-12-01'; Checks = 0 }
            [ordered]@{ GUID = 'clash-guid'; Title = 'Radio Clash'; Url = "$base/stream/elsewhere"; Category = 'Test'; NextCheck = '2026-12-01'; Checks = 0 }
            [ordered]@{ GUID = 'once-guid'; Title = 'Radio Once'; Url = "$base/stream/once"; Category = 'Test'; NextCheck = '2026-12-01'; Checks = 0 }
            # Its neighbor moved to another category since: it goes first in its own (Test), not after the neighbor.
            [ordered]@{ GUID = 'follow-guid'; Title = 'Radio Follow'; Url = "$base/stream/back?follow"; Category = 'Test'; After = $stationIds['Radio Away']; NextCheck = '2026-12-01'; Checks = 0 }
        ) + @(1..6 | ForEach-Object { [ordered]@{ GUID = "dead-$_"; Title = "Radio Dead $_"; Url = "$dead/dead-$_"; Category = 'Test'; NextCheck = '2026-12-01'; Checks = 0 } })
        $script:retiredPath = Join-Path $work 'recheck-retired.json'
        Set-Content -Path $retiredPath -Value (ConvertTo-Json -InputObject $retired -Depth 4)
        $results = Join-Path $work 'recheck-results.json'
        Set-Content -Path $results -Value '[]'
        # The whole list's network guard (half failing) passed in to the recheck, with more than ten retired stations
        # due and most of them still dead: the recheck must search anyway.
        $recheckSearch = $search.Clone()
        $recheckSearch.Catalog = 'ignored.json'
        $recheckSearch.MaxFailureRatio = 0.5
        $script:outcome = Invoke-Lifecycle @{ Catalog = $catalog; RetiredPath = $retiredPath; StatePath = (Join-Path $work 'recheck/failing.json'); ResultsPath = $results; Probed = 100; Date = '2026-12-16'; SearchArguments = $recheckSearch; ReportPath = (Join-Path $work 'recheck.md') }
        $script:after = Read-TestCatalog $catalog
        $script:left = @(Get-Content $retiredPath -Raw | ConvertFrom-Json)
        $script:order = @(foreach ($category in (Get-Content $catalog -Raw | ConvertFrom-Json)) { $category.List | ForEach-Object { $_.Title } })
    }

    It 'restores a station whose old url plays again, verbatim and after the station it followed' {
        @($outcome.Restored.Title) | Should -Contain 'Radio Back'
        $after['Radio Back'].ImageUrl | Should -Be 'back.png'
        $order.IndexOf('Radio Back') | Should -Be ($order.IndexOf('Radio Alive') + 1)
    }

    It 'restores a station found at a new url, and one added by hand without its block' {
        $after['Radio Moved'].Url | Should -Be "$base/stream/moved-new"
        $order.IndexOf('Radio Moved') | Should -BeLessThan $order.IndexOf('Radio Alive') -Because 'without the station before it, it goes first in its category'
        $after['Radio Hand'].Url | Should -Be "$base/stream/hand"
        @($left.Title) | Should -Not -Contain 'Radio Back'
    }

    It 'restores only on two probes that heard audio, and never after a neighbor that moved to another category' {
        @($left.Title) | Should -Contain 'Radio Once' -Because 'its old url played once, then failed'
        $order.IndexOf('Radio Follow') | Should -BeLessThan $order.IndexOf('Radio Alive') -Because 'it goes first in Test'
        $after['Radio Away'] | Should -Not -BeNullOrEmpty
    }

    It 'rechecks on a growing schedule: 30 days after retirement, then 60, then 90' {
        ($left | Where-Object Title -eq 'Radio First').NextCheck | Should -Be '2027-02-14' -Because 'after the first failed check, 60 days'
        ($left | Where-Object Title -eq 'Radio First').Checks | Should -Be 1
        ($left | Where-Object Title -eq 'Radio Still').NextCheck | Should -Be '2027-03-16' -Because 'after the second failed check, 90 days'
        ($left | Where-Object Title -eq 'Radio Later').Checks | Should -Be 0 -Because 'not due yet'
    }

    It 'keeps a station retired when its category is gone or another station has its url, and says why' {
        @($left.Title) | Should -Contain 'Radio Homeless'
        @($left.Title) | Should -Contain 'Radio Clash'
        $report = Get-Content (Join-Path $work 'recheck.md') -Raw
        $report | Should -Match '## Restored'
        $report | Should -Match '\| Radio Clash \| 1 \| 2027-02-14 \| .* another station has it'
        $report | Should -Match '\| Radio Still \| 2 \| 2027-03-16 \| no url plays \|'
    }
}

Describe 'Libraries: catalogue edits, retries, Sentry, metrics' {
    It 'cuts out the last station of a category with the comma before it, and finds nothing for an unknown GUID' {
        $text = "[{`"Name`": `"T`", `"List`": [{`"GUID`": `"a`", `"Url`": `"u`"}, {`"GUID`": `"b`", `"Url`": `"v`"}]}]"
        Get-ListWithoutStation $text 'b' | Should -Be "[{`"Name`": `"T`", `"List`": [{`"GUID`": `"a`", `"Url`": `"u`"}]}]"
        Get-ListWithoutStation $text 'nope' | Should -BeNullOrEmpty
        Get-StationBlock $text 'nope' | Should -BeNullOrEmpty
        Add-StationBlock $text '{"GUID": "c"}' 'nope' 'Missing' | Should -BeNullOrEmpty
        Add-StationBlock "[{`"Name`": `"T`",`r`n `"List`": [`r`n  {`"GUID`": `"a`", `"Url`": `"u`"}]}]" '{"GUID": "c"}' 'a' 'T' | Should -Match "`"u`"},`r`n  \{`"GUID`": `"c`"\}"
    }

    It 'refuses a list that is not a station list' {
        { Read-StationList '[{"Name": "T"}]' } | Should -Throw '*every category needs*'
        { Read-StationList '[{"Name": "T", "List": [{"Title": "no guid"}]}]' } | Should -Throw '*no GUID or no Url*'
        { Read-StationList '[]' } | Should -Throw '*not a station list*'
        { Read-StationList '[{"Name": "T", "List": [{"GUID": "a", "Url": "u"}, {"GUID": "A", "Url": "v"}]}]' } | Should -Throw '*twice*'
    }

    It 'never writes a list cut short: the refresh stops before probing' {
        $cut = Join-Path $work 'cut.json'
        $text = "[{`"Name`": `"Test`", `"List`": [{`"GUID`": `"a`", `"Title`": `"A`", `"Url`": `"$dead/a`"}"
        [IO.File]::WriteAllText($cut, $text)
        { & (Join-Path $scripts 'Update-StationUrls.ps1') -Catalog $cut @search 6>$null } | Should -Throw
        [IO.File]::ReadAllText($cut) | Should -BeExactly $text
    }

    It 'searches and writes nothing when most stations fail at once (the runner''s network is blocked)' {
        $blocked = Join-Path $work 'blocked.json'
        Write-CategoryList $blocked ([ordered]@{ Test = @(0..10 | ForEach-Object { @{ Title = "Radio $_"; Url = "$dead/$_" } }) }) | Out-Null
        $before = [IO.File]::ReadAllText($blocked)
        $report = Join-Path $work 'blocked.md'
        $arguments = $search.Clone()
        $arguments.MaxFailureRatio = 0.5
        $results = & (Join-Path $scripts 'Update-StationUrls.ps1') -Catalog $blocked -ReportPath $report @arguments 6>$null
        @($results).Count | Should -Be 11
        @($results | Where-Object Tried -gt 0) | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($blocked) | Should -BeExactly $before
        Get-Content $report -Raw | Should -Match "Not searched: the runner's network"
    }

    It 'tries again with a growing pause, counts the retries, and gives up with the last error' {
        $env:RORADIO_REFRESH_RETRIES = $null
        $script:calls = 0
        Invoke-WithRetry -BaseDelaySeconds 0 { $script:calls++; if ($script:calls -lt 3) { throw 'busy' }; 'done' } 3>$null | Should -Be 'done'
        Get-RetryTotal | Should -Be 2 -Because 'the count lives in the process, where the scripts the refresh runs inside each other all see it'
        { Invoke-WithRetry -Attempts 2 -BaseDelaySeconds 0 { throw 'down' } 3>$null } | Should -Throw 'down'
    }

    It 'writes a file whole, through a rename' {
        $path = Join-Path $work 'atomic.txt'
        Write-FileAtomic $path 'one'
        Write-FileAtomic $path 'two' $true
        [IO.File]::ReadAllText($path) | Should -Be 'two'
        Test-Path "$path.$PID.tmp" | Should -BeFalse
    }

    It 'keeps every secret out of what it reports' {
        $env:REFRESH_TOKEN = 'token-of-the-test'
        try {
            Protect-Text 'push https://x-access-token:abc123@github.com/x.git with token-of-the-test' | Should -Be 'push https://x-access-token:[redacted]@github.com/x.git with [redacted]'
        } finally {
            $env:REFRESH_TOKEN = $null
        }
    }

    It 'sends an event with tags, breadcrumbs and the exception to Sentry, and nothing without a DSN' {
        Remove-Item $sentryLog -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 105; $i++) { Add-Breadcrumb 'test' "step $i" }
        $script:Breadcrumbs.Count | Should -Be 100
        $script:SentryTags = @{ run_id = '42' }
        try { throw 'probe exploded' } catch { $record = $_ }
        Send-SentryEvent -Message 'test failure' -Tags @{ stage = 'urls'; station = 'Radio Beta'; source = 'radio-browser' } -ErrorRecord $record -Dsn $dsn | Should -BeTrue
        $sent = Get-Content $sentryLog -Raw
        $sent | Should -Match '"type":"event"'
        $sent | Should -Match '"run_id":"42"'
        $sent | Should -Match '"station":"Radio Beta"'
        $sent | Should -Match 'probe exploded'
        $sent | Should -Match 'step 104'
        Send-SentryEvent -Message 'none' -Dsn '' | Should -BeFalse
        Send-SentryEvent -Message 'refused' -Dsn 'http://key@127.0.0.1:1/1' 3>$null | Should -BeFalse
    }

    It 'reports a failed stage to Sentry, times it, and throws on' {
        Remove-Item $sentryLog -ErrorAction SilentlyContinue
        $env:SENTRY_DSN = $dsn
        try {
            { Measure-Stage 'broken' { throw 'stage failed' } } | Should -Throw 'stage failed'
        } finally {
            $env:SENTRY_DSN = $null
        }
        $script:RunMetrics.Stages['broken'] | Should -Not -BeNullOrEmpty
        Get-Content $sentryLog -Raw | Should -Match '"stage":"broken"'
    }

    It 'ranks the strong sources by hit rate, a source without data last' {
        $metrics = Join-Path $work 'rank.jsonl'
        Set-Content -Path $metrics -Value @(
            '{"Sources": {"myradioonline": {"Queries": 10, "Hits": 1}, "radio-browser": {"Queries": 10, "Hits": 5}}}'
            '{"Sources": {"myradioonline": {"Queries": 10, "Hits": 1}, "radio-browser": {"Queries": 10, "Hits": 3}}}')
        Get-SourceRanking $metrics | Should -Be @('radio-browser', 'myradioonline', 'same-server')
        Get-SourceRanking (Join-Path $work 'none.jsonl') | Should -Be @('myradioonline', 'radio-browser', 'same-server')
        Format-RunTrend (Join-Path $work 'none.jsonl') | Should -BeNullOrEmpty
        $script:RunMetrics = [ordered]@{ Date = '2026-12-16'; Stages = [ordered]@{ urls = 1 } }
        Write-RunMetric (Join-Path $work 'new/runs.jsonl')
        (Get-Content (Join-Path $work 'new/runs.jsonl') | ConvertFrom-Json).Date | Should -Be '2026-12-16'
    }
}

Describe 'The whole run (Invoke-Refresh.ps1) and its data branch' {
    BeforeAll {
        # A checkout of the list with its remote, a test script that passes, and the run's folders.
        $script:remote = Join-Path $work 'run-remote.git'
        $script:checkout = Join-Path $work 'run-checkout'
        git init -q --bare -b master $remote
        git init -q -b master $checkout
        $script:stationIds = Write-CategoryList (Join-Path $checkout 'RadioStationsData.json') ([ordered]@{
            Test = @(@{ Title = 'Radio Alive'; Url = "$base/stream/alive" }, @{ Title = 'Radio Gamma'; Url = "$dead/gamma" }, @{ Title = 'Radio Gone'; Url = "$dead/gone" })
        })
        New-Item -ItemType Directory -Path (Join-Path $checkout 'RadioLogos') | Out-Null
        Set-Content -Path (Join-Path $checkout 'RadioLogos/keep.txt') -Value 'logos'
        git -C $checkout add -A
        git -C $checkout -c user.name=test -c user.email=test@example.com commit -q -m 'start'
        git -C $checkout push -q $remote master 2>$null
        $script:passing = Join-Path $work 'pass.ps1'
        Set-Content -Path $passing -Value 'param([string]$Python) Write-Verbose "tests pass with $Python"'
        $script:runArguments = @{
            Repository         = 'ventura8/RoRadioResources'
            RunId              = '777'
            RunUrl             = 'https://github.com/ventura8/RoRadioResources/actions/runs/777'
            TestScript         = $passing
            Python             = (Get-TestPython)
            SearchArguments    = ($search + @{ Catalog = (Join-Path $checkout 'RadioStationsData.json') })
            # Three stations, two of them broken on purpose: the mass-failure guard is tested on its own.
            LifecycleArguments = @{ Catalog = (Join-Path $checkout 'RadioStationsData.json'); RetiredPath = (Join-Path $checkout 'RetiredStations.json'); MassFailureRatio = 1 }
            LogoArguments      = @{ Catalog = (Join-Path $checkout 'RadioStationsData.json'); LogoFolder = (Join-Path $checkout 'RadioLogos'); MyRadioOnlineUrl = $base; RadioBrowserUrl = $base }
            PublishArguments   = @{ Gh = $fakeGh; Remote = $remote; RepositoryPath = $checkout; RetryDelaySeconds = 0; Date = '2026-12-16' }
        }
        function Invoke-Run([string]$Name, [hashtable]$Extra = @{}) {
            $folder = Join-Path $work $Name
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            $env:FAKE_GH_LOG = Join-Path $folder 'gh.log'
            $all = $runArguments.Clone()
            $all.WorkFolder = $folder
            foreach ($key in $Extra.Keys) { $all[$key] = $Extra[$key] }
            & (Join-Path $scripts 'Invoke-Refresh.ps1') @all 6>$null 3>$null
        }
    }

    AfterEach {
        foreach ($name in 'FAKE_GH_LOG', 'FAKE_GH_PR_STATE', 'FAKE_GH_RUNS', 'FAKE_GH_AUTH_EXIT', 'FAKE_GH_BAD_TOKEN', 'FALLBACK_TOKEN', 'SENTRY_DSN', 'GH_TOKEN') { Set-Item "env:$name" $null }
    }

    It 'runs from start to end: fixes through a source that failed once, publishes, and saves its data on the refresh-data branch' {
        Invoke-Run 'run1' @{ Logos = $true; Merge = $true; AutoMerge = $true }
        $log = Get-Content (Join-Path $work 'run1/gh.log')
        ($log | Where-Object { $_ -like 'pr create *' }) | Should -Not -BeNullOrEmpty
        ($log | Where-Object { $_ -like 'pr merge automation/station-refresh --auto *' }) | Should -Not -BeNullOrEmpty
        (Read-TestCatalog (Join-Path $checkout 'RadioStationsData.json'))['Radio Gamma'].Url | Should -Be "$base/stream/flaky-source" -Because 'the source answered 503 once, and the retry found the stream'
        $data = Join-Path $work 'data-check'
        git clone -q --branch refresh-data $remote $data 2>$null
        $state = Get-Content (Join-Path $data 'state/failing.json') -Raw | ConvertFrom-Json
        $state.($stationIds['Radio Gone']).FirstFailed | Should -Not -BeNullOrEmpty
        $run = Get-Content (Join-Path $data 'metrics/runs.jsonl') | ConvertFrom-Json
        $run.RunId | Should -Be '777'
        $run.Probed | Should -Be 3
        $run.Fixed | Should -Be 1
        $run.Sources.myradioonline.Hits | Should -Be 1
        $run.Stages.urls | Should -Not -BeNullOrEmpty
        $run.Stages.publish | Should -Not -BeNullOrEmpty -Because 'the record is written after publishing'
        $run.Retries | Should -BeGreaterThan 0 -Because 'the source that answered 503 once was read again'
        $run.FailingDays.'Radio Gone' | Should -Be 0
    }

    It 'runs again over the same data without piling anything up (an idempotent rerun)' {
        $env:FAKE_GH_PR_STATE = 'OPEN'
        Invoke-Run 'run2'
        $log = Get-Content (Join-Path $work 'run2/gh.log')
        ($log | Where-Object { $_ -like 'pr create *' }) | Should -BeNullOrEmpty
        $data = Join-Path $work 'data-check2'
        git clone -q --branch refresh-data $remote $data 2>$null
        @(Get-Content (Join-Path $data 'metrics/runs.jsonl')).Count | Should -Be 2
    }

    It 'leaves everything alone in a dry run' {
        $before = Get-Content (Join-Path $checkout 'RadioStationsData.json') -Raw
        Invoke-Run 'dry' @{ DryRun = $true }
        Get-Content (Join-Path $checkout 'RadioStationsData.json') -Raw | Should -Be $before
        Test-Path (Join-Path $work 'dry/gh.log') | Should -BeFalse -Because 'a dry run publishes nothing'
    }

    It 'falls back to the workflow token when REFRESH_TOKEN has expired, and tells Sentry' {
        Remove-Item $sentryLog -ErrorAction SilentlyContinue
        $env:GH_TOKEN = 'expired-refresh-token'
        $env:FAKE_GH_BAD_TOKEN = 'expired-refresh-token'
        $env:FALLBACK_TOKEN = 'workflow-token-value'
        $env:SENTRY_DSN = $dsn
        Invoke-Run 'fallback'
        $env:GH_TOKEN | Should -Be 'workflow-token-value'
        $sent = Get-Content $sentryLog -Raw
        $sent | Should -Match 'fell back to GITHUB_TOKEN'
        $sent | Should -Not -Match 'expired-refresh-token' -Because 'no secret leaves'
    }

    It 'stops with the reason, and reports to Sentry, when no token works' {
        Remove-Item $sentryLog -ErrorAction SilentlyContinue
        $env:FAKE_GH_AUTH_EXIT = '1'
        $env:SENTRY_DSN = $dsn
        { Invoke-Run 'no-token' @{ Stage = 'Publish' } } | Should -Throw '*Set the REFRESH_TOKEN secret again*'
        Get-Content $sentryLog -Raw | Should -Match '"stage":"token"'
    }

    It 'records a search that never finished, without publishing anything' {
        Invoke-Run 'no-search' @{ Stage = 'Publish' }
        (Get-Content (Join-Path $work 'no-search/gh.log') | Where-Object { $_ -like 'pr *' }) | Should -BeNullOrEmpty
        $last = git --git-dir $remote show refresh-data:metrics/runs.jsonl | Select-Object -Last 1 | ConvertFrom-Json
        $last.Failed | Should -BeTrue
        $last.Error | Should -Match 'did not finish'
    }

    It 'records a failed search with its stage, and the publish part saves it' {
        $broken = Join-Path $work 'broken-list.json'
        [IO.File]::WriteAllText($broken, '[{"Name": "Test", "List": [')
        $searchBroken = $runArguments.SearchArguments.Clone()
        $searchBroken.Catalog = $broken
        { Invoke-Run 'failed-search' @{ Stage = 'Search'; SearchArguments = $searchBroken } } | Should -Throw '*not complete JSON*'
        (Get-Content (Join-Path $work 'failed-search/refresh-run.json') -Raw | ConvertFrom-Json).FailedStage | Should -Be 'urls'
        Invoke-Run 'failed-search' @{ Stage = 'Publish' }
        $last = git --git-dir $remote show refresh-data:metrics/runs.jsonl | Select-Object -Last 1 | ConvertFrom-Json
        $last.FailedStage | Should -Be 'urls'
    }

    It 'records a failed publication, and reports a failure between stages to Sentry' {
        $env:FAKE_GH_FAIL = 'issue list'
        try {
            { Invoke-Run 'failed-publish' @{ Stage = 'All'; Merge = $true } } | Should -Throw '*issue list*'
        } finally {
            $env:FAKE_GH_FAIL = $null
        }
        $last = git --git-dir $remote show refresh-data:metrics/runs.jsonl | Select-Object -Last 1 | ConvertFrom-Json
        $last.FailedStage | Should -Be 'publish'
        $last.Stages.publish | Should -Not -BeNullOrEmpty

        Remove-Item $sentryLog -ErrorAction SilentlyContinue
        $env:SENTRY_DSN = $dsn
        $folder = Join-Path $work 'corrupt-run'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Set-Content -Path (Join-Path $folder 'refresh-run.json') -Value '{ not json'
        # Its data remote is gone too: the record of the failure cannot be saved, which is said, not hidden.
        $publishNowhere = $runArguments.PublishArguments.Clone()
        $publishNowhere.Remote = Join-Path $work 'gone-remote.git'
        { Invoke-Run 'corrupt-run' @{ Stage = 'Publish'; PublishArguments = $publishNowhere; WarningVariable = 'warned' } } | Should -Throw
        Get-Content $sentryLog -Raw | Should -Match 'The refresh failed'
    }

    It 'runs the daily retry only when no refresh succeeded this week, judged by the recorded runs' {
        $output = Join-Path $work 'due.txt'
        $due = @{ Stage = 'Due'; RetryOnly = $true; OutputPath = $output; WorkFolder = (Join-Path $work 'due-1'); PublishArguments = @{ Remote = $remote; RetryDelaySeconds = 0 } }
        & (Join-Path $scripts 'Invoke-Refresh.ps1') @due 6>$null | Should -BeFalse -Because 'today''s successful run is recorded'
        $failedOnly = Join-Path $work 'failed-only.git'
        git init -q --bare -b master $failedOnly
        $seed = Join-Path $work 'failed-only-seed'
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Pull -Path $seed -Remote $failedOnly
        New-Item -ItemType Directory -Force -Path (Join-Path $seed 'metrics') | Out-Null
        Set-Content -Path (Join-Path $seed 'metrics/runs.jsonl') -Value "{`"Date`": `"$([DateTime]::UtcNow.ToString('yyyy-MM-dd'))`", `"Failed`": true}"
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Push -Path $seed -Remote $failedOnly
        $due.WorkFolder = Join-Path $work 'due-2'
        $due.PublishArguments = @{ Remote = $failedOnly; RetryDelaySeconds = 0 }
        & (Join-Path $scripts 'Invoke-Refresh.ps1') @due 6>$null | Should -BeTrue -Because 'a failed run, or a skipped retry, is no refresh'
        & (Join-Path $scripts 'Invoke-Refresh.ps1') -Stage Due | Should -BeTrue -Because 'the weekly run always has work'
        Get-Content $output | Should -Be @('due=false', 'due=true')
    }

    It 'reports a retry check that cannot read the data to Sentry' {
        Remove-Item $sentryLog -ErrorAction SilentlyContinue
        $env:SENTRY_DSN = $dsn
        { & (Join-Path $scripts 'Invoke-Refresh.ps1') -Stage Due -RetryOnly -WorkFolder (Join-Path $work 'due-3') -PublishArguments @{ Remote = (Join-Path $work 'no-such.git'); RetryDelaySeconds = 0 } 6>$null 3>$null } | Should -Throw
        Get-Content $sentryLog -Raw | Should -Match '"stage":"due"'
    }

    It 'keeps both runs'' metrics lines when two runs race for the data branch' {
        $one = Join-Path $work 'race-one'
        $two = Join-Path $work 'race-two'
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Pull -Path $one -Remote $remote
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Pull -Path $two -Remote $remote
        Add-Content -Path (Join-Path $one 'metrics/runs.jsonl') -Value '{"RunId": "one"}'
        Add-Content -Path (Join-Path $two 'metrics/runs.jsonl') -Value '{"RunId": "two"}'
        Set-Content -Path (Join-Path $one 'state/failing.json') -Value '{"from": "one"}'
        Set-Content -Path (Join-Path $two 'state/failing.json') -Value '{"from": "two"}'
        Set-Content -Path (Join-Path $two 'new.txt') -Value 'two'
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Push -Path $one -Remote $remote -RetryDelaySeconds 0
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Push -Path $two -Remote $remote -RetryDelaySeconds 0 3>$null
        & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Push -Path $two -Remote $remote -RetryDelaySeconds 0 6>$null
        $lines = @(git --git-dir $remote show refresh-data:metrics/runs.jsonl)
        $lines | Should -Contain '{"RunId": "one"}'
        $lines | Should -Contain '{"RunId": "two"}'
        $lines.IndexOf('{"RunId": "one"}') | Should -BeLessThan $lines.IndexOf('{"RunId": "two"}')
        git --git-dir $remote show refresh-data:state/failing.json | Should -Be '{"from": "two"}' -Because 'the newer run owns the state'
        @(git --git-dir $remote ls-tree -r --name-only refresh-data) | Should -Contain 'new.txt'
    }

    It 'stops when the data remote cannot be reached' {
        { & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Pull -Path (Join-Path $work 'nowhere-data') -Remote (Join-Path $work 'no-such-remote.git') -RetryDelaySeconds 0 3>$null } | Should -Throw '*ls-remote*'
        $env:GH_TOKEN = 'token-value'
        $env:GIT_ALLOW_PROTOCOL = 'file'
        try {
            { & (Join-Path $scripts 'Sync-RefreshData.ps1') -Mode Pull -Path (Join-Path $work 'default-data') -Repository 'ventura8/none' -RetryDelaySeconds 0 3>$null } | Should -Throw
        } finally {
            $env:GIT_ALLOW_PROTOCOL = $null
        }
    }
}

Describe 'The weekly workflow installs what its test stage needs' {
    It 'installs the pinned Python tools and the pinned npm packages (axe-core), as CI does' {
        # Regression: from 2026-11-24 every run failed in the search stage's tests because
        # tests/receiver.browser.test.js loads axe-core from scripts/ci/node_modules and only CI installed it.
        $workflows = Join-Path (Split-Path $PSScriptRoot -Parent) '.github/workflows'
        $refresh = Get-Content -Raw (Join-Path $workflows 'refresh-stations.yml')
        $ci = Get-Content -Raw (Join-Path $workflows 'ci.yml')
        foreach ($install in 'npm ci --prefix scripts/ci', 'pip install --quiet -r scripts/ci/requirements.txt') {
            $ci | Should -Match ([regex]::Escape($install)) -Because 'CI is the reference for the test stage'
            $refresh | Should -Match ([regex]::Escape($install)) -Because 'the refresh runs the same tests'
        }
    }
}
