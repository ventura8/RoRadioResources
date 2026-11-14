#Requires -Version 7.0
# The weekly refresh end to end (.github/workflows/refresh-stations.yml): the real scripts against a fake of everything
# they talk to (tests/e2e/fake_station_server.py on 127.0.0.1: streams that work, are broken or have moved, and the
# pages the refresh scrapes) and a fake GitHub CLI (tests/e2e/fake-gh.ps1), with a real git repository and remote.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:scripts = Join-Path $root 'scripts'
    . (Join-Path $PSScriptRoot 'e2e/FakeServer.ps1')
    $script:python = Get-TestPython
    $script:work = Join-Path ([IO.Path]::GetTempPath()) "roradio-e2e-$([Guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $work | Out-Null

    # Logo images: distinct, logo-shaped and not blank; one too small to be a logo; one that is no image at all.
    $script:images = Join-Path $work 'images'
    New-Item -ItemType Directory -Path $images | Out-Null
    $draw = @'
import sys
from PIL import Image, ImageDraw
folder = sys.argv[1]
for name, colour, size in [("blue", "#1060c0", 256), ("green", "#10a040", 256), ("red", "#c01010", 256),
                           ("purple", "#8010c0", 256), ("orange", "#e08010", 256), ("same", "#404040", 256),
                           ("teal", "#108080", 256), ("small", "#c0c010", 32)]:
    image = Image.new("RGB", (size, size), colour)
    ImageDraw.Draw(image).rectangle((size // 4, size // 4, size // 2, size // 2), fill="white")
    image.save(f"{folder}/{name}.png")
'@
    & $python -c $draw $images
    if ($LASTEXITCODE -ne 0) { throw 'Could not draw the test logos (Python with Pillow is needed).' }
    Set-Content -Path (Join-Path $images 'text.png') -Value 'not an image' -Encoding utf8

    $hls = 'application/vnd.apple.mpegurl'
    $routes = @(
        # Streams.
        @{ path = '/stream/alpha'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/beta-new'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/gamma-new'; type = 'audio/aac'; audio = 8192 }
        @{ path = '/stream/gamma-other'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/gamma-us'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/delta-old'; type = 'audio/mpeg' }
        @{ path = '/delta-live'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/zeta-old'; type = 'audio/mpeg' }
        @{ path = '/zeta-live'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/zeta-ice'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/eps'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/eta'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/theta-new'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/stream/mu-flaky'; type = 'audio/mpeg'; audio = 8192; times = 1 }
        @{ path = '/stream/mu-flaky'; status = 404; body = 'gone' }
        @{ path = '/stream/nu-blip'; status = 503; body = 'busy'; times = 1 }
        @{ path = '/stream/nu-blip'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/icy'; icy = (Join-Line "`r`n" 'ICY 200 OK' 'content-type: audio/aacp' '' ''); audio = 4096 }
        @{ path = '/hls/master.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' '#EXT-X-STREAM-INF:BANDWIDTH=64000' 'variant.m3u8' '') }
        @{ path = '/hls/variant.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' '#EXTINF:10,' 'segment.aac' '') }
        @{ path = '/hls/segment.aac'; type = 'audio/aac'; audio = 4096 }
        @{ path = '/redirect'; status = 302; headers = @{ Location = '{base}/stream/alpha-moved' } }
        @{ path = '/stream/alpha-moved'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/html'; body = '<html><body>Our player moved</body></html>' }

        # myradioonline.ro: the sitemap and the station pages.
        @{ path = '/sitemap.xml'; type = 'application/xml'; body = (
            @('radio-beta', 'theta', 'radio-iota', 'radio-kappa', 'radio-lambda', 'radio-mu', 'radio-page', 'radio-weak', 'other') |
                ForEach-Object { "<url><loc>{base}/$_</loc></url>" }) -join '' }
        @{ path = '/radio-beta'; body = '<img src="{base}/img/beta.png"><audio src="{base}/stream/beta-new?time=1731600000"></audio>' }
        @{ path = '/theta'; body = '<div data-x="1" url="{base}/stream/theta-new"></div>' }
        @{ path = '/radio-iota'; body = '<audio src="{base}/stream/iota-gone"></audio>' }
        @{ path = '/radio-kappa'; body = '<audio src="{base}/stream/alpha"></audio>' }
        @{ path = '/radio-lambda'; body = '<audio src="{base}/stream/beta-new"></audio>' }
        @{ path = '/radio-mu'; body = '<audio src="{base}/stream/mu-flaky"></audio>' }
        @{ path = '/radio-page'; body = '<audio src="{base}/stream/page"></audio><link itemprop="logo" href="{base}/logo/purple.png">' }
        @{ path = '/radio-weak'; body = '<audio src="http://elsewhere.example/stream"></audio><link itemprop="logo" href="{base}/logo/orange.png"><link itemprop="logo" href="{base}/logo/teal.png">' }

        # radio-browser.info.
        @{ path = '/json/stations/search'; query = 'name=Radio%20Gamma'; type = 'application/json'; body = (ConvertTo-Json -Compress -InputObject @(
            @{ name = 'Radio Gamma'; countrycode = 'US'; url_resolved = '{base}/stream/gamma-us'; homepage = 'https://radiogamma.example/' }
            @{ name = 'Radio Gamma FM'; countrycode = 'RO'; url_resolved = '{base}/stream/gamma-other'; homepage = 'https://radiogamma.example/' }
            @{ name = 'Radio Gamma'; countrycode = 'RO'; url_resolved = ''; homepage = 'https://radiogamma.example/' }
            @{ name = 'Radio Gamma'; countrycode = 'RO'; url_resolved = '{base}/stream/gamma-other'; homepage = 'https://other.example/' }
            @{ name = 'Radio Gamma'; countrycode = 'MD'; url_resolved = '{base}/stream/gamma-new'; homepage = 'https://www.radio-gamma.example/' }
        )) }
        @{ path = '/json/stations/search'; query = 'name=Radio%20Bravo'; type = 'application/json'; body = (ConvertTo-Json -Compress -InputObject @(
            @{ stationuuid = 'u3'; name = 'Radio Bravo'; countrycode = 'RO'; homepage = 'https://radiobravo.invalid/'; url_resolved = 'http://radiobravo.invalid/live'; favicon = '{base}/logo/red.png' }
            @{ stationuuid = 'u4'; name = 'Radio Bravo'; countrycode = 'DE'; homepage = 'https://radiobravo.invalid/'; favicon = '{base}/logo/blue.png' }
        )) }
        @{ path = '/json/stations/search'; type = 'application/json'; body = '[]' }
        @{ path = '/json/stations/byurl'; query = 'fav'; type = 'application/json'; body = '[{"stationuuid": "u1", "name": "Radio Fav", "favicon": "{base}/logo/blue.png", "homepage": "{base}/home/fav"}]' }
        @{ path = '/json/stations/byurl'; query = 'home'; type = 'application/json'; body = '[{"stationuuid": "u2", "name": "Radio Home", "homepage": "{base}/home/home"}]' }
        @{ path = '/json/stations/byurl'; query = 'slug'; type = 'application/json'; body = '[{"stationuuid": "u5", "name": "Radio Slug Clash", "favicon": "{base}/logo/teal.png"}]' }
        @{ path = '/json/stations/byurl'; query = 'placeholder'; type = 'application/json'; body = '[{"stationuuid": "u6", "name": "Placeholder", "favicon": "{base}/logo/same.png"}]' }
        @{ path = '/json/stations/byurl'; type = 'application/json'; body = '[]' }
        @{ path = '/home/fav'; body = '<link rel="icon" href="/favicon.ico">' }
        @{ path = '/home/home'; body = (
            '<link href="/no-rel.png"><link rel="icon"><link rel="stylesheet" href="/site.css">' +
            '<link rel="apple-touch-icon" href="http://[broken">' +
            '<link rel="icon" sizes="192x192" href="/logo/none.png">' +
            '<link rel="icon" sizes="256x256" href="/logo/small.png">' +
            '<link rel="icon" sizes="256x256" href="/logo/text.png">' +
            '<link rel="apple-touch-icon" href="/logo/green.png">') }

        # The old servers' status pages (Icecast and Shoutcast), on the same host and port as the old urls.
        @{ path = '/status-json.xsl'; type = 'application/json'; body = '{"icestats": {"source": [{"listenurl": "{base}/delta-live", "server_name": "Radio Delta"}, {"listenurl": "{base}/zeta-ice", "server_name": "Other channel"}, {"server_name": "No url"}]}}' }
        @{ path = '/statistics'; query = 'json=1'; type = 'application/json'; body = '{"streams": [{"streampath": "/zeta-live", "servertitle": "Radio Zeta"}, {"servertitle": "No path"}]}' }

        # The Shoutcast directory and radio.net.
        @{ path = '/Search/UpdateSearch'; method = 'POST'; type = 'application/json'; body = '[{"Name": "Radio Epsilon Hits", "ID": 7}, {"Name": "Radio Epsilon Two", "ID": 9}, {"Name": "Unrelated", "ID": 8}]' }
        @{ path = '/sbin/tunein-station.pls'; query = 'id=7'; type = 'audio/x-scpls'; body = "[playlist]`nFile1={base}/stream/eps`n" }
        @{ path = '/sbin/tunein-station.pls'; query = 'id=9'; type = 'audio/x-scpls'; body = "[playlist]`n" }
        @{ path = '/stations/search'; query = 'query=Radio%20Eta'; type = 'application/json'; body = '{"playables": [{"name": "Radio Eta", "country": "Germany", "id": "eta-de", "streams": [{"url": "{base}/stream/gamma-us"}]}, {"name": "Radio Eta", "country": "Romania", "id": "eta-ro", "streams": [{"url": "{base}/stream/eta"}]}]}' }
        @{ path = '/stations/search'; type = 'application/json'; body = '{"playables": []}' }
        @{ path = '/broken/stations/search'; type = 'text/html'; body = '<html>Service unavailable</html>' }

        # Logos.
        foreach ($name in 'blue', 'green', 'red', 'purple', 'orange', 'same', 'teal', 'small', 'text') {
            @{ path = "/logo/$name.png"; type = 'image/png'; file = (Join-Path $images "$name.png") }
        }
    )
    $script:server = Open-FakeStationServer $routes
    $script:base = $server.Base
    $script:sources = @{
        MyRadioOnlineUrl      = $base
        RadioBrowserUrl       = $base
        ShoutcastDirectoryUrl = $base
        ShoutcastPlaylistUrl  = $base
        RadioNetUrl           = $base
    }
    # The fake list is mostly broken on purpose: the network guard (more than half failing) is tested on its own.
    $script:fast = @{ TimeoutSeconds = 5; RetryDelaySeconds = 0; ThrottleLimit = 8; MaxFailureRatio = 1 }

    # Runs a script and returns its output and its information stream (the report it prints) apart.
    function Invoke-Quiet([string]$Script, [hashtable]$Arguments) {
        $output = & (Join-Path $scripts $Script) @Arguments 6>$null 3>$null
        @($output)
    }
}

AfterAll {
    Close-FakeStationServer $server
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Describe 'The url refresh (Update-StationUrls.ps1 -ReplaceOnlyDead, as the weekly workflow runs it)' {
    BeforeAll {
        $script:catalog = Join-Path $work 'urls.json'
        $dead = 'http://127.0.0.1:1'
        $script:before = Write-TestCatalog $catalog @(
            @{ Title = 'Radio Alpha'; Url = "$base/stream/alpha" }
            @{ Title = 'Radio Beta'; Url = "$dead/beta" }
            @{ Title = 'Radio Gamma'; Url = "$dead/gamma" }
            @{ Title = 'Radio Delta'; Url = "$base/delta-old" }
            @{ Title = 'Radio Zeta'; Url = "$base/zeta-old" }
            @{ Title = 'Radio Epsilon'; Url = "$dead/epsilon" }
            @{ Title = 'Radio Eta'; Url = "$dead/eta" }
            @{ Title = 'Radio Theta'; Url = "$base/theta-old" }
            @{ Title = 'Radio Iota'; Url = "$dead/iota" }
            @{ Title = 'Radio Kappa'; Url = "$dead/kappa" }
            @{ Title = 'Radio Lambda'; Url = "$dead/lambda" }
            @{ Title = 'Radio Mu'; Url = "$dead/mu" }
            @{ Title = 'Radio Nu'; Url = "$base/stream/nu-blip" }
            @{ Title = 'Radio Icy'; Url = "$base/icy" }
            @{ Title = 'Radio Hls'; Url = "$base/hls/master.m3u8" }
            @{ Title = 'Radio Moved'; Url = "$base/redirect" }
            @{ Title = 'Radio Html'; Url = "$base/html" }
        )
        $script:originalBytes = [IO.File]::ReadAllBytes($catalog)
        $script:report = Join-Path $work 'urls.md'
        $script:results = Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $catalog; ReportPath = $report; ReplaceOnlyDead = $true } + $sources + $fast)
        $script:after = Read-TestCatalog $catalog
        $script:byTitle = @{}
        foreach ($result in $results) { $byTitle[$result.Title] = $result }
        $script:reportText = Get-Content $report -Raw
    }

    It 'detects the broken stations, and leaves alone the ones that play (ICY, HLS, a redirect, a blip)' {
        @($results | ForEach-Object Title | Sort-Object) | Should -Be @(
            'Radio Beta', 'Radio Delta', 'Radio Epsilon', 'Radio Eta', 'Radio Gamma', 'Radio Html', 'Radio Iota',
            'Radio Kappa', 'Radio Lambda', 'Radio Mu', 'Radio Theta', 'Radio Zeta')
        $byTitle['Radio Delta'].OldVerdict | Should -Be 'dead'
        $byTitle['Radio Theta'].OldVerdict | Should -Be 'http-404'
        $byTitle['Radio Html'].OldVerdict | Should -Be 'no-audio'
    }

    It 'finds the replacements on myradioonline.ro, radio-browser.info and the old server''s status pages' {
        $byTitle['Radio Beta'].NewUrl | Should -Be "$base/stream/beta-new" -Because 'the cache-buster is removed and the image skipped'
        $byTitle['Radio Beta'].Source | Should -Be "$base/radio-beta"
        $byTitle['Radio Gamma'].NewUrl | Should -Be "$base/stream/gamma-new" -Because 'only the Moldovan entry with the name in its host counts'
        $byTitle['Radio Delta'].NewUrl | Should -Be "$base/delta-live"
        $byTitle['Radio Delta'].Source | Should -Be "same server, Icecast status ($base)"
        $byTitle['Radio Zeta'].NewUrl | Should -Be "$base/zeta-live" -Because 'the brand-only mark matches two mounts, the full name one'
        $byTitle['Radio Zeta'].Source | Should -Be "same server, Shoutcast status ($base)"
    }

    It 'writes the verified urls into the list, and nothing else' {
        foreach ($title in 'Radio Beta', 'Radio Gamma', 'Radio Delta', 'Radio Zeta') {
            $after[$title].Url | Should -Be $byTitle[$title].NewUrl
        }
        $changed = @($before | Where-Object { $after[$_.Title].Url -ne $_.Url } | ForEach-Object Title)
        $changed | Should -Be @('Radio Beta', 'Radio Gamma', 'Radio Delta', 'Radio Zeta')
    }

    It 'never removes, renames or reorders a station, and keeps the file''s format' {
        $titles = @(foreach ($category in (Get-Content $catalog -Raw | ConvertFrom-Json)) { $category.List | ForEach-Object { "$($_.GUID) $($_.Title)" } })
        $titles | Should -Be @($before | ForEach-Object { "$($_.GUID) $($_.Title)" })
        $bytes = [IO.File]::ReadAllBytes($catalog)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $old = [Text.Encoding]::UTF8.GetString($originalBytes) -split "`n"
        $new = [Text.Encoding]::UTF8.GetString($bytes) -split "`n"
        $new.Count | Should -Be $old.Count
        @(for ($i = 0; $i -lt $old.Count; $i++) { if ($old[$i] -ne $new[$i]) { $new[$i] } }).Count | Should -Be 4 -Because 'one Url line per fix'
    }

    It 'never writes an unverified url: a dead candidate, one that fails the second probe, another station''s stream' {
        foreach ($title in 'Radio Iota', 'Radio Mu', 'Radio Kappa', 'Radio Lambda', 'Radio Html') {
            $byTitle[$title].NewUrl | Should -BeNullOrEmpty -Because $title
            $byTitle[$title].Suggested | Should -BeNullOrEmpty -Because $title
            $after[$title].Url | Should -Be ($before | Where-Object Title -eq $title).Url
        }
        $byTitle['Radio Iota'].Tried | Should -Be 1
        $byTitle['Radio Mu'].Tried | Should -Be 1 -Because 'alive once, then gone: not written'
        $byTitle['Radio Kappa'].Tried | Should -Be 0 -Because 'Radio Alpha plays that stream'
        $byTitle['Radio Lambda'].Tried | Should -Be 0 -Because 'Radio Beta took that stream earlier in the run'
    }

    It 'only suggests what a name match or a non-dead station found' {
        $byTitle['Radio Epsilon'].Suggested | Should -Be "$base/stream/eps"
        $byTitle['Radio Epsilon'].Source | Should -Be 'Shoutcast directory: Radio Epsilon Hits (id 7)'
        $byTitle['Radio Eta'].Suggested | Should -Be "$base/stream/eta"
        $byTitle['Radio Eta'].Source | Should -Be 'radio.net (eta-ro)'
        $byTitle['Radio Theta'].Suggested | Should -Be "$base/stream/theta-new" -Because 'HTTP 404 from a US runner can be geo-blocking'
        foreach ($title in 'Radio Epsilon', 'Radio Eta', 'Radio Theta') {
            $byTitle[$title].NewUrl | Should -BeNullOrEmpty
            $after[$title].Url | Should -Be ($before | Where-Object Title -eq $title).Url
        }
    }

    It 'reports what it fixed, what needs review and what it could not fix, with links' {
        $reportText | Should -Match 'Probed 17 stations; 12 failed twice; 4 fixed\.'
        $reportText | Should -Match ([regex]::Escape("| Radio Beta | dead | ``$($before[1].Url)`` | ``$base/stream/beta-new`` | [127.0.0.1:$(([Uri]$base).Port)/radio-beta]($base/radio-beta) |"))
        $reportText | Should -Match ([regex]::Escape("radio-browser.info ([https://www.radio-gamma.example/](https://www.radio-gamma.example/))"))
        $reportText | Should -Match ([regex]::Escape("same server, Icecast status ([$base]($base))"))
        $reportText | Should -Match ([regex]::Escape('[radio.net (eta-ro)](https://www.radio.net/s/eta-ro)'))
        $reportText | Should -Match ([regex]::Escape('`Shoutcast directory: Radio Epsilon Hits (id 7)`'))
        $reportText | Should -Match '## Needs review'
        $reportText | Should -Match '## Unresolved'
        $reportText | Should -Match ([regex]::Escape("| Radio Iota | dead | ``http://127.0.0.1:1/iota`` | 1 |"))
        $reportText | Should -Not -Match 'Sources that could not be read'
    }
}

Describe 'The dry run, a source that is down, and a run with nothing to fix' {
    BeforeAll {
        $script:catalog = Join-Path $work 'dry.json'
        $script:stations = Write-TestCatalog $catalog @(
            @{ Title = 'Radio Alpha'; Url = "$base/stream/alpha" }
            @{ Title = 'Radio Theta'; Url = "$base/theta-old" }
        )
        $script:originalBytes = [IO.File]::ReadAllBytes($catalog)
    }

    It 'finds the fix but writes nothing under -WhatIf, and names the sources it could not read' {
        $report = Join-Path $work 'dry.md'
        $down = $sources.Clone()
        $down.RadioBrowserUrl = "$base/down"
        $down.ShoutcastDirectoryUrl = "$base/down"
        $results = Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $catalog; ReportPath = $report; WhatIf = $true } + $down + $fast)
        $results.NewUrl | Should -Be "$base/stream/theta-new" -Because 'a run from Romania replaces an HTTP error too'
        [IO.File]::ReadAllBytes($catalog) | Should -Be $originalBytes
        $text = Get-Content $report -Raw
        $text | Should -Match '## Sources that could not be read'
        $text | Should -Match ([regex]::Escape("- ``$base/down/json/stations/search?hidebroken=true&limit=50&name=Radio%20Theta``"))
        $text | Should -Match ([regex]::Escape("- ``$base/down/Search/UpdateSearch``"))
    }

    It 'probes only the stations named, and reports a run with nothing broken' {
        $report = Join-Path $work 'none.md'
        $results = Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $catalog; ReportPath = $report; Title = 'radio ALPHA' } + $sources + $fast)
        $results | Should -BeNullOrEmpty
        (Get-Content $report -Raw).Trim() | Should -Be 'Probed 1 stations; 0 failed twice; 0 fixed.'
        [IO.File]::ReadAllBytes($catalog) | Should -Be $originalBytes
    }

    It 'reports radio.net when it answers no JSON, and survives a malformed old url' {
        $broken = Join-Path $work 'broken.json'
        Write-TestCatalog $broken @(@{ Title = 'Radio Broken'; Url = 'http://[broken' }) | Out-Null
        $report = Join-Path $work 'broken.md'
        $arguments = $sources.Clone()
        $arguments.RadioNetUrl = "$base/broken"
        $results = Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $broken; ReportPath = $report; WhatIf = $true } + $arguments + $fast)
        $results.OldVerdict | Should -Be 'dead'
        $results.Tried | Should -Be 0
        Get-Content $report -Raw | Should -Match ([regex]::Escape("- ``$base/broken/stations/search?count=10&query=Radio%20Broken``"))
    }

    It 'reads the real list by default (only the stations named: none here, so nothing is requested)' {
        $results = Invoke-Quiet 'Update-StationUrls.ps1' @{ Title = 'Nowhere At All'; WhatIf = $true }
        $results | Should -BeNullOrEmpty
        $results = Invoke-Quiet 'Update-StationLogos.ps1' @{ Title = 'Nowhere At All'; WhatIf = $true }
        $results | Should -BeNullOrEmpty
    }

    It 'refuses a source that is not a public address' {
        $env:RORADIO_REFRESH_ALLOW_LOOPBACK = $null
        try {
            $report = Join-Path $work 'private.md'
            Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $catalog; ReportPath = $report; Title = 'Radio Alpha', 'Radio Theta'; WhatIf = $true } + $sources + $fast) | Out-Null
            Get-Content $report -Raw | Should -Match ([regex]::Escape("- ``$base/Search/UpdateSearch``"))
        } finally {
            $env:RORADIO_REFRESH_ALLOW_LOOPBACK = '1'
        }
    }

    It 'writes nothing when the url line cannot be found where the station is' {
        $odd = Join-Path $work 'odd.json'
        $json = "[{`"Name`": `"Test`", `"List`": [{`"Url`": `"http://127.0.0.1:1/x`", `"GUID`": `"$([Guid]::NewGuid())`", `"Title`": `"Radio Beta`"}]}]"
        [IO.File]::WriteAllText($odd, $json)
        { Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $odd } + $sources + $fast) } | Should -Throw '*Could not find the Url line*'
        Get-Content $odd -Raw | Should -Be $json
    }

    It 'writes nothing when the result would change more than the fixed urls' {
        $twice = Join-Path $work 'twice.json'
        $guid = [Guid]::NewGuid().ToString()
        $json = "[{`"Name`": `"Test`", `"List`": [{`"GUID`": `"$guid`", `"Title`": `"Radio Beta`", `"Url`": `"http://127.0.0.1:1/x`"}, {`"GUID`": `"$guid`", `"Title`": `"Radio Alpha`", `"Url`": `"$base/stream/alpha`"}]}]"
        [IO.File]::WriteAllText($twice, $json)
        { Invoke-Quiet 'Update-StationUrls.ps1' (@{ Catalog = $twice } + $sources + $fast) } | Should -Throw '*nothing was written*'
        Get-Content $twice -Raw | Should -Be $json
    }
}

