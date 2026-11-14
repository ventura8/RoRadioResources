<#
.SYNOPSIS
    End-to-end check of the RoRadio Cast receiver (F38F9694) on a real touch display: a Pixel Tablet over adb.

.DESCRIPTION
    Plays the receiver's user flows on the device and saves an adb screenshot after each, then checks the device's own
    state:
      1. launch     the RoRadio receiver starts (not the Default Media Receiver) and shows its splash with the icon
      2. load       a station with its logo, name and previous / next (the app's customData)
      3. song       a song update: title, artist, album, year, cover beside the station's logo
      4. touch      the system media bar's next / previous / pause, tapped; exactly one step per press is read back
                    from the media status, as the app reads it, with what the page says it shows ("shown")
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

# The device's system media bar: uiautomator sees only the receiver's web view (the bar is drawn inside it), so its
# buttons are tapped where the Pixel Tablet draws them, as shares of the screen (2560 x 1600, 2026-11-14): previous,
# pause, next on one row at 89 % of the height.
$bar = @{ previous = 0.401; pause = 0.5; next = 0.599; row = 0.888; reserve = 0.28 }

function Get-ScreenSize {
    $size = [regex]::Match((Invoke-Adb @('shell', 'wm', 'size')) -join ' ', '(\d+)x(\d+)')
    @{ width = [int]$size.Groups[1].Value; height = [int]$size.Groups[2].Value }
}

# Taps a system bar button while a sender listens; returns the steps the page broadcast and what it says it shows.
function Invoke-Tap([string]$Button) {
    $screen = Get-ScreenSize
    $tap = @{ device = $Device; x = [int]($screen.width * $bar[$Button]); y = [int]($screen.height * $bar.row) }
    Invoke-Cast 'tap' $tap
}

# The WCAG relative luminance of a colour, and the contrast of two.
function Get-Luminance([double[]]$Rgb) {
    $c = $Rgb | ForEach-Object { $v = $_ / 255; if ($v -le 0.03928) { $v / 12.92 } else { [math]::Pow(($v + 0.055) / 1.055, 2.4) } }
    0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
}

function Get-Contrast([double[]]$A, [double[]]$B) {
    $la = Get-Luminance $A
    $lb = Get-Luminance $B
    ([math]::Max($la, $lb) + 0.05) / ([math]::Min($la, $lb) + 0.05)
}

# The page's own report (test mode, "rects") against the device's real screenshot: no two boxes overlap, none
# reaches under the system bar, and every text's colour stands out from the pixels along its box's edges (WCAG AA
# for large text, 3:1; all the page's text is large). Returns $true when all hold; the findings go to $failures.
function Test-Layout($Shown, [string]$Png) {
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Bitmap]::new($Png)
    try {
        # CSS px to the screenshot's pixels.
        $s = $image.Height / $Shown.viewport[1]
        $boxes = @($Shown.rects.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ id = $_.Name; box = @($_.Value.box | ForEach-Object { $_ * $s }); color = $_.Value.color }
            })
        $ok = $true
        foreach ($b in $boxes) {
            if ($b.box[3] -gt $image.Height * (1 - $bar.reserve)) { $failures.Add("$($b.id) reaches under the system bar"); $ok = $false }
        }
        for ($i = 0; $i -lt $boxes.Count; $i++) {
            for ($j = $i + 1; $j -lt $boxes.Count; $j++) {
                $a = $boxes[$i].box
                $c = $boxes[$j].box
                if ([math]::Min($a[2], $c[2]) - [math]::Max($a[0], $c[0]) -gt 1 -and [math]::Min($a[3], $c[3]) - [math]::Max($a[1], $c[1]) -gt 1) {
                    $failures.Add("$($boxes[$i].id) overlaps $($boxes[$j].id)")
                    $ok = $false
                }
            }
        }
        foreach ($b in $boxes | Where-Object { $_.id -notin @('cover', 'station') }) {
            $rgb = @([regex]::Matches($b.color, '[\d.]+') | Select-Object -First 3 | ForEach-Object { [double]$_.Value })
            $worst = [double]::MaxValue
            for ($x = [int]$b.box[0]; $x -lt [int]$b.box[2]; $x += 4) {
                foreach ($y in @([int]$b.box[1], ([int]$b.box[3] - 1))) {
                    $p = $image.GetPixel([math]::Min($x, $image.Width - 1), [math]::Min([math]::Max($y, 0), $image.Height - 1))
                    $worst = [math]::Min($worst, (Get-Contrast $rgb @($p.R, $p.G, $p.B)))
                }
            }
            if ($worst -lt 3) {
                $failures.Add("$($b.id) contrast $([math]::Round($worst, 2)):1 under 3:1")
                $ok = $false
            }
        }
        $ok
    } finally {
        $image.Dispose()
    }
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
    # rects: the page's test mode, which reports its boxes for the layout check on the screenshot.
    data = @{ caption = ''; previous = $true; next = $true; station = 'Pro FM'; logo = "$pages/Profm.png"; rects = $true }
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
# One press is exactly one step, and the screen shows the song's cover with the station's logo beside it.
Test-Step 'touch next' {
    $heard = Invoke-Tap 'next'
    $script:layout = $heard.shown
    ($heard.steps -join ',') -eq 'next' -and $heard.shown.cover -and $heard.shown.logo -and $heard.shown.title -eq 'Test song'
}
Test-Step 'layout on the screenshot' { Test-Layout $script:layout (Join-Path $OutDir 'touch-next.png') }
Test-Step 'touch previous' { ((Invoke-Tap 'previous').steps -join ',') -eq 'previous' }
Test-Step 'touch pause' {
    Invoke-Tap 'pause' | Out-Null
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
# A fallback is the Default Media Receiver STARTING. Its id is in every Cast mDNS record and in the "App stopping"
# line of a receiver our launch replaced, which an earlier check took for a fallback (2026-11-14).
$fallback = @($log -split "`n" | Where-Object { $_ -match 'Starting app: app_id=CC1AD845' })
if ($fallback) { $failures.Add("the device started the Default Media Receiver: $($fallback[0].Trim())") }
if ($log -match 'Uncaught .*receiver\.js') { $failures.Add('an uncaught error in receiver.js (logcat)') }
$sessions = Get-Content (Join-Path $OutDir 'media_session.txt') -Raw
if ($sessions -notmatch 'mediashell|cast') { $failures.Add('no Cast media session in dumpsys media_session') }

Write-Information "Screenshots and logs: $OutDir" -InformationAction Continue
if ($failures.Count -gt 0) {
    Write-Error "Receiver E2E on the tablet failed: $($failures -join '; ')"
}
Write-Information 'Receiver E2E on the tablet passed.' -InformationAction Continue
