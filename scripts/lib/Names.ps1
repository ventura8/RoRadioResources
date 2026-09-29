# Station-name helpers shared by the station scripts (dot-sourced).

# Titles are matched without diacritics and case: Romanian writes t and s both with a cedilla and with a comma
# below, the catalogue is not consistent about it, and Sentry's logs drop them entirely ("Constan?a").
function ConvertTo-PlainTitle([string]$Text) {
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $kept = $decomposed.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' }
    (-join $kept).ToLowerInvariant().Trim()
}

function ConvertTo-Slug([string]$Text) {
    ((ConvertTo-PlainTitle $Text) -replace "['’]", '' -replace '[^a-z0-9]+', '-').Trim('-')
}

# What of a station's name must show up in a host name for that host to be the station's own: the whole name
# run together ("radionoise", "romanfm") and each distinctive word of four letters or more ("noise", "aquila").
function Get-NameMark([string]$Title) {
    $generic = 'radio', 'online', 'romania', 'music', 'muzica', 'live', 'stream', 'best', 'hits', 'station'
    $words = @((ConvertTo-PlainTitle $Title) -split '[^a-z0-9]+' | Where-Object { $_ })
    @(-join $words) + @($words | Where-Object { $_.Length -ge 4 -and $generic -notcontains $_ }) | Select-Object -Unique
}

# True when the text carries one of the station's name marks (spaces and dashes ignored).
function Test-NameMark([string[]]$Marks, [string]$Text) {
    $plain = (ConvertTo-PlainTitle $Text) -replace '[\s\-_]', ''
    [bool]($Marks | Where-Object { $plain.Contains($_) })
}

# The host of a url, lower case; '' when it is not one.
function Get-UrlHost([string]$Url) {
    try { ([Uri]$Url).Host.ToLowerInvariant() } catch { '' }
}

function Get-UrlPath([string]$Url) {
    try { ([Uri]$Url).AbsolutePath } catch { '' }
}

# The myradioonline.ro pages whose slug fits a station title (as is, without or with a leading "radio-").
function Get-MyRadioOnlineSlug([string]$Title, [string[]]$Known) {
    $slug = ConvertTo-Slug $Title
    @($slug, ($slug -replace '^radio-', ''), "radio-$slug") | Select-Object -Unique | Where-Object { $Known -contains $_ }
}

function Get-MyRadioOnlineSitemap {
    $sitemap = Get-Text 'https://myradioonline.ro/sitemap.xml'
    @([regex]::Matches($sitemap, '<loc>https://myradioonline\.ro/([a-z0-9-]+)</loc>') | ForEach-Object { $_.Groups[1].Value })
}
