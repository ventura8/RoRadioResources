# Text-level edits of RadioStationsData.json (dot-sourced). The list keeps the format it has had since 2018, so a
# change is a few lines of diff: a station block is cut out or put back verbatim, never re-serialized. A station block
# is flat ({ "GUID", "Title", "Url", "ImageUrl", "Description" }: no nested braces), which is what the patterns rely on.

# The pattern of one station's block, found by its GUID.
function Get-StationBlockPattern([string]$Guid) {
    '\{[^{}]*"GUID"\s*:\s*"' + [regex]::Escape($Guid) + '"[^{}]*\}'
}

# The station's block as it is written in the list, or $null.
function Get-StationBlock([string]$Text, [string]$Guid) {
    $match = [regex]::Match($Text, (Get-StationBlockPattern $Guid))
    @($null, $match.Value)[[int]$match.Success]
}

# The list without the station's block (and the comma that joined it). $null when the station is not there.
function Get-ListWithoutStation([string]$Text, [string]$Guid) {
    $block = Get-StationBlockPattern $Guid
    # Followed by another station: the block, its comma and the line break up to the next block go. One block only:
    # a GUID found twice is a broken list, which the caller's check then refuses.
    $updated = [regex]::new($block + '\s*,\s*(?=\{)').Replace($Text, '', 1)
    # The last station of its category: the comma before it and the block go.
    if ($updated -eq $Text) { $updated = [regex]::new(',\s*' + $block).Replace($Text, '', 1) }
    @($null, $updated)[[int]($updated -ne $Text)]
}

# The list with $Block put back after the station $AfterGuid, or first in category $Category when there is no such
# station. $null when neither is there (the category itself is gone).
function Add-StationBlock([string]$Text, [string]$Block, [string]$AfterGuid, [string]$Category) {
    $newline = ("`n", "`r`n")[[int]$Text.Contains("`r`n")]
    $after = [regex]::Match($Text, '(?<indent>[ \t]*)' + (Get-StationBlockPattern $AfterGuid))
    # The station it followed counts only while it is still in the same category: one that moved elsewhere since is
    # no place for it (Greptile, #44); then it goes first in its own category.
    $neighbor = @(Read-StationList $Text | Where-Object Guid -eq $AfterGuid | Where-Object Category -eq $Category)
    if ($AfterGuid -and $after.Success -and $neighbor) {
        $end = $after.Index + $after.Length
        return $Text.Substring(0, $end) + ",$newline" + $after.Groups['indent'].Value + $Block + $Text.Substring($end)
    }

    $list = [regex]::Match($Text, '"Name"\s*:\s*' + [regex]::Escape(($Category | ConvertTo-Json)) + '\s*,\s*"List"\s*:\s*\[(?<space>\s*)')
    if (-not $list.Success) { return $null }
    $space = $list.Groups['space'].Value
    $end = $list.Index + $list.Length
    $Text.Substring(0, $end) + $Block + ",$space" + $Text.Substring($end)
}

# Throws unless $Text is the list of $Before (Read-StationList's stations) with only the urls of $Fixed
# ({ Guid, NewUrl }) changed: the same stations, titles and order.
function Assert-OnlyUrlChange([object[]]$Before, [string]$Text, [object[]]$Fixed) {
    $expected = @($Before | ForEach-Object {
        $guid = $_.Guid
        $fix = $Fixed | Where-Object Guid -eq $guid
        "$guid|$($_.Title)|$(@($_.Url, $fix.NewUrl)[[int][bool]$fix])"
    })
    $written = @(Read-StationList $Text | ForEach-Object { "$($_.Guid)|$($_.Title)|$($_.Url)" })
    if (Compare-Object $expected $written -SyncWindow 0) { throw 'The updated station list differs from the list with only the verified urls changed; nothing was written.' }
}

# The stations of a list as { Guid, Title, Url, Category, After } in order ($After: the station before it in its
# category, or ''). Throws when the text is not a station list: a list cut short or corrupt is never written.
function Read-StationList([string]$Text) {
    # ConvertFrom-Json accepts some text cut short ("[{...}" without its end); Test-Json does not.
    if (-not (Test-Json -Json $Text -ErrorAction SilentlyContinue)) { throw 'This is not a station list: it is not complete JSON (cut short?).' }
    $categories = @($Text | ConvertFrom-Json)
    if (-not $categories -or ($categories | Where-Object { -not $_.Name -or $null -eq $_.List })) {
        throw 'This is not a station list: every category needs a Name and a List.'
    }
    # A GUID twice is refused here, before any probing or editing (Greptile, #44).
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($category in $categories) {
        $previous = ''
        foreach ($station in $category.List) {
            if (-not $station.GUID -or -not $station.Url) { throw "A station of '$($category.Name)' has no GUID or no Url." }
            if (-not $seen.Add($station.GUID)) { throw "The GUID $($station.GUID) is in the list twice." }
            [pscustomobject]@{ Guid = $station.GUID; Title = $station.Title; Url = $station.Url; ImageUrl = $station.ImageUrl; Category = $category.Name; After = $previous }
            $previous = $station.GUID
        }
    }
}
