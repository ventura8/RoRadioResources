#Requires -Version 7.0
<#
.SYNOPSIS
    Retires the stations that are gone for good, rechecks the retired ones and restores those that play again.

.DESCRIPTION
    Runs after Update-StationUrls.ps1 in the weekly refresh, on its results:

      1. Remembers since when each station has failed every check: dead, and no source found a replacement or even
         a suggestion. The dates live in -StatePath (state/failing.json on the refresh-data branch), so the count
         survives between runs; a station that plays again, or for which a candidate turned up, starts over.
      2. Retires a station that has failed that way for -RetireAfterDays days in a row (30): its block leaves
         RadioStationsData.json and goes, verbatim, to RetiredStations.json with its category, the station before it,
         its last url and logo, the dates and the evidence. RoRadio keeps a removed station's favorite and last-station
         GUID, so a station that comes back is a favorite again.
      3. Rechecks the retired stations whose time has come: 30 days after retirement, then 60 days after that check,
         then 90, then 120 (-RecheckDays times the number of checks so far, plus one). The old url and a search of
         every source (Update-StationUrls.ps1) are tried; a url that plays in two probes restores the station to its
         category, after the station it followed, and its schedule starts over if it is ever retired again.
      4. Does nothing of the above in a run where more than -MassFailureRatio of the probed stations failed (10%): a
         source or the runner's network is the problem then, not the stations. It says so in the report.

    Retired stations can also be added by hand: an entry needs GUID, Title, Url, Category and NextCheck (yyyy-MM-dd);
    without Block the station's block is rebuilt from its fields when it is restored.

.PARAMETER Catalog
    The station list. Default: RadioStationsData.json next to this folder.

.PARAMETER RetiredPath
    The retired stations. Default: RetiredStations.json next to this folder.

.PARAMETER StatePath
    The first-failed dates (JSON: GUID -> { Title, FirstFailed }).

.PARAMETER ResultsPath
    Update-StationUrls.ps1's results (-ResultsPath there).

.PARAMETER Probed
    How many stations Update-StationUrls.ps1 probed.

.PARAMETER Date
    Today (yyyy-MM-dd). Default: today, UTC.

.PARAMETER RetireAfterDays
    How long a station must fail every check before it is retired.

.PARAMETER RecheckDays
    The first recheck comes this many days after retirement; each failed one pushes the next further by as much.

.PARAMETER MassFailureRatio
    Above this share of failing stations nothing is retired or rechecked.

.PARAMETER SearchArguments
    Passed on to Update-StationUrls.ps1 for the rechecks (timeouts, the sources' addresses).

.PARAMETER ReportPath
    Where to write the Markdown report (it is appended to the url report in the release note and the issue).

.OUTPUTS
    { Retired, Restored, Rechecked, Failing, MassFailure }.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Catalog,
    [string]$RetiredPath,
    [Parameter(Mandatory)] [string]$StatePath,
    [Parameter(Mandatory)] [string]$ResultsPath,
    [Parameter(Mandatory)] [int]$Probed,
    [string]$Date = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture),
    [int]$RetireAfterDays = 30,
    [int]$RecheckDays = 30,
    [double]$MassFailureRatio = 0.1,
    [hashtable]$SearchArguments = @{},
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$Catalog = @($Catalog, (Join-Path $root 'RadioStationsData.json')) | Where-Object { $_ } | Select-Object -First 1
$RetiredPath = @($RetiredPath, (Join-Path $root 'RetiredStations.json')) | Where-Object { $_ } | Select-Object -First 1
. (Join-Path $PSScriptRoot 'lib/Catalog.ps1')
. (Join-Path $PSScriptRoot 'lib/Resilience.ps1')
$invariant = [Globalization.CultureInfo]::InvariantCulture
$today = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', $invariant)
function Format-Day([DateTime]$Day) { $Day.ToString('yyyy-MM-dd', $invariant) }
function Read-Day([string]$Text) { [DateTime]::ParseExact($Text, 'yyyy-MM-dd', $invariant) }

$bytes = [IO.File]::ReadAllBytes($Catalog)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [Text.UTF8Encoding]::new($false).GetString($bytes).TrimStart([char]0xFEFF)
$stations = @(Read-StationList $text)
$results = @(Get-Content $ResultsPath -Raw -Encoding utf8 | ConvertFrom-Json | Where-Object { $_ })
$retired = [Collections.Generic.List[object]]::new()
if (Test-Path $RetiredPath) { foreach ($entry in @(Get-Content $RetiredPath -Raw -Encoding utf8 | ConvertFrom-Json)) { $retired.Add($entry) } }
$state = [ordered]@{}
if (Test-Path $StatePath) {
    $saved = Get-Content $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($property in @($saved.PSObject.Properties)) { $state[$property.Name] = $property.Value }
}

