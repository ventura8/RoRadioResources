# Network helpers shared by the station scripts (dot-sourced; Test-StationStreams.ps1 loads it inside each of its
# parallel runspaces). The weekly refresh runs on a GitHub runner against urls that come from the internet
# (directories, the status pages of stream servers, station web sites). A url - or a redirect - that points into a
# private network, the machine itself or a cloud metadata address (169.254.169.254) is never requested (CodeRabbit,
# RoRadioResources#2), so redirects are followed one checked hop at a time, never by curl -L.

$script:StationUserAgent = 'RoRadio-station-refresh (+https://github.com/ventura8/RoRadioResources)'
$script:Curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }

function Test-PrivateAddress([Net.IPAddress]$Address) {
    if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
    if ([Net.IPAddress]::IsLoopback($Address) -or $Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or $Address.IsIPv6Multicast) { return $true }
    $b = $Address.GetAddressBytes()
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ($b[0] -band 0xFE) -eq 0xFC -or $Address.Equals([Net.IPAddress]::IPv6None)
    }

    $b[0] -eq 0 -or $b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -ge 224 -or
        ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)
}

# The curl arguments that pin a request to an address checked here, or $null when the url may not be requested.
# Checking the name and letting curl resolve it again would leave a gap (DNS rebinding: the second answer can be
# private), so a name is bound with --resolve to the first checked address.
function Get-PinnedTarget([string]$Url) {
    try { $uri = [Uri]$Url } catch { return $null }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin 'http', 'https') { return $null }
    try { $addresses = [Net.Dns]::GetHostAddresses($uri.DnsSafeHost) } catch { return $null }
    if ($addresses.Count -eq 0 -or ($addresses | Where-Object { Test-PrivateAddress $_ })) { return $null }
    if ($uri.HostNameType -in 'IPv4', 'IPv6') { return , @() }
    # IPv4 first: GitHub's runners have no IPv6 route, and a pinned IPv6 address would read as dead there.
    $address = @($addresses | Where-Object AddressFamily -eq ([Net.Sockets.AddressFamily]::InterNetwork)) + @($addresses) | Select-Object -First 1
    $literal = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { "[$address]" } else { "$address" }
    , @('--resolve', "$($uri.Host):$($uri.Port):$literal")
}

function Test-PublicUrl([string]$Url) {
    $null -ne (Get-PinnedTarget $Url)
}

# Downloads a url into a file, every redirect hop checked and pinned. Returns the url that answered 200, or $null
# (a private destination, an HTTP error, more than $MaxBytes, nothing within $TimeoutSeconds).
function Save-PublicFile([string]$Url, [string]$Path, [int]$TimeoutSeconds = 20, [long]$MaxBytes = 5MB) {
    $current = $Url
    foreach ($hop in 0..5) {
        $pin = Get-PinnedTarget $current
        if ($null -eq $pin) { return $null }
        $line = & $script:Curl -s @pin -o $Path --max-time $TimeoutSeconds --max-filesize $MaxBytes -A $script:StationUserAgent -w '%{http_code}|%{redirect_url}' $current 2>$null
        $parts = "$line".Split('|')
        if ($parts[0] -eq '200') { return $current }
        if ($parts[0] -notmatch '^3\d\d$' -or $parts.Count -lt 2 -or -not $parts[1]) { return $null }
        $current = $parts[1]
    }

    $null
}

# A web page's text; '' (with a warning) when it cannot be read.
function Get-Text([string]$Url) {
    try {
        $content = (Invoke-WebRequest -Uri $Url -UserAgent $script:StationUserAgent -TimeoutSec 30 -MaximumRetryCount 2).Content
        # A playlist (.pls, audio/x-scpls) is not a text content type to PowerShell: it comes back as bytes.
        if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { $content }
    } catch {
        Write-Warning "Could not read ${Url}: $($_.Exception.Message)"
        ''
    }
}

# A lookup that is allowed to find nothing (a status page most servers do not have): no retries, no warning.
function Get-OptionalJson([string]$Url) {
    try {
        (Invoke-WebRequest -Uri $Url -UserAgent $script:StationUserAgent -TimeoutSec 10).Content | ConvertFrom-Json
    } catch {
        $null
    }
}
