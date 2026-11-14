# Network helpers shared by the station scripts (dot-sourced; Test-StationStreams.ps1 loads lib/Probe.ps1, and this
# file with it, inside each of its parallel runspaces). The weekly refresh runs on a GitHub runner against urls that
# come from the internet (directories, the status pages of stream servers, station web sites). A url - or a redirect -
# that points into a private network, the machine itself or a cloud metadata address (169.254.169.254) is never
# requested (CodeRabbit, RoRadioResources#2), so redirects are followed one checked hop at a time, never by curl -L.
#
# The one exception is the end-to-end tests (tests/Refresh.E2E.Tests.ps1): they run the real scripts against a fake
# station server on this machine and set RORADIO_REFRESH_ALLOW_LOOPBACK=1 for that. It opens the loopback addresses
# (127.0.0.0/8, ::1) and nothing else: private networks and the metadata address stay refused. No workflow sets it.

$script:StationUserAgent = 'RoRadio-station-refresh (+https://github.com/ventura8/RoRadioResources)'
# curl.exe on Windows (Windows PowerShell's "curl" was an alias of Invoke-WebRequest), curl elsewhere.
$script:Curl = ('curl', 'curl.exe')[[int][bool](Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)]
# What Get-Text could not read in this run: a directory or a station page that was down. The refresh report lists
# them, so a run that found nothing because a source was down says so instead of only listing stations unresolved.
$script:UnreadableSource = [Collections.Generic.List[string]]::new()

function Test-PrivateAddress([Net.IPAddress]$Address) {
    if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
    if ([Net.IPAddress]::IsLoopback($Address)) { return $env:RORADIO_REFRESH_ALLOW_LOOPBACK -ne '1' }
    if ($Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or $Address.IsIPv6Multicast) { return $true }
    $b = $Address.GetAddressBytes()
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ($b[0] -band 0xFE) -eq 0xFC -or $Address.Equals([Net.IPAddress]::IPv6None)
    }

    $b[0] -eq 0 -or $b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -ge 224 -or
        ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)
}

# The addresses of a host name (a function of its own, so that the tests can answer for DNS).
function Resolve-HostAddress([string]$HostName) {
    [Net.Dns]::GetHostAddresses($HostName)
}

# The curl arguments that pin a request to an address checked here, or $null when the url may not be requested.
# Checking the name and letting curl resolve it again would leave a gap (DNS rebinding: the second answer can be
# private), so a name is bound with --resolve to the first checked address.
function Get-PinnedTarget([string]$Url) {
    try { $uri = [Uri]$Url } catch { return $null }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin 'http', 'https') { return $null }
    try { $addresses = @(Resolve-HostAddress $uri.DnsSafeHost) } catch { return $null }
    if ($addresses.Count -eq 0 -or ($addresses | Where-Object { Test-PrivateAddress $_ })) { return $null }
    if ($uri.HostNameType -in 'IPv4', 'IPv6') { return , @() }
    # IPv4 first: GitHub's runners have no IPv6 route, and a pinned IPv6 address would read as dead there.
    $address = @($addresses | Where-Object AddressFamily -eq ([Net.Sockets.AddressFamily]::InterNetwork)) + @($addresses) | Select-Object -First 1
    $literal = ("$address", "[$address]")[[int]($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6)]
    , @('--resolve', "$($uri.Host):$($uri.Port):$literal")
}

function Test-PublicUrl([string]$Url) {
    $null -ne (Get-PinnedTarget $Url)
}

# Downloads a url into a file, every redirect hop checked and pinned. Returns the url that answered 200, or $null
# (a private destination, an HTTP error, more than $MaxBytes, nothing within $TimeoutSeconds), and then leaves no file.
function Save-PublicFile([string]$Url, [string]$Path, [int]$TimeoutSeconds = 20, [long]$MaxBytes = 5MB, [int]$Retries = 0) {
    $current = $Url
    foreach ($hop in 0..5) {
        Write-Debug "Hop ${hop}: $current"
        $pin = Get-PinnedTarget $current
        if ($null -eq $pin) { break }
        $line = & $script:Curl -s @pin -o $Path --max-time $TimeoutSeconds --max-filesize $MaxBytes --retry $Retries -A $script:StationUserAgent -w '%{http_code}|%{redirect_url}' $current 2>$null
        $exit = $LASTEXITCODE
        $parts = "$line".Split('|')
        # curl reports a transfer it cut short through its exit code (63: more than --max-filesize, 28: too slow),
        # while -w still prints the 200 it started with: what it wrote is not the file (Copilot, RoRadioResources#2).
        if ($exit -eq 0 -and $parts[0] -eq '200') { return $current }
        if ($exit -ne 0 -or $parts[0] -notmatch '^3\d\d$' -or $parts.Count -lt 2 -or -not $parts[1]) { break }
        $current = $parts[1]
    }

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -WhatIf:$false
    $null
}

# A page's text through Save-PublicFile (checked, pinned, capped), or $null.
function Get-PublicText([string]$Url, [long]$MaxBytes = 10MB, [int]$TimeoutSeconds = 30, [int]$Retries = 0) {
    $file = [IO.Path]::GetTempFileName()
    try {
        $final = Save-PublicFile $Url $file -TimeoutSeconds $TimeoutSeconds -MaxBytes $MaxBytes -Retries $Retries
        if ($final) { [IO.File]::ReadAllText($file) }
    } finally {
        # Scratch files go even under -WhatIf, which guards the catalogue only (dry runs left them in the temp folder).
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# A web page's text; '' (with a warning, and the url noted for the report) when it cannot be read. Two retries:
# directories answer slowly at times.
function Get-Text([string]$Url) {
    $text = Get-PublicText $Url -Retries 2
    if ($null -eq $text) {
        Write-Warning "Could not read $Url"
        $script:UnreadableSource.Add($Url)
        return ''
    }
    $text
}

# A lookup that is allowed to find nothing (a status page most servers do not have): no retries, no warning.
function Get-OptionalJson([string]$Url) {
    $text = Get-PublicText $Url -MaxBytes 2MB -TimeoutSeconds 10
    if (-not $text) { return $null }
    try { $text | ConvertFrom-Json } catch { $null }
}