$mass = $Probed -gt 0 -and $results.Count -gt $MassFailureRatio * $Probed
# Gone this run: dead, and nothing found for it, not even a suggestion.
$gone = @($results | Where-Object { $_.OldVerdict -eq 'dead' -and -not $_.NewUrl -and -not $_.Suggested })
if (-not $mass) {
    $next = [ordered]@{}
    foreach ($result in $gone) {
        $first = @($state[$result.Guid].FirstFailed, $Date) | Where-Object { $_ } | Select-Object -First 1
        $next[$result.Guid] = [ordered]@{ Title = $result.Title; FirstFailed = $first }
    }
    $state = $next
}

# 2: retire.
$retiredNow = [Collections.Generic.List[object]]::new()
$kept = [Collections.Generic.List[string]]::new()
foreach ($result in $gone | Where-Object { -not $mass }) {
    $since = Read-Day $state[$result.Guid].FirstFailed
    if (($today - $since).TotalDays -lt $RetireAfterDays) { continue }
    $station = $stations | Where-Object Guid -eq $result.Guid | Select-Object -First 1
    $removed = Get-ListWithoutStation $text $result.Guid
    $alone = -not ($stations | Where-Object { $_.Category -eq $station.Category -and $_.Guid -ne $station.Guid -and $retiredNow.GUID -notcontains $_.Guid })
    if (-not $station -or -not $removed -or $alone) {
        $kept.Add("$($result.Title): $(@('not found in the list', 'the only station left in its category')[[int][bool]($station -and $alone)])")
        continue
    }
    $entry = [pscustomobject][ordered]@{
        GUID        = $result.Guid
        Title       = $result.Title
        Url         = $result.OldUrl
        ImageUrl    = $station.ImageUrl
        Category    = $station.Category
        After       = $station.After
        Block       = Get-StationBlock $text $result.Guid
        FirstFailed = $state[$result.Guid].FirstFailed
        Retired     = $Date
        LastChecked = $Date
        Checks      = 0
        NextCheck   = Format-Day $today.AddDays($RecheckDays)
        Evidence    = "Dead in every run since $($state[$result.Guid].FirstFailed); no source had a replacement ($($result.Tried) candidate(s) tried on $Date)."
    }
    $text = $removed
    $retiredNow.Add($entry)
    $retired.Add($entry)
    $state.Remove($result.Guid)
}

