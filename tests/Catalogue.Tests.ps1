#Requires -Version 7.0
# The rules every RoRadio app relies on, checked on each pull request and before the weekly refresh commits
# (Invoke-Pester; scripts/ci/Invoke-Tests.ps1). RoRadio's own RadioRepoTest checks the same list again.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $catalogPath = Join-Path $root 'RadioStationsData.json'
    $logoFolder = Join-Path $root 'RadioLogos'
    # Script scope: the tests below read them (Pester runs BeforeAll and each It in that scope).
    $script:bytes = [IO.File]::ReadAllBytes($catalogPath)
    $script:categories = @([Text.UTF8Encoding]::new($false).GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json)
    $script:stations = @($categories | ForEach-Object { $_.List } | ForEach-Object { $_ })
    $script:logoFolder = $logoFolder
    $script:logoNames = @(Get-ChildItem $logoFolder -File | ForEach-Object { $_.Name })

    function Get-Duplicate([string[]]$Values) {
        @($Values | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object { $_.Name })
    }
}

Describe 'RadioStationsData.json' {
    It 'is UTF-8 with a byte order mark (its own format: a url fix stays a one-line diff)' {
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'has more than 200 stations (RoRadio falls back to its bundled list below that)' {
        $stations.Count | Should -BeGreaterThan 200
    }

    It 'names every category and gives it stations' {
        @($categories | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) -or @($_.List).Count -eq 0 }) | Should -BeNullOrEmpty
        Get-Duplicate @($categories | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'gives every station a GUID that is a GUID' {
        $bad = @($stations | Where-Object { -not [Guid]::TryParse($_.GUID, [ref][Guid]::Empty) } | ForEach-Object { "$($_.Title): '$($_.GUID)'" })
        $bad | Should -BeNullOrEmpty
    }

    It 'never gives two stations the same GUID (favorites and the last station refer to it)' {
        Get-Duplicate @($stations | ForEach-Object { $_.GUID.ToLowerInvariant() }) | Should -BeNullOrEmpty
    }

    It 'gives every station a title and an absolute http(s) url with a host and a valid port' {
        # Parsed, not pattern-matched: "http://stream.example:abc/live" starts like a url and is none (CodeRabbit,
        # RoRadioResources#2).
        $bad = @($stations | Where-Object {
            $uri = $null
            [string]::IsNullOrWhiteSpace($_.Title) -or $_.Url -match '\s' -or
                -not [Uri]::TryCreate($_.Url, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin 'http', 'https' -or [string]::IsNullOrEmpty($uri.Host)
        } | ForEach-Object { "$($_.GUID): '$($_.Title)' '$($_.Url)'" })
        $bad | Should -BeNullOrEmpty
    }

    It 'refuses what only looks like a url (the check above, on known bad values)' {
        foreach ($url in 'http://stream.example:abc/live', 'ftp://stream.example/live', 'stream.example/live', 'http:///live') {
            $uri = $null
            $valid = [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in 'http', 'https' -and $uri.Host
            $valid | Should -BeFalse -Because "'$url' is not a stream url"
        }
    }

    It 'never gives two stations the same title (the apps and their UI tests find a station by it)' {
        Get-Duplicate @($stations | ForEach-Object { $_.Title.Trim().ToLowerInvariant() }) | Should -BeNullOrEmpty
    }

    It 'never gives two stations the same url' {
        Get-Duplicate @($stations | ForEach-Object { $_.Url }) | Should -BeNullOrEmpty
    }

    It 'has no url that contains another station''s url (a "stream" and "stream/" copy, or one mount under another)' {
        $urls = @($stations | ForEach-Object { $_.Url })
        $contained = @(foreach ($outer in $urls) {
            foreach ($inner in $urls) {
                if ($outer -ne $inner -and $outer.Contains($inner)) { "$inner is inside $outer" }
            }
        })
        $contained | Should -BeNullOrEmpty
    }

    It 'has only the fields the apps read' {
        $known = 'GUID', 'Title', 'Url', 'ImageUrl', 'Description'
        $unknown = @($stations | ForEach-Object { $_.PSObject.Properties.Name } | Where-Object { $known -notcontains $_ } | Select-Object -Unique)
        $unknown | Should -BeNullOrEmpty
    }
}

Describe 'RadioLogos' {
    It 'has the file every ImageUrl names, with the same case (GitHub Pages is case-sensitive)' {
        $missing = @($stations | Where-Object { $_.ImageUrl -and $logoNames -cnotcontains $_.ImageUrl } | ForEach-Object { "$($_.Title): $($_.ImageUrl)" })
        $missing | Should -BeNullOrEmpty
    }

    It 'has no ImageUrl that is empty or a path (a file name only)' {
        $bad = @($stations | Where-Object { $null -ne $_.ImageUrl -and ($_.ImageUrl -eq '' -or $_.ImageUrl -match '[/\\:]') } | ForEach-Object { "$($_.Title): '$($_.ImageUrl)'" })
        $bad | Should -BeNullOrEmpty
    }

    It 'keeps no file that no station uses' {
        $used = @($stations | ForEach-Object { $_.ImageUrl } | Where-Object { $_ })
        @($logoNames | Where-Object { $used -cnotcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'keeps each logo a PNG or JPEG of at most 200 KB (every app downloads the ones it does not bundle)' {
        $bad = @(Get-ChildItem $logoFolder -File | Where-Object {
            $head = [byte[]]::new(4)
            $stream = [IO.File]::OpenRead($_.FullName)
            try { $null = $stream.Read($head, 0, 4) } finally { $stream.Dispose() }
            $png = $head[0] -eq 0x89 -and $head[1] -eq 0x50 -and $head[2] -eq 0x4E -and $head[3] -eq 0x47
            $jpeg = $head[0] -eq 0xFF -and $head[1] -eq 0xD8
            $matchesName = ($png -and $_.Extension -eq '.png') -or ($jpeg -and $_.Extension -in '.jpg', '.jpeg')
            -not $matchesName -or $_.Length -gt 200KB
        } | ForEach-Object { "$($_.Name) ($($_.Length) bytes)" })
        $bad | Should -BeNullOrEmpty
    }
}
