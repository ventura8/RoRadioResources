#Requires -Version 7.0
# The stream probe (scripts/lib/Probe.ps1) and the checked downloads (scripts/lib/Net.ps1), against the fake station
# server of tests/e2e on 127.0.0.1: every kind of answer a station gives, called in this runspace so that the
# coverage of scripts/ci/Invoke-Tests.ps1 sees them (Test-StationStreams.ps1 runs the probe in parallel runspaces).

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'scripts/lib/Probe.ps1')
    . (Join-Path $root 'scripts/lib/Names.ps1')
    . (Join-Path $PSScriptRoot 'e2e/FakeServer.ps1')
    $hls = 'application/vnd.apple.mpegurl'
    $script:server = Open-FakeStationServer @(
        @{ path = '/audio'; type = 'audio/mpeg'; audio = 8192 }
        @{ path = '/untyped'; type = ''; audio = 1024 }
        @{ path = '/html'; body = '<html><body>Not a stream</body></html>' }
        @{ path = '/empty'; type = 'audio/mpeg' }
        @{ path = '/redirect'; status = 302; headers = @{ Location = '{base}/audio' } }
        @{ path = '/redirect-nowhere'; status = 302 }
        @{ path = '/loop'; status = 302; headers = @{ Location = '{base}/loop' } }
        @{ path = '/icy'; icy = (Join-Line "`r`n" 'ICY 200 OK' 'content-type: audio/aacp' 'icy-name: Radio Icy' '' ''); audio = 2048 }
        @{ path = '/icy-untyped'; icy = (Join-Line "`r`n" 'ICY 200 OK' 'icy-name: Radio Icy' '' ''); audio = 2048 }
        @{ path = '/icy-cut'; icy = (Join-Line "`r`n" 'ICY 200 OK' 'icy-name: Radio Icy') }
        @{ path = '/icy-error'; icy = (Join-Line "`r`n" 'ICY 404 Resource Not Found' '' '') }
        @{ path = '/not-icy'; icy = (Join-Line "`r`n" 'SOURCE OK' '' '') }
        @{ path = '/silent'; icy = '' }
        @{ path = '/hls/master.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' '#EXT-X-STREAM-INF:BANDWIDTH=64000' 'variant.m3u8' '') }
        @{ path = '/hls/variant.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' '#EXTINF:10,' 'segment.aac' '') }
        @{ path = '/hls/segment.aac'; type = 'audio/aac'; audio = 4096 }
        @{ path = '/hls/empty.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' '') }
        @{ path = '/hls/deep.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' 'deeper.m3u8' '') }
        @{ path = '/hls/deeper.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' 'deepest.m3u8' '') }
        @{ path = '/hls/deepest.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' 'segment.aac' '') }
        @{ path = '/hls/gone.m3u8'; type = $hls; body = (Join-Line "`n" '#EXTM3U' 'missing.m3u8' '') }
        @{ path = '/live'; type = 'application/x-mpegurl'; body = (Join-Line "`n" '#EXTM3U' 'hls/segment.aac' '') }
        @{ path = '/page.json'; type = 'application/json'; body = '{"ok": true}' }
        @{ path = '/broken.json'; type = 'application/json'; body = '{not json' }
        @{ path = '/large'; type = 'application/octet-stream'; audio = 300000 }
    )
    $script:base = $server.Base

    function Get-Verdict([string]$Url) {
        Get-StreamVerdict ([pscustomobject]@{ Title = 'Test'; Url = $Url; Guid = 'g'; Category = 'c' }) 5
    }
}

AfterAll {
    Close-FakeStationServer $server
}

Describe 'Stream verdicts' {
    It 'calls a stream with audio bytes alive' {
        $verdict = Get-Verdict "$base/audio"
        $verdict.Verdict | Should -Be 'alive'
        $verdict.ContentType | Should -Be 'audio/mpeg'
        $verdict.Checked | Should -Be "$base/audio"
        $verdict.Guid | Should -Be 'g'
    }

    It 'calls bytes without a content type alive' {
        (Get-Verdict "$base/untyped").Verdict | Should -Be 'alive'
    }

    It 'follows a redirect to the stream' {
        (Get-Verdict "$base/redirect").Verdict | Should -Be 'alive'
    }

    It 'calls a web page no-audio' {
        (Get-Verdict "$base/html").Verdict | Should -Be 'no-audio'
    }

    It 'reports an HTTP error with its status' {
        (Get-Verdict "$base/nothing-here").Verdict | Should -Be 'http-404'
    }

    It 'calls a redirect without a destination an HTTP answer, not a stream' {
        (Get-Verdict "$base/redirect-nowhere").Verdict | Should -Be 'http-302'
    }

    It 'calls an empty answer, an endless redirect, a refused connection and a server that sends nothing dead' {
        (Get-Verdict "$base/empty").Verdict | Should -Be 'dead'
        (Get-Verdict "$base/loop").Verdict | Should -Be 'dead'
        (Get-Verdict 'http://127.0.0.1:1/stream').Verdict | Should -Be 'dead'
        (Get-Verdict "$base/silent").Verdict | Should -Be 'dead'
    }

    It 'never requests a private address: it counts as dead' {
        (Get-Verdict 'http://10.0.0.1/stream').Verdict | Should -Be 'dead'
    }

    It 'reads an old Shoutcast server''s ICY answer, with its content type or MP3 by default' {
        $icy = Get-Verdict "$base/icy"
        $icy.Verdict | Should -Be 'alive'
        $icy.ContentType | Should -Be 'audio/aacp'
        (Get-Verdict "$base/icy-untyped").ContentType | Should -Be 'audio/mpeg'
    }

    It 'calls an ICY answer without audio dead, and an ICY error an HTTP error' {
        (Get-Verdict "$base/icy-cut").Verdict | Should -Be 'dead'
        (Get-Verdict "$base/icy-error").Verdict | Should -Be 'http-404'
        (Get-Verdict "$base/not-icy").Verdict | Should -Be 'dead'
    }

    It 'follows an HLS playlist to its variant and its first segment' {
        $verdict = Get-Verdict "$base/hls/master.m3u8"
        $verdict.Verdict | Should -Be 'alive'
        $verdict.Checked | Should -Be "$base/hls/segment.aac"
    }

    It 'recognizes a playlist by its content type, without the .m3u8 name' {
        $verdict = Get-Verdict "$base/live"
        $verdict.Verdict | Should -Be 'alive'
        $verdict.Checked | Should -Be "$base/hls/segment.aac"
    }

    It 'calls a playlist that leads to no segment no-audio' {
        (Get-Verdict "$base/hls/empty.m3u8").Verdict | Should -Be 'no-audio'
        (Get-Verdict "$base/hls/deep.m3u8").Verdict | Should -Be 'no-audio'
        (Get-Verdict "$base/hls/gone.m3u8").Verdict | Should -Be 'http-404'
    }

    It 'gives up on a playlist that cannot be read' {
        $body = Get-Body "$base/nothing.m3u8" 5
        $body.Body | Should -BeExactly ''
        $body.Final | Should -Be "$base/nothing.m3u8"
    }
}