# 3: recheck the retired stations that are due, and restore those that play.
$due = @($retired | Where-Object { -not $mass -and $retiredNow -notcontains $_ -and (Read-Day $_.NextCheck) -le $today })
$restoredNow = [Collections.Generic.List[object]]::new()
$recheckedNow = [Collections.Generic.List[object]]::new()
if ($due) {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "roradio-retired-$PID"
    New-Item -ItemType Directory -Force -Path $scratch -WhatIf:$false | Out-Null
    $recheckList = Join-Path $scratch 'retired.json'
    $recheckResults = Join-Path $scratch 'results.json'
    $list = @($due | ForEach-Object { [ordered]@{ GUID = $_.GUID; Title = $_.Title; Url = $_.Url } })
    Write-FileAtomic $recheckList (ConvertTo-Json -InputObject @([ordered]@{ Name = 'Retired'; List = $list }) -Depth 5)
    $search = $SearchArguments.Clone()
    foreach ($name in 'Catalog', 'ReportPath', 'ResultsPath', 'MetricsPath', 'Title', 'ReplaceOnlyDead', 'WhatIf') { $search.Remove($name) }
    $null = & (Join-Path $PSScriptRoot 'Update-StationUrls.ps1') -Catalog $recheckList -ResultsPath $recheckResults @search -WhatIf:$false 6>$null
    $answers = @(Get-Content $recheckResults -Raw -Encoding utf8 | ConvertFrom-Json | Where-Object { $_ })
    Remove-Item -Recurse -Force $scratch -WhatIf:$false
    $urls = @($stations | ForEach-Object { $_.Url })
    foreach ($entry in $due) {
        $answer = $answers | Where-Object Guid -eq $entry.GUID
        # Not among the failures: the old url played in both probes. A NewUrl played in two probes too.
        $url = @($entry.Url, $answer.NewUrl)[[int][bool]$answer]
        $clash = $url -and ($urls | Where-Object { $_.Contains($url) -or $url.Contains($_) })
        $restored = $null
        if ($url -and -not $clash) {
            $block = @($entry.Block, "{`n        `"GUID`": $($entry.GUID | ConvertTo-Json),`n        `"Title`": $($entry.Title | ConvertTo-Json),`n        `"Url`": $($entry.Url | ConvertTo-Json)`n      }")[[int](-not $entry.Block)]
            $block = $block.Replace("`"Url`": $($entry.Url | ConvertTo-Json)", "`"Url`": $($url | ConvertTo-Json)")
            $restored = Add-StationBlock $text $block $entry.After $entry.Category
        }
        if ($restored) {
            $text = $restored
            $restoredNow.Add([pscustomobject]@{ Guid = $entry.GUID; Title = $entry.Title; Url = $url; Retired = $entry.Retired; Category = $entry.Category })
            $null = $retired.Remove($entry)
            continue
        }
        # A hand-added entry may lack these fields: they are set, not assumed.
        $checks = [int]$entry.Checks + 1
        $entry | Add-Member -NotePropertyName Checks -NotePropertyValue $checks -Force
        $entry | Add-Member -NotePropertyName LastChecked -NotePropertyValue $Date -Force
        $entry | Add-Member -NotePropertyName NextCheck -NotePropertyValue (Format-Day $today.AddDays($RecheckDays * ($checks + 1))) -Force
        $why = @('no url plays', "$url plays but another station has it, or its category is gone")[[int][bool]$url]
        $recheckedNow.Add([pscustomobject]@{ Title = $entry.Title; Checks = $entry.Checks; NextCheck = $entry.NextCheck; Why = $why })
    }
}

# The written list must be the old one without the retired stations and with the restored ones, nothing else.
$expected = @($stations | Where-Object { $retiredNow.GUID -notcontains $_.Guid } | ForEach-Object { $_.Guid }) + @($restoredNow | ForEach-Object { $_.Guid })
$written = @(Read-StationList $text | ForEach-Object { $_.Guid })
if (Compare-Object @($expected | Sort-Object) @($written | Sort-Object)) { throw 'The list after retiring and restoring is not the expected one; nothing was written.' }
if (($retiredNow.Count + $restoredNow.Count) -gt 0 -and $PSCmdlet.ShouldProcess($Catalog, "Retire $($retiredNow.Count), restore $($restoredNow.Count) station(s)")) {
    Write-FileAtomic $Catalog $text $hasBom
}
if ($PSCmdlet.ShouldProcess($RetiredPath, 'Write the retired stations')) {
    Write-FileAtomic $RetiredPath ((ConvertTo-Json -InputObject @($retired | Sort-Object Title) -Depth 4) + "`n")
    New-Item -ItemType Directory -Force -Path (Split-Path $StatePath -Parent) | Out-Null
    Write-FileAtomic $StatePath (($state | ConvertTo-Json -Depth 4) + "`n")
}

# The report.
$failingNow = @($state.Keys | ForEach-Object {
    [pscustomobject]@{ Title = $state[$_].Title; Since = $state[$_].FirstFailed; Days = [int]($today - (Read-Day $state[$_].FirstFailed)).TotalDays }
} | Sort-Object Days -Descending)
$lines = [Collections.Generic.List[string]]::new()
if ($mass) {
    $lines.Add('## No station retired or rechecked: too many failed at once')
    $lines.Add('')
    $lines.Add("$($results.Count) of $Probed stations failed, more than $([Math]::Round(100 * $MassFailureRatio))%: a source or the network is the problem, not the stations. The failing days are not counted for this run.")
    $lines.Add('')
}
if ($retiredNow.Count) {
    $lines.Add("## Retired (dead, with no replacement anywhere, for $RetireAfterDays days)")
    $lines.Add('')
    $lines.Add('| Station | Last url | Failing since | Next check |')
    $lines.Add('| :--- | :--- | :--- | :--- |')
    foreach ($entry in $retiredNow) { $lines.Add("| $($entry.Title) | ``$($entry.Url)`` | $($entry.FirstFailed) | $($entry.NextCheck) |") }
    $lines.Add('')
}
if ($restoredNow.Count) {
    $lines.Add('## Restored (retired, and playing again)')
    $lines.Add('')
    $lines.Add('| Station | Url | Retired on |')
    $lines.Add('| :--- | :--- | :--- |')
    foreach ($entry in $restoredNow) { $lines.Add("| $($entry.Title) | ``$($entry.Url)`` | $($entry.Retired) |") }
    $lines.Add('')
}
if ($recheckedNow.Count) {
    $lines.Add('## Retired stations rechecked, still gone')
    $lines.Add('')
    $lines.Add('| Station | Checks | Next check | Why |')
    $lines.Add('| :--- | ---: | :--- | :--- |')
    foreach ($entry in $recheckedNow) { $lines.Add("| $($entry.Title) | $($entry.Checks) | $($entry.NextCheck) | $($entry.Why) |") }
    $lines.Add('')
}
if ($failingNow -or $kept.Count) {
    $lines.Add("## Failing, retired after $RetireAfterDays days")
    $lines.Add('')
    $lines.Add('| Station | Failing since | Days |')
    $lines.Add('| :--- | :--- | ---: |')
    foreach ($item in $failingNow) { $lines.Add("| $($item.Title) | $($item.Since) | $($item.Days) |") }
    foreach ($item in $kept) { $lines.Add("| $item | | |") }
    $lines.Add('')
}
$report = $lines -join "`n"
if ($ReportPath) { Set-Content -Path $ReportPath -Value $report -Encoding utf8 -WhatIf:$false }
Write-Information $report -InformationAction Continue
[pscustomobject]@{
    Retired     = @($retiredNow)
    Restored    = @($restoredNow)
    Rechecked   = @($recheckedNow)
    Failing     = $failingNow
    MassFailure = $mass
}