Describe 'The stream probe (Test-StationStreams.ps1)' {
    BeforeAll {
        $script:catalog = Join-Path $work 'probe.json'
        Write-TestCatalog $catalog @(
            @{ Title = 'Radio Alpha'; Url = "$base/stream/alpha" }
            @{ Title = 'Radio Html'; Url = "$base/html" }
        ) | Out-Null
    }

    It 'probes the catalogue and lists the failures first' {
        $results = Invoke-Quiet 'Test-StationStreams.ps1' @{ Catalog = $catalog; TimeoutSeconds = 5 }
        @($results | ForEach-Object Verdict) | Should -Be @('no-audio', 'alive')
        $results[1].Category | Should -Be 'Test'
    }

    It 'warns about a title that is not in the catalogue' {
        $results = & (Join-Path $scripts 'Test-StationStreams.ps1') -Catalog $catalog -Title 'Radio Alpha', 'Radio Nowhere' -WarningVariable warned 6>$null 3>$null
        @($results).Count | Should -Be 1
        "$warned" | Should -Match 'radio nowhere'
    }

    It 'stops without a catalogue' {
        { & (Join-Path $scripts 'Test-StationStreams.ps1') -Catalog (Join-Path $work 'none.json') } | Should -Throw '*not found*'
    }

    It 'stops without curl' {
        Mock Get-Command { $null } -ParameterFilter { "$Name" -match '^curl' }
        { & (Join-Path $scripts 'Test-StationStreams.ps1') -Catalog $catalog 6>$null } | Should -Throw '*curl is needed*'
    }

    It 'probes the real catalogue by default' {
        $results = & (Join-Path $scripts 'Test-StationStreams.ps1') -Title 'Nowhere At All' 6>$null 3>$null
        $results | Should -BeNullOrEmpty
    }
}