Describe 'Checked downloads' {
    BeforeEach {
        $script:file = Join-Path ([IO.Path]::GetTempPath()) "roradio-probe-test-$PID.bin"
    }

    AfterEach {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }

    It 'saves a file and returns the url that answered, after redirects' {
        Save-PublicFile "$base/redirect" $file | Should -Be "$base/audio"
        (Get-Item $file).Length | Should -Be 8192
    }

    It 'leaves no file after an HTTP error, a redirect loop, a file too large or a private address' {
        Save-PublicFile "$base/nothing" $file | Should -BeNullOrEmpty
        Save-PublicFile "$base/loop" $file | Should -BeNullOrEmpty
        Save-PublicFile "$base/large" $file -MaxBytes 1000 | Should -BeNullOrEmpty
        Save-PublicFile "$base/redirect-nowhere" $file | Should -BeNullOrEmpty
        Test-Path $file | Should -BeFalse
    }

    It 'reads json, and nothing from a page that is not json or not there' {
        (Get-OptionalJson "$base/page.json").ok | Should -BeTrue
        Get-OptionalJson "$base/broken.json" | Should -BeNullOrEmpty
        Get-OptionalJson "$base/nothing.json" | Should -BeNullOrEmpty
    }

    It 'reads a page, and notes one it could not read for the report' {
        $UnreadableSource.Clear()
        Get-Text "$base/html" | Should -Match 'Not a stream'
        Get-Text "$base/nothing" 3>$null | Should -BeExactly ''
        $UnreadableSource | Should -Be @("$base/nothing")
    }
}

Describe 'Loopback addresses' {
    It 'are open only while RORADIO_REFRESH_ALLOW_LOOPBACK is 1, and private networks never are' {
        Test-PrivateAddress ([Net.IPAddress]'127.0.0.1') | Should -BeFalse
        Test-PrivateAddress ([Net.IPAddress]'::1') | Should -BeFalse
        Test-PrivateAddress ([Net.IPAddress]'10.0.0.1') | Should -BeTrue
        Test-PrivateAddress ([Net.IPAddress]'169.254.169.254') | Should -BeTrue
        $env:RORADIO_REFRESH_ALLOW_LOOPBACK = $null
        try {
            Test-PrivateAddress ([Net.IPAddress]'127.0.0.1') | Should -BeTrue
        } finally {
            $env:RORADIO_REFRESH_ALLOW_LOOPBACK = '1'
        }
    }
}

Describe 'Pinned host names' {
    It 'pins a name to its IPv4 address first' {
        Mock Resolve-HostAddress { @([Net.IPAddress]'2001:db8::1', [Net.IPAddress]'93.184.216.34') }
        $pin = Get-PinnedTarget 'https://stream.example.com/live'
        $pin | Should -Be @('--resolve', 'stream.example.com:443:93.184.216.34')
    }

    It 'pins a name with only an IPv6 address in brackets' {
        Mock Resolve-HostAddress { @([Net.IPAddress]'2001:db8::1') }
        $pin = Get-PinnedTarget 'http://stream.example.com:8000/live'
        $pin | Should -Be @('--resolve', 'stream.example.com:8000:[2001:db8::1]')
    }

    It 'refuses a name that does not resolve, resolves to nothing, or resolves to a private address' {
        Mock Resolve-HostAddress { throw 'No such host is known.' }
        Get-PinnedTarget 'http://nowhere.example.com/' | Should -BeNullOrEmpty
        Mock Resolve-HostAddress { @() }
        Get-PinnedTarget 'http://nowhere.example.com/' | Should -BeNullOrEmpty
        Mock Resolve-HostAddress { @([Net.IPAddress]'93.184.216.34', [Net.IPAddress]'192.168.1.1') }
        Get-PinnedTarget 'http://rebind.example.com/' | Should -BeNullOrEmpty
    }

    It 'resolves a real name' {
        @(Resolve-HostAddress 'localhost').Count | Should -BeGreaterThan 0
    }

    It 'pins nothing for, and reads no path from, a malformed url' {
        Get-PinnedTarget 'http://[broken' | Should -BeNullOrEmpty
        Get-UrlPath 'http://[broken' | Should -BeExactly ''
    }
}
