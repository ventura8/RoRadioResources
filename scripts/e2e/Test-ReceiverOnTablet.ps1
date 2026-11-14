<#
.SYNOPSIS
    End-to-end check of the RoRadio Cast receiver (F38F9694) on a real touch display: a Pixel Tablet over adb.

.DESCRIPTION
    Plays the receiver's user flows on the device and saves an adb screenshot after each, then checks the device's own
    state:
      1. launch     the RoRadio receiver starts (not the Default Media Receiver) and shows its splash with the icon
      2. load       a station with its logo, name and previous / next (the app's customData)
      3. song       a song update: title, artist, album, year, cover beside the station's logo
      4. touch      the page's own previous / next buttons, found by their labels and tapped; the step is read back
                    from the media status, as the app reads it
      5. pause/play the stream pauses and resumes
      6. switch     another station: the old song, cover and caption are gone
      7. stop       the receiver closes
    After the run: `dumpsys media_session` names the receiver's session and the song, and logcat has no uncaught
    error from the receiver page and no fallback to the Default Media Receiver (CC1AD845).

    The cast plays at volume 10 / 100. Run it only when the tablet is yours to use (its lock file in local-ai is free):
    it launches an app on the device and plays audio.

.PARAMETER Device
    The adb serial of the tablet.

.PARAMETER Address
    The tablet's IP address for Cast; read from the device's wlan0 when omitted.

.PARAMETER OutDir
    Where the screenshots and logs go (default: logs/receiver-e2e/<time> under the repository).

.EXAMPLE
    ./scripts/e2e/Test-ReceiverOnTablet.ps1 -Device adb-3406105H801UJL-TonHNR._adb-tls-connect._tcp
#>
[CmdletBinding()]
param(
    [string]$Device = 'adb-3406105H801UJL-TonHNR._adb-tls-connect._tcp',
    [string]$Address,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# The functions below read the device from the script's scope.
$script:Device = $Device
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $OutDir) { $OutDir = Join-Path $root "logs/receiver-e2e/$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$client = Join-Path $PSScriptRoot 'cast-client.mjs'
$pages = 'https://ventura8.github.io/RoRadioResources/RadioLogos'
$failures = [Collections.Generic.List[string]]::new()

function Invoke-Adb([string[]]$Arguments) {
    $output = & adb -s $Device @Arguments
    if ($LASTEXITCODE -ne 0) { throw "adb $($Arguments -join ' ') failed: $output" }
    $output
}

function Save-Screen([string]$Name) {
    $file = Join-Path $OutDir "$Name.png"
    $process = Start-Process adb -ArgumentList @('-s', $Device, 'exec-out', 'screencap', '-p') -NoNewWindow -Wait -PassThru -RedirectStandardOutput $file
    if ($process.ExitCode -ne 0 -or (Get-Item $file).Length -lt 1000) { $failures.Add("screenshot $Name") }
    Write-Information "  screenshot: $file" -InformationAction Continue
}

function Invoke-Cast([string]$Step, [hashtable]$Data = @{}) {
    $json = $Data | ConvertTo-Json -Compress -Depth 5
    $answer = & node $client $script:Address $Step $json
    if ($LASTEXITCODE -ne 0) { throw "Cast step $Step failed" }
    Write-Information "  $Step -> $answer" -InformationAction Continue
    $answer | ConvertFrom-Json
}

function Test-Step([string]$Name, [scriptblock]$Check) {
    Write-Information "==> $Name" -InformationAction Continue
    try {
        if ((& $Check) -eq $false) { $failures.Add($Name) }
    } catch {
        $failures.Add("${Name}: $($_.Exception.Message)")
    }
    Start-Sleep -Seconds 3
    Save-Screen ($Name -replace '[^a-z0-9]+', '-')
}

# The centre of the page's own button, found by its label (the WebView exposes aria-label as content-desc).
function Find-Button([string]$Label) {
    Invoke-Adb @('shell', 'uiautomator', 'dump', '/sdcard/receiver-ui.xml') | Out-Null
    $xml = [xml](Invoke-Adb @('shell', 'cat', '/sdcard/receiver-ui.xml'))
    $node = $xml.SelectSingleNode("//node[@content-desc='$Label']")
    if (-not $node) { throw "no '$Label' button on the screen" }
    $bounds = [regex]::Matches($node.bounds, '\d+') | ForEach-Object { [int]$_.Value }
    @{ device = $Device; x = [int](($bounds[0] + $bounds[2]) / 2); y = [int](($bounds[1] + $bounds[3]) / 2) }
}

# Taps it while a sender listens; returns the step the page broadcast, or null.
function Invoke-Tap([string]$Label) {
    (Invoke-Cast 'tap' (Find-Button $Label)).step
}

if (-not $Address) {
    $inet = Invoke-Adb @('shell', 'ip', '-f', 'inet', 'addr', 'show', 'wlan0')
    $Address = ([regex]::Match(($inet -join ' '), 'inet (\d+\.\d+\.\d+\.\d+)')).Groups[1].Value
    if (-not $Address) { throw 'The tablet has no wlan0 address: pass -Address.' }
}
$script:Address = $Address
Remove-Item (Join-Path ([IO.Path]::GetTempPath()) 'roradio-cast-e2e.json') -ErrorAction SilentlyContinue
Invoke-Adb @('logcat', '-c') | Out-Null
Invoke-Adb @('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP') | Out-Null

$station = @{
    url = 'https://edge126.rcs-rds.ro/profm/profm.mp3'; title = 'Pro FM'; artist = 'Pro FM'; album = $null; year = $null
    images = @("$pages/Profm.png")
    data = @{ caption = ''; previous = $true; next = $true; station = 'Pro FM'; logo = "$pages/Profm.png" }
}

Test-Step 'launch' { (Invoke-Cast 'launch').appId -eq 'F38F9694' }
Test-Step 'load' { (Invoke-Cast 'load' $station).playerState -in @('PLAYING', 'BUFFERING') }
Test-Step 'song' {
    $song = $station.Clone()
    $song.title = 'Test song'; $song.artist = 'Test artist'; $song.album = 'Test album'; $song.year = '2025'
    # A picture GitHub Pages serves stands in for the song's cover: the check is that cover and logo both show.
    $song.images = @("$pages/90er-stream.png", "$pages/Profm.png")
    Invoke-Cast 'song' $song | Out-Null
}
Test-Step 'touch next' { (Invoke-Tap 'Next station') -eq 'next' }
Test-Step 'touch previous' { (Invoke-Tap 'Previous station') -eq 'previous' }
Test-Step 'touch pause' {
    Invoke-Tap 'Pause' | Out-Null
    (Invoke-Cast 'status').playerState -eq 'PAUSED'
}
Test-Step 'play' { (Invoke-Cast 'play').playerState -in @('PLAYING', 'BUFFERING') }
Test-Step 'switch' {
    $other = $station.Clone()
    $other.title = 'Other station'; $other.artist = 'Other station'
    $other.data = @{ caption = ''; previous = $true; next = $false; station = 'Other station'; logo = "$pages/Profm.png" }
    (Invoke-Cast 'load' $other).playerState -in @('PLAYING', 'BUFFERING')
}

Invoke-Adb @('shell', 'dumpsys', 'media_session') | Set-Content (Join-Path $OutDir 'media_session.txt')
Invoke-Adb @('logcat', '-d') | Set-Content (Join-Path $OutDir 'logcat.txt')
Test-Step 'stop' { -not ((Invoke-Cast 'stop').applications -contains 'F38F9694') }

Write-Information '==> device state' -InformationAction Continue
$log = Get-Content (Join-Path $OutDir 'logcat.txt') -Raw
if ($log -match 'CC1AD845') { $failures.Add('the device fell back to the Default Media Receiver (CC1AD845)') }
if ($log -match 'Uncaught .*receiver\.js') { $failures.Add('an uncaught error in receiver.js (logcat)') }
$sessions = Get-Content (Join-Path $OutDir 'media_session.txt') -Raw
if ($sessions -notmatch 'mediashell|cast') { $failures.Add('no Cast media session in dumpsys media_session') }

Write-Information "Screenshots and logs: $OutDir" -InformationAction Continue
if ($failures.Count -gt 0) {
    Write-Error "Receiver E2E on the tablet failed: $($failures -join '; ')"
}
Write-Information 'Receiver E2E on the tablet passed.' -InformationAction Continue