Describe 'The logo refresh (Update-StationLogos.ps1)' {
    BeforeAll {
        $script:catalog = Join-Path $work 'logos.json'
        $script:logos = Join-Path $work 'RadioLogos'
        New-Item -ItemType Directory -Path $logos | Out-Null
        Copy-Item (Join-Path $images 'blue.png') (Join-Path $logos 'has-logo.png')
        Copy-Item (Join-Path $images 'blue.png') (Join-Path $logos 'radio-slug-clash.png')
        $script:before = Write-TestCatalog $catalog @(
            @{ Title = 'Radio Has Logo'; Url = "$base/stream/has"; ImageUrl = 'has-logo.png' }
            @{ Title = 'Radio Other'; Url = "$base/stream/other"; ImageUrl = 'radio-slug-clash.png' }
            @{ Title = 'Radio Fav'; Url = "$base/stream/fav" }
            @{ Title = 'Radio Home'; Url = "$base/stream/home"; ImageUrl = 'missing-file.png' }
            @{ Title = 'Radio Bravo'; Url = "$base/stream/bravo" }
            @{ Title = 'Radio Page'; Url = "$base/stream/page" }
            @{ Title = 'Radio Weak'; Url = 'http://localhost:1/weak' }
            @{ Title = 'Radio Placeholder A'; Url = "$base/stream/placeholder-a" }
            @{ Title = 'Radio Placeholder B'; Url = "$base/stream/placeholder-b" }
            @{ Title = 'Radio Nothing'; Url = "$base/stream/nothing" }
            @{ Title = 'Radio Slug Clash'; Url = "$base/stream/slug" }
        )
        $script:report = Join-Path $work 'logos.md'
        $arguments = @{ Catalog = $catalog; LogoFolder = $logos; ReportPath = $report; MyRadioOnlineUrl = $base; RadioBrowserUrl = $base }
        $script:results = Invoke-Quiet 'Update-StationLogos.ps1' ($arguments + @{ Python = $python })
        $script:after = Read-TestCatalog $catalog
        $script:byTitle = @{}
        foreach ($result in $results) { $byTitle[$result.Title] = $result }
        $script:reportText = Get-Content $report -Raw
    }

    It 'looks only at the stations without a usable logo' {
        $byTitle.Keys | Should -Not -Contain 'Radio Has Logo'
        $byTitle.Keys | Should -Not -Contain 'Radio Other'
        $byTitle.Count | Should -Be 9
    }

    It 'adds the first good strong logo: a favicon, a homepage icon, a by-name entry, the station''s page' {
        $byTitle['Radio Fav'].File | Should -Be 'radio-fav.png'
        $byTitle['Radio Home'].File | Should -Be 'radio-home.png'
        $byTitle['Radio Home'].Source | Should -Be 'homepage icon (127.0.0.1)'
        $byTitle['Radio Bravo'].Source | Should -Be 'radio-browser.info favicon (Radio Bravo)'
        $byTitle['Radio Page'].Source | Should -Be '127.0.0.1/radio-page'
        $byTitle['Radio Slug Clash'].File | Should -Be 'radio-slug-clash-2.png' -Because 'an existing file is never replaced'
        foreach ($title in 'Radio Fav', 'Radio Home', 'Radio Bravo', 'Radio Page', 'Radio Slug Clash') {
            $after[$title].ImageUrl | Should -Be $byTitle[$title].File
            Test-Path (Join-Path $logos $byTitle[$title].File) | Should -BeTrue
        }
    }

    It 'says why the candidates before it were not taken' {
        $byTitle['Radio Home'].Reasons | Should -Match 'not downloaded'
        $byTitle['Radio Home'].Reasons | Should -Match 'too small'
        $byTitle['Radio Home'].Reasons | Should -Match 'not an image'
    }

    It 'only suggests a logo found by the name, and gives a shared image to nobody' {
        $byTitle['Radio Weak'].File | Should -BeNullOrEmpty
        $byTitle['Radio Weak'].Suggested | Should -Be "$base/logo/orange.png"
        $after['Radio Weak'].ImageUrl | Should -BeNullOrEmpty
        $byTitle['Radio Placeholder A'].File | Should -BeNullOrEmpty
        $byTitle['Radio Placeholder B'].Reasons | Should -Match 'placeholder'
        $byTitle['Radio Nothing'].Tried | Should -Be 0
    }

    It 'reports the logos added, suggested and not found' {
        $reportText | Should -Match '9 station\(s\) without a logo; 5 logo\(s\) added\.'
        $reportText | Should -Match ([regex]::Escape('<img src="../../RadioLogos/radio-fav.png" width="64" alt="Radio Fav">'))
        $reportText | Should -Match '## Suggested logos'
        $reportText | Should -Match '## No logo found'
    }

    It 'changes nothing under -WhatIf, and finds nothing to do when every station has a logo' {
        $copy = Join-Path $work 'logos-copy.json'
        Copy-Item $catalog $copy
        $bytes = [IO.File]::ReadAllBytes($copy)
        $results = Invoke-Quiet 'Update-StationLogos.ps1' @{ Catalog = $copy; LogoFolder = $logos; Title = 'Radio Weak'; WhatIf = $true; MyRadioOnlineUrl = $base; RadioBrowserUrl = $base }
        $results.Suggested | Should -Be "$base/logo/orange.png"
        [IO.File]::ReadAllBytes($copy) | Should -Be $bytes
        $results = Invoke-Quiet 'Update-StationLogos.ps1' @{ Catalog = $copy; LogoFolder = $logos; Title = 'Radio Fav'; Python = $python }
        $results | Should -BeNullOrEmpty
    }

    It 'keeps CRLF line endings when it adds an ImageUrl line (a Windows checkout)' {
        $crlf = Join-Path $work 'crlf.json'
        $folder = New-Item -ItemType Directory -Path (Join-Path $work 'crlf-logos')
        Write-TestCatalog $crlf @(@{ Title = 'Radio Fav'; Url = "$base/stream/fav" }) | Out-Null
        $text = [IO.File]::ReadAllText($crlf) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText($crlf, $text, [Text.UTF8Encoding]::new($true))
        $results = Invoke-Quiet 'Update-StationLogos.ps1' @{ Catalog = $crlf; LogoFolder = $folder.FullName; Python = $python; MyRadioOnlineUrl = $base; RadioBrowserUrl = $base }
        $results.File | Should -Be 'radio-fav.png'
        $written = [IO.File]::ReadAllText($crlf)
        $written | Should -Match '"ImageUrl": "radio-fav.png"'
        ($written -replace "`r`n", '') | Should -Not -Match "`n" -Because 'every line still ends in CRLF'
    }

    It 'stops without Pillow, and when an ImageUrl cannot be written' {
        # pwsh stands in for a Python without Pillow: "-c 'import PIL'" fails there too.
        { Invoke-Quiet 'Update-StationLogos.ps1' @{ Catalog = $catalog; LogoFolder = $logos; Python = 'pwsh' } } | Should -Throw '*Pillow*'
        $odd = Join-Path $work 'odd-logos.json'
        [IO.File]::WriteAllText($odd, "[{`"Name`": `"Test`", `"List`": [{`"Url`": `"$base/stream/fav`", `"GUID`": `"$([Guid]::NewGuid())`", `"Title`": `"Radio Fav`"}]}]")
        { Invoke-Quiet 'Update-StationLogos.ps1' @{ Catalog = $odd; LogoFolder = $logos; Python = $python; MyRadioOnlineUrl = $base; RadioBrowserUrl = $base } } | Should -Throw '*Could not write the ImageUrl*'
    }
}

