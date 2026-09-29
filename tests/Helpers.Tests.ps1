#Requires -Version 7.0
# The shared helpers of the station scripts (scripts/lib), offline: no test here touches the network except the
# DNS lookup of a literal address, which needs none.

BeforeAll {
    $library = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/lib'
    . (Join-Path $library 'Net.ps1')
    . (Join-Path $library 'Names.ps1')
}

Describe 'Station names' {
    It 'compares titles without diacritics, case or surrounding spaces' {
        ConvertTo-PlainTitle '  Radio Timișoara ' | Should -BeExactly 'radio timisoara'
        ConvertTo-PlainTitle 'Radio Timişoara' | Should -BeExactly 'radio timisoara' -Because 'the cedilla and the comma below are the same letter'
    }

    It 'makes myradioonline.ro slugs' {
        ConvertTo-Slug 'Kolozsvári Rádió' | Should -BeExactly 'kolozsvari-radio'
        ConvertTo-Slug "Radio 90's Hits" | Should -BeExactly 'radio-90s-hits'
        ConvertTo-Slug "Radio 90$([char]0x2019)s" | Should -BeExactly 'radio-90s' -Because 'the typographic apostrophe goes too'
    }

    It 'finds the slugs a title can have on myradioonline.ro' {
        Get-MyRadioOnlineSlug 'Radio Zu' @('radio-zu', 'zu', 'kiss-fm') | Should -Be @('radio-zu', 'zu')
        Get-MyRadioOnlineSlug 'Kiss FM' @('radio-zu', 'radio-kiss-fm') | Should -Be @('radio-kiss-fm')
        Get-MyRadioOnlineSlug 'Magic FM' @('radio-zu') | Should -BeNullOrEmpty
    }

    It 'takes the whole name and its distinctive words as marks, not the generic ones' {
        Get-NameMark 'Radio Aquila Online' | Should -Be @('radioaquilaonline', 'aquila')
    }

    It 'finds a mark in a text, spaces and dashes ignored' {
        Test-NameMark @('aquila') 'https://stream.radio-aquila.ro/live' | Should -BeTrue
        Test-NameMark @('radioaquila') 'Radio Aquila - Live' | Should -BeTrue
        Test-NameMark @('aquila') 'Kiss FM' | Should -BeFalse
    }

    It 'reads hosts and paths, and nothing from a non-url' {
        Get-UrlHost 'https://Stream.Example.COM:8000/live' | Should -BeExactly 'stream.example.com'
        Get-UrlPath 'https://stream.example.com:8000/live.mp3' | Should -BeExactly '/live.mp3'
        Get-UrlHost 'not a url' | Should -BeExactly ''
    }
}

Describe 'Private addresses (never requested by the scripts)' {
    It 'flags <Address>' -ForEach @(
        @{ Address = '127.0.0.1' }, @{ Address = '10.1.2.3' }, @{ Address = '172.16.0.1' }, @{ Address = '172.31.255.255' },
        @{ Address = '192.168.1.1' }, @{ Address = '169.254.169.254' }, @{ Address = '100.64.0.1' }, @{ Address = '0.0.0.0' },
        @{ Address = '224.0.0.1' }, @{ Address = '::1' }, @{ Address = 'fe80::1' }, @{ Address = 'fd00::1' },
        @{ Address = '::ffff:10.0.0.1' }
    ) {
        Test-PrivateAddress ([Net.IPAddress]$Address) | Should -BeTrue
    }

    It 'lets <Address> through' -ForEach @(
        @{ Address = '8.8.8.8' }, @{ Address = '172.32.0.1' }, @{ Address = '100.128.0.1' }, @{ Address = '2001:4860:4860::8888' }
    ) {
        Test-PrivateAddress ([Net.IPAddress]$Address) | Should -BeFalse
    }

    It 'refuses private, metadata and non-web urls, and pins nothing for a public address literal' {
        Get-PinnedTarget 'http://127.0.0.1:8000/stream' | Should -BeNullOrEmpty
        Get-PinnedTarget 'http://169.254.169.254/latest/meta-data/' | Should -BeNullOrEmpty
        Get-PinnedTarget 'file:///etc/passwd' | Should -BeNullOrEmpty
        Get-PinnedTarget 'not a url' | Should -BeNullOrEmpty
        Test-PublicUrl 'http://10.0.0.1/' | Should -BeFalse
        $pin = Get-PinnedTarget 'http://8.8.8.8:8000/stream'
        $pin.Count | Should -Be 0 -Because 'an address literal is already the address that was checked'
        Test-PublicUrl 'http://8.8.8.8:8000/stream' | Should -BeTrue
    }

    It 'downloads nothing from a private address' {
        $file = Join-Path ([IO.Path]::GetTempPath()) "roradio-test-$PID.bin"
        Save-PublicFile 'http://127.0.0.1:9/logo.png' $file | Should -BeNullOrEmpty
        Test-Path $file | Should -BeFalse
    }
}
