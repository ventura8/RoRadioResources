# Starts and stops tests/e2e/fake_station_server.py for the Pester tests (dot-sourced). The scripts under test
# refuse loopback addresses unless RORADIO_REFRESH_ALLOW_LOOPBACK is 1 (scripts/lib/Net.ps1): Open-FakeStationServer
# sets it, Close-FakeStationServer clears it.

# The Python that runs the fake: RORADIO_TEST_PYTHON, else python on Windows and python3 elsewhere.
function Get-TestPython {
    @($env:RORADIO_TEST_PYTHON, ('python3', 'python')[[int][bool]$IsWindows]) | Where-Object { $_ } | Select-Object -First 1
}

# Serves $Routes (see the fake's docstring) and returns { Process, Base, RoutesPath }.
function Open-FakeStationServer([object[]]$Routes) {
    $routesPath = Join-Path ([IO.Path]::GetTempPath()) "roradio-fake-$([Guid]::NewGuid().ToString('n')).json"
    ConvertTo-Json -InputObject @($Routes) -Depth 10 | Set-Content -Path $routesPath -Encoding utf8
    $start = [Diagnostics.ProcessStartInfo]::new((Get-TestPython))
    $start.ArgumentList.Add((Join-Path $PSScriptRoot 'fake_station_server.py'))
    $start.ArgumentList.Add($routesPath)
    $start.RedirectStandardOutput = $true
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $port = $process.StandardOutput.ReadLine()
    if (-not $port) { throw 'The fake station server did not start.' }
    $env:RORADIO_REFRESH_ALLOW_LOOPBACK = '1'
    # No pause between the retries of a page that cannot be read: the fake answers at once.
    $env:RORADIO_REFRESH_RETRY_DELAY = '0'
    [pscustomobject]@{ Process = $process; Base = "http://127.0.0.1:$port"; RoutesPath = $routesPath }
}

function Close-FakeStationServer([object]$Server) {
    $env:RORADIO_REFRESH_ALLOW_LOOPBACK = $null
    $env:RORADIO_REFRESH_RETRY_DELAY = $null
    if ($Server) {
        $Server.Process.Kill()
        $Server.Process.WaitForExit()
        Remove-Item -LiteralPath $Server.RoutesPath -Force -ErrorAction SilentlyContinue
    }
}

# A catalogue of one category from { Title, Url, ImageUrl } entries, with a GUID for each, written like the real one
# (UTF-8 with a byte order mark, four-space indentation). Returns the stations with their GUIDs.
function Write-TestCatalog([string]$Path, [object[]]$Station) {
    $list = @(foreach ($entry in $Station) {
        $item = [ordered]@{ GUID = [Guid]::NewGuid().ToString(); Title = $entry.Title; Url = $entry.Url }
        if ($entry.ImageUrl) { $item.ImageUrl = $entry.ImageUrl }
        $item
    })
    $json = ConvertTo-Json -InputObject @([ordered]@{ Name = 'Test'; List = $list }) -Depth 5
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($true))
    $list | ForEach-Object { [pscustomobject]$_ }
}

# The stations of a catalogue, by title.
function Read-TestCatalog([string]$Path) {
    $byTitle = @{}
    foreach ($category in (Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json)) {
        foreach ($station in $category.List) { $byTitle[$station.Title] = $station }
    }
    $byTitle
}

# Lines joined by a separator: protocol text (ICY headers, playlists) written line by line.
function Join-Line([string]$Separator) {
    $args -join $Separator
}