Describe 'Publishing the refresh (Publish-Refresh.ps1: the release note, the pull request, the issue)' {
    BeforeAll {
        $script:fakeGh = Join-Path $PSScriptRoot 'e2e/fake-gh.ps1'
        $script:repo = ' --repo ventura8/RoRadioResources'
        $script:urlReport = Join-Path $work 'publish-urls.md'
        $script:logoReport = Join-Path $work 'publish-logos.md'
        Set-Content -Path $urlReport -Encoding utf8 -Value @(
            'Probed 3 stations; 2 failed twice; 1 fixed.', '', '## Fixed', '', '| Station |', '| :--- |', '| Radio Beta |', '',
            '## Unresolved (url kept; the owner decides)', '', '| Station |', '| :--- |', '| Radio Iota |')
        Set-Content -Path $logoReport -Encoding utf8 -Value @(
            '1 station(s) without a logo; 1 logo(s) added.', '', '## Logos added', '',
            '| Logo |', '| :---: |', '| <img src="../../RadioLogos/radio-fav.png" width="64" alt="Radio Fav"> |')

        # A checkout of the list and the remote it pushes to.
        function Initialize-Checkout([string]$Name) {
            $folder = Join-Path $work $Name
            $remote = Join-Path $work "$Name-remote.git"
            git init -q --bare -b master $remote
            git init -q -b master $folder
            Copy-Item (Join-Path $work 'urls.json') (Join-Path $folder 'RadioStationsData.json')
            New-Item -ItemType Directory -Path (Join-Path $folder 'RadioLogos') | Out-Null
            Copy-Item (Join-Path $images 'blue.png') (Join-Path $folder 'RadioLogos/radio-fav.png')
            git -C $folder add -A
            git -C $folder -c user.name=test -c user.email=test@example.com commit -q -m 'start'
            git -C $folder remote add origin $remote
            git -C $folder push -q origin master 2>$null
            Add-Content -Path (Join-Path $folder 'RadioStationsData.json') -Value ' '
            [pscustomobject]@{ Folder = $folder; Remote = $remote; Temp = (New-Item -ItemType Directory -Path (Join-Path $work "$Name-temp")).FullName; Summary = Join-Path $work "$Name-summary.md" }
        }

        function Invoke-Publish([object]$Checkout, [hashtable]$Arguments) {
            $env:FAKE_GH_LOG = Join-Path $Checkout.Temp 'gh.log'
            $common = @{
                UrlReport = $urlReport; LogoReport = $logoReport; Date = '2026-11-16'; RunUrl = 'https://github.com/ventura8/RoRadioResources/actions/runs/1'
                Repository = 'ventura8/RoRadioResources'; RepositoryPath = $Checkout.Folder; Remote = $Checkout.Remote
                SummaryPath = $Checkout.Summary; TempFolder = $Checkout.Temp; Gh = $fakeGh; RetryDelaySeconds = 0
            }
            foreach ($name in $Arguments.Keys) { $common[$name] = $Arguments[$name] }
            & (Join-Path $scripts 'Publish-Refresh.ps1') @common 6>$null
            @(Get-Content $env:FAKE_GH_LOG)
        }
    }

    AfterEach {
        foreach ($name in 'FAKE_GH_LOG', 'FAKE_GH_PR_STATE', 'FAKE_GH_ISSUES', 'FAKE_GH_API_EXIT', 'FAKE_GH_FAIL', 'FAKE_GH_CHECKS', 'FAKE_GH_AUTH_EXIT', 'FAKE_GH_FLAKY') { Set-Item "env:$name" $null }
    }

    It 'commits the list, the logos and the note, pushes, opens the pull request, merges it and asks Pages to rebuild' {
        $checkout = Initialize-Checkout 'merge'
        $log = Invoke-Publish $checkout @{ UrlCount = 1; LogoCount = 1; Merge = $true }
        $log | Should -Contain ('pr create --base master --head automation/station-refresh --title Refresh 1 station url(s), 1 logo(s), 0 station(s) retired or restored (2026-11-16) --body-file ' + (Join-Path $checkout.Temp 'refresh-body.md') + $repo)
        $log | Should -Contain "pr merge automation/station-refresh --squash --delete-branch$repo"
        $log | Should -Contain 'api -X POST repos/ventura8/RoRadioResources/pages/builds --silent'
        $files = @(git --git-dir $checkout.Remote ls-tree -r --name-only automation/station-refresh)
        $files | Should -Contain 'docs/releases/2026-11-16-refresh.md'
        git --git-dir $checkout.Remote log -1 --format=%s automation/station-refresh | Should -Be 'Refresh 1 station url(s), 1 logo(s), 0 station(s) retired or restored (2026-11-16)'
        $sha = git --git-dir $checkout.Remote rev-parse automation/station-refresh
        $body = Get-Content (Join-Path $checkout.Temp 'refresh-body.md') -Raw
        $body | Should -Match ([regex]::Escape("https://raw.githubusercontent.com/ventura8/RoRadioResources/$sha/RadioLogos/radio-fav.png"))
        $note = Get-Content (Join-Path $checkout.Folder 'docs/releases/2026-11-16-refresh.md') -Raw
        $note | Should -Match ([regex]::Escape('../../RadioLogos/radio-fav.png'))
        $note | Should -Match '### Unresolved'
        Get-Content $checkout.Summary -Raw | Should -Match 'Merged\.'
    }

    It 'opens the issue of the stations it could not fix, with what needs a human only' {
        $checkout = Initialize-Checkout 'issue'
        $log = Invoke-Publish $checkout @{ UrlCount = 0; LogoCount = 0 }
        $log | Should -Contain ('issue create --title Stations the weekly refresh could not fix --body-file ' + (Join-Path $checkout.Temp 'refresh-issue.md') + $repo)
        $log | Should -Contain "issue list --state open --limit 100 --json number,title$repo" -Because 'every gh call names the repository'
        $issue = Get-Content (Join-Path $checkout.Temp 'refresh-issue.md') -Raw
        $issue | Should -Match '## Unresolved'
        $issue | Should -Match 'Radio Iota'
        $issue | Should -Not -Match 'Radio Beta' -Because 'what was fixed needs nobody'
        $log | Should -Not -Contain 'pr create' -Because 'nothing changed'
        Get-Content $checkout.Summary -Raw | Should -Match 'Nothing changed\.'
    }

    It 'updates the open issue and the open pull request, and leaves a large change for a human' {
        $checkout = Initialize-Checkout 'large'
        $env:FAKE_GH_ISSUES = '[{"number": 41, "title": "Stations the weekly refresh could not fix"}, {"number": 3, "title": "Other"}]'
        $env:FAKE_GH_PR_STATE = 'OPEN'
        $log = Invoke-Publish $checkout @{ UrlCount = 16; LogoCount = 0; Merge = $true }
        $log | Should -Contain ('issue edit 41 --body-file ' + (Join-Path $checkout.Temp 'refresh-issue.md') + $repo)
        ($log | Where-Object { $_ -like 'pr edit automation/station-refresh *' }) | Should -Not -BeNullOrEmpty
        $log | Should -Contain "pr merge automation/station-refresh --disable-auto$repo" -Because 'an earlier run may have turned auto-merge on'
        ($log | Where-Object { $_ -like 'pr comment automation/station-refresh --body 16 urls and 0 logos changed*' }) | Should -Not -BeNullOrEmpty
        $log | Should -Not -Contain "pr merge automation/station-refresh --squash --delete-branch$repo"
    }

    It 'turns on auto-merge instead of merging, so that master''s required checks decide' {
        $checkout = Initialize-Checkout 'auto'
        $log = Invoke-Publish $checkout @{ UrlCount = 1; LogoCount = 0; Merge = $true; AutoMerge = $true }
        $log | Should -Contain "pr merge automation/station-refresh --auto --squash --delete-branch$repo"
        ($log | Where-Object { $_ -like 'api -X *' }) | Should -BeNullOrEmpty -Because 'Pages rebuilds from the merge itself'
        Get-Content $checkout.Summary -Raw | Should -Match 'Auto-merge is on'
    }

    It 'leaves the pull request open when no merge is asked, and closes the issue when nothing is left' {
        $checkout = Initialize-Checkout 'held'
        Set-Content -Path $urlReport -Encoding utf8 -Value @('Probed 3 stations; 1 failed twice; 1 fixed.', '', '## Fixed', '', '| Station |', '| :--- |', '| Radio Beta |')
        $env:FAKE_GH_ISSUES = '[{"number": 41, "title": "Stations the weekly refresh could not fix"}]'
        $log = Invoke-Publish $checkout @{ UrlCount = 1; LogoCount = 0; RunUrl = ''; LogoReport = (Join-Path $work 'no-such-report.md') }
        $log | Should -Contain "issue close 41 --comment The refresh of 2026-11-16 left nothing to fix.$repo"
        $log | Should -Not -Contain "pr merge automation/station-refresh --squash --delete-branch$repo"
        Get-Content $checkout.Summary -Raw | Should -Match 'Merge not requested'
    }

    It 'warns when Pages cannot be asked to rebuild, and stops on a failed command' {
        $checkout = Initialize-Checkout 'failures'
        Set-Content -Path $urlReport -Encoding utf8 -Value 'Probed 3 stations; 0 failed twice; 0 fixed.'
        $env:FAKE_GH_API_EXIT = '1'
        $log = Invoke-Publish $checkout @{ UrlCount = 1; LogoCount = 0; Merge = $true; WarningAction = 'SilentlyContinue' }
        Get-Content $checkout.Summary -Raw | Should -Match 'Could not request a Pages build'
        ($log | Where-Object { $_ -like 'issue *' -and $_ -notlike 'issue list *' }) | Should -BeNullOrEmpty -Because 'there is nothing to report'
        Add-Content -Path (Join-Path $checkout.Folder 'RadioStationsData.json') -Value ' '
        $env:FAKE_GH_FAIL = 'pr merge'
        { Invoke-Publish $checkout @{ UrlCount = 1; LogoCount = 0; Merge = $true } } | Should -Throw '*fake-gh.ps1 pr merge failed*'
    }

    It 'pushes to github.com with the token when no remote is given' {
        $checkout = Initialize-Checkout 'token'
        $env:GH_TOKEN = 'test-token'
        try {
            $common = @{ UrlReport = $urlReport; RepositoryPath = $checkout.Folder; Repository = 'ventura8/no-such-repository'; Gh = $fakeGh; UrlCount = 1; SummaryPath = ''; RetryDelaySeconds = 0 }
            $env:FAKE_GH_LOG = Join-Path $checkout.Temp 'gh.log'
            # No network: git refuses https before it connects (tried three times, like a network that is down).
            $env:GIT_ALLOW_PROTOCOL = 'file'
            { & (Join-Path $scripts 'Publish-Refresh.ps1') @common 6>$null 2>$null 3>$null } | Should -Throw 'git fetch -q failed (exit *'
        } finally {
            $env:GH_TOKEN = $null
            $env:GIT_ALLOW_PROTOCOL = $null
        }
    }

    It 'closes a refresh pull request an earlier run left open when this run changes nothing' {
        $checkout = Initialize-Checkout 'stale'
        Set-Content -Path $urlReport -Encoding utf8 -Value 'Probed 3 stations; 0 failed twice; 0 fixed.'
        $env:FAKE_GH_PR_STATE = 'OPEN'
        $log = Invoke-Publish $checkout @{ UrlCount = 0; LogoCount = 0; StationCount = 0 }
        ($log | Where-Object { $_ -like 'pr close automation/station-refresh --delete-branch --comment *' }) | Should -Not -BeNullOrEmpty
        Get-Content $checkout.Summary -Raw | Should -Match 'Closed the refresh pull request'
    }

    It 'reports its own pull request failing CI in the issue, and pushes the new run to the same pull request' {
        $checkout = Initialize-Checkout 'red'
        $env:FAKE_GH_PR_STATE = 'OPEN'
        $env:FAKE_GH_CHECKS = '[{"name": "Tests", "bucket": "fail"}, {"name": "Lint", "bucket": "pass"}]'
        $log = Invoke-Publish $checkout @{ UrlCount = 1; LogoCount = 0; Merge = $true; AutoMerge = $true }
        Get-Content (Join-Path $checkout.Temp 'refresh-issue.md') -Raw | Should -Match "own pull request fails CI[\s\S]*Tests"
        ($log | Where-Object { $_ -like 'pr create *' }) | Should -BeNullOrEmpty -Because 'no second pull request piles up'
        ($log | Where-Object { $_ -like 'pr edit automation/station-refresh *' }) | Should -Not -BeNullOrEmpty
    }

    It 'stops with the reason when the token cannot read the repository' {
        $checkout = Initialize-Checkout 'expired'
        $env:FAKE_GH_AUTH_EXIT = '1'
        { Invoke-Publish $checkout @{ UrlCount = 1 } } | Should -Throw '*cannot read ventura8/RoRadioResources*REFRESH_TOKEN*'
    }

    It 'tries a gh command again when the API fails once' {
        $checkout = Initialize-Checkout 'flaky'
        $env:FAKE_GH_FLAKY = 'issue list'
        $log = Invoke-Publish $checkout @{ UrlCount = 0; WarningAction = 'SilentlyContinue' }
        @($log | Where-Object { $_ -like 'issue list *' }).Count | Should -Be 2
    }

    It 'puts its commit on top of a master that moved, and says so when master changed the same lines' {
        $checkout = Initialize-Checkout 'moved'
        git -C $checkout.Folder push -q origin master
        $other = Join-Path $work 'moved-other'
        git clone -q $checkout.Remote $other
        Set-Content -Path (Join-Path $other 'README.md') -Value 'moved'
        git -C $other add -A
        git -C $other -c user.name=test -c user.email=test@example.com commit -q -m 'master moved'
        git -C $other push -q origin master
        Invoke-Publish $checkout @{ UrlCount = 1 } | Out-Null
        git --git-dir $checkout.Remote merge-base --is-ancestor master automation/station-refresh
        $LASTEXITCODE | Should -Be 0 -Because 'the refresh commit sits on the newest master'

        $conflict = Initialize-Checkout 'conflict'
        git -C $conflict.Folder stash -q
        git -C $conflict.Folder push -q origin master
        $clone = Join-Path $work 'conflict-other'
        git clone -q $conflict.Remote $clone
        Add-Content -Path (Join-Path $clone 'RadioStationsData.json') -Value 'other'
        git -C $clone -c user.name=test -c user.email=test@example.com commit -q -am 'same lines'
        git -C $clone push -q origin master
        git -C $conflict.Folder stash pop -q
        Invoke-Publish $conflict @{ UrlCount = 1 } | Out-Null
        Get-Content $conflict.Summary -Raw | Should -Match 'may need a rebase'
    }

    It 'commits RetiredStations.json, and puts the trend of the last runs in the issue' {
        $checkout = Initialize-Checkout 'trend'
        Set-Content -Path $urlReport -Encoding utf8 -Value @('Probed 3 stations; 1 failed twice; 0 fixed.', '', '## Retired (dead)', '', '| Station |', '| :--- |', '| Radio Iota |')
        Set-Content -Path (Join-Path $checkout.Folder 'RetiredStations.json') -Value '[]'
        $metrics = Join-Path $checkout.Temp 'runs.jsonl'
        Set-Content -Path $metrics -Encoding utf8 -Value @(
            '{"Date":"2026-11-09","Probed":229,"Failing":9,"Fixed":1,"Unresolved":7,"Retired":0,"Restored":0,"Retries":2,"Stages":{"urls":600},"Sources":{"myradioonline":{"Queries":9,"Hits":1,"Milliseconds":900}}}'
            'not json'
            '{"Date":"2026-11-16","Probed":229,"Failing":8,"Fixed":0,"Unresolved":7,"Retired":1,"Restored":0,"Retries":0,"Stages":{"urls":540},"Sources":{"myradioonline":{"Queries":8,"Hits":0,"Milliseconds":800}}}')
        Invoke-Publish $checkout @{ StationCount = 1; MetricsPath = $metrics } | Out-Null
        @(git --git-dir $checkout.Remote ls-tree -r --name-only automation/station-refresh) | Should -Contain 'RetiredStations.json'
        $issue = Get-Content (Join-Path $checkout.Temp 'refresh-issue.md') -Raw
        $issue | Should -Match '## Trend'
        $issue | Should -Match '\| 2026-11-16 \| 229 \| 8 \| 0 \| 7 \| 1 \| 0 \| 0 \| 9 \|'
        $issue | Should -Match '\| myradioonline \| 17 \| 1 \| 6% \| 100 \|'
    }
}

Describe 'The release note (New-RefreshNote.ps1)' {
    It 'writes a note without a run link or a logo section into the current folder' {
        Push-Location $work
        try {
            & (Join-Path $scripts 'New-RefreshNote.ps1') -UrlReport (Join-Path $work 'urls.md') -Path 'note.md' -Date '2026-11-16'
            $note = Get-Content (Join-Path $work 'note.md') -Raw
            $note | Should -Match '^# Station refresh, 2026-11-16'
            $note | Should -Match 'What the weekly refresh changed'
            $note | Should -Not -Match '## Logos'
            $note | Should -Match '### Fixed'
        } finally {
            Pop-Location
        }
    }
}
