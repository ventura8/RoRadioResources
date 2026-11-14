<#
.SYNOPSIS
    End-to-end check of the RoRadio Cast receiver (F38F9694) on a real Cast device over adb: a touch display (the
    Pixel Tablet) or a TV (the Google TV Streamer).

.DESCRIPTION
    Plays the receiver's user flows on the device and saves an adb screenshot after each, then checks the device's own
    state:
      1. launch     the RoRadio receiver starts (not the Default Media Receiver) and shows its splash with the icon
      2. load       a station with its logo, name and previous / next (the app's customData)
      3. song       a song update: title, artist, album, year, cover beside the station's logo
      4. theme      the app's cover colour theme on, then off, read back from the page's "shown" status
      5. layout     the page's reported boxes against the device's real screenshot: no overlap, readable contrast,
                    and on a touch display nothing under its system media bar
      6. steps      next, previous, next again and pause: exactly one step per press, read back from the media
                    status as the app reads it. On a touch display they are taps on its system media bar; on a device
                    without a touch screen (a TV, found in `dumpsys input`, or -NoTouch) they are the presses a remote
                    or a sender makes, queue jumps and a PAUSE over Cast.
      7. play       the stream plays again
      8. switch     another station: the old song, cover and caption are gone
      9. stop       the receiver closes
    After the run: `dumpsys media_session` names the receiver's session, and logcat has no uncaught error from the
    receiver page and no fallback to the Default Media Receiver (CC1AD845).

    The cast plays at volume 10 / 100. Run it only when the device is yours to use (its lock file in local-ai is free):
    it launches an app on the device and plays audio.

.PARAMETER Device
    The device's adb serial.

.PARAMETER Address
    The device's IP address for Cast; read from its wlan0 when omitted.

.PARAMETER OutDir
    Where the screenshots and logs go (default: logs/receiver-e2e/<time> under the repository).

.PARAMETER NoTouch
    Treat the device as one without a touch screen even if `dumpsys input` lists one.

.EXAMPLE
    ./scripts/e2e/Test-ReceiverOnTablet.ps1 -Device adb-3406105H801UJL-TonHNR._adb-tls-connect._tcp

.EXAMPLE
    ./scripts/e2e/Test-ReceiverOnTablet.ps1 -Device <the TV's adb serial> -Address 192.168.1.107 -NoTouch
#>
[CmdletBinding()]
param(
    [string]$Device = 'adb-3406105H801UJL-TonHNR._adb-tls-connect._tcp',
    [string]$Address,
    [string]$OutDir,
    [switch]$NoTouch
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

# A touch display's system media bar: uiautomator sees only the receiver's web view (the bar is drawn inside it), so
# its buttons are tapped where the Pixel Tablet draws them, as shares of the screen (2560 x 1600, 2026-11-14):
# previous, pause, next on one row at 89 % of the height; the bar covers the bottom 28 %.
$bar = @{ previous = 0.401; pause = 0.5; next = 0.599; row = 0.888; reserve = 0.28 }

# The screen as it is turned now: `wm size` gives the natural (portrait) size, so it is read from a screenshot.
function Get-ScreenSize {
    $file = Join-Path $OutDir 'size.png'
    Start-Process adb -ArgumentList @('-s', $Device, 'exec-out', 'screencap', '-p') -NoNewWindow -Wait -RedirectStandardOutput $file
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Image]::FromFile($file)
    try { @{ width = $image.Width; height = $image.Height } } finally { $image.Dispose(); Remove-Item $file }
}

# A press while a sender listens; returns the steps the page broadcast and what it says it shows. On a touch display
# a tap on its system bar; without a touch screen what a remote or a sender sends: a queue jump, or PAUSE.
function Invoke-Press([string]$Button) {
    if ($script:Touch) {
        $screen = Get-ScreenSize
        return Invoke-Cast 'tap' @{ device = $Device; x = [int]($screen.width * $bar[$Button]); y = [int]($screen.height * $bar.row) }
    }

    if ($Button -eq 'pause') {
        return Invoke-Cast 'pause'
    }

    Invoke-Cast 'jump' @{ jump = $(if ($Button -eq 'next') { 1 } else { -1 }) }
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

# The page's own report (test mode, "rects") against the device's real screenshot: no two boxes overlap, on a touch
# display none reaches under its system bar, and every text's colour stands out from the median pixel of its box
# (WCAG AA for large text, 3:1; all the page's text is large). Returns $true when all hold; findings go to $failures.
function Test-Layout($Shown, [string]$Png) {
    if (-not $Shown -or -not $Shown.viewport -or -not $Shown.rects) {
        $failures.Add('the page reported no layout (its "shown" status has no rects)')
        return $false
    }

    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Bitmap]::new($Png)
    try {
        # CSS px to the screenshot's pixels (a 1920 x 1080 TV draws a 960 x 540 viewport at scale 2).
        $s = $image.Height / [double]$Shown.viewport[1]
        $boxes = @($Shown.rects.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ id = $_.Name; box = @($_.Value.box | ForEach-Object { [double]$_ * $s }); color = $_.Value.color }
            })
        $floor = $image.Height * $(if ($script:Touch) { 1 - $bar.reserve } else { 1 })
        $ok = $true
        foreach ($b in $boxes) {
            if ($b.box[3] -gt $floor + 1) { $failures.Add("$($b.id) reaches under the system bar or off the screen"); $ok = $false }
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
            # The background under the text: the median pixel of its box (the glyphs are the minority of a text box;
            # its edges, sampled first, ran through the glyphs and measured the text against itself).
            $samples = [Collections.Generic.List[object]]::new()
            for ($x = [int]$b.box[0]; $x -lt [math]::Min([int]$b.box[2], $image.Width); $x += 4) {
                for ($y = [int]$b.box[1]; $y -lt [math]::Min([int]$b.box[3], $image.Height); $y += 4) {
                    $p = $image.GetPixel($x, $y)
                    $samples.Add(@{ rgb = @([double]$p.R, [double]$p.G, [double]$p.B); l = Get-Luminance @($p.R, $p.G, $p.B) })
                }
            }
            # A text box with no pixel on the screenshot is off the screen: a failure, never a skip (Greptile, #48).
            if ($samples.Count -eq 0) {
                $failures.Add("$($b.id) is off the screenshot")
                $ok = $false
                continue
            }
            $median = ($samples | Sort-Object { $_.l })[[int]($samples.Count / 2)]
            $worst = Get-Contrast $rgb $median.rgb
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
    if (-not $Address) { throw 'The device has no wlan0 address: pass -Address.' }
}
$script:Address = $Address
# A touch display lists a touchscreen input source; a TV has its remote, and its presses come over Cast instead.
$script:Touch = -not $NoTouch -and ((Invoke-Adb @('shell', 'dumpsys', 'input')) -join "`n") -match 'TOUCHSCREEN'
Write-Information "Device $Device at $Address, $(if ($script:Touch) { 'a touch display' } else { 'no touch screen' })" -InformationAction Continue
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
# The app's cover colour theme on, then off: the receiver reports the colours it took, then none.
Test-Step 'theme on' {
    $themed = $station.Clone()
    $themed.title = 'Test song'; $themed.artist = 'Test artist'; $themed.images = @("$pages/90er-stream.png", "$pages/Profm.png")
    $themed.data = $station.data.Clone()
    $themed.data.theme = @{ accent = '#f0e040'; tint = '#4d4813' }
    Invoke-Cast 'song' $themed | Out-Null
    Start-Sleep -Seconds 2
    (Invoke-Cast 'shown').theme.tint -eq '#4d4813'
}
Test-Step 'theme off' {
    $plain = $station.Clone()
    $plain.title = 'Test song'; $plain.artist = 'Test artist'; $plain.album = 'Test album'; $plain.year = '2025'
    $plain.images = @("$pages/90er-stream.png", "$pages/Profm.png")
    Invoke-Cast 'song' $plain | Out-Null
    Start-Sleep -Seconds 2
    $script:layout = Invoke-Cast 'shown'
    $null -eq $script:layout.theme -and $script:layout.cover -and $script:layout.logo -and $script:layout.title -eq 'Test song'
}
# The screen as the page reports it (read in 'theme off'), on that step's screenshot.
Test-Step 'layout on the screenshot' { Test-Layout $script:layout (Join-Path $OutDir 'theme-off.png') }
# One press is exactly one step. A touch display's bar sends every press with one request id: previous after next,
# and next again, must each still step.
Test-Step 'next' { ((Invoke-Press 'next').steps -join ',') -eq 'next' }
Test-Step 'previous' { ((Invoke-Press 'previous').steps -join ',') -eq 'previous' }
Test-Step 'next again' { ((Invoke-Press 'next').steps -join ',') -eq 'next' }
Test-Step 'pause' {
    Invoke-Press 'pause' | Out-Null
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
    Write-Error "Receiver E2E on the device failed: $($failures -join '; ')"
}
Write-Information 'Receiver E2E on the device passed.' -InformationAction Continue
