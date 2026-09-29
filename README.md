# RoRadioResources

The station list of [RoRadio](https://github.com/ventura8/RoRadio), in one place.

| File | What it is |
| :--- | :--- |
| `RadioStationsData.json` | Every station: categories, and for each station its `GUID`, `Title`, `Url`, `ImageUrl`, `Description`. UTF-8 with BOM, LF (CRLF in a Windows checkout with `core.autocrlf`). |
| `scripts/Test-StationStreams.ps1` | Probes the streams and says which are `alive`, `dead`, `http-NNN` or `no-audio`. |
| `scripts/Update-StationUrls.ps1` | Finds a verified current url for every broken station and writes it into the list. |
| `.github/workflows/refresh-stations.yml` | Runs the refresh every Monday, opens a pull request with the report and merges it. |

## Who reads the list

- **Every running RoRadio app**, first: GitHub Pages serves this repository's `master`, so the app downloads
  `https://ventura8.github.io/RoRadioResources/RadioStationsData.json`. A change pushed here reaches listeners
  within minutes, without an app release.
- **The app's offline copy**: RoRadio includes this repository as the git submodule `RoRadioResources/` on both
  release lines (2.x on `master`, 1.x on `release/1.x`) and bundles this file. A new submodule pointer ships with
  the next app release.

## Rules for editing the list

- A station's `GUID` never changes: listeners' favorites refer to it. Fix a station by changing its `Url`.
- Never write a url that `Test-StationStreams.ps1` has not reported `alive`.
- A station with no working stream anywhere is not deleted automatically: removing it drops it from listeners'
  favorites, so that is the owner's decision.
- Keep the encoding (UTF-8 with BOM) and the line endings, so a fix is a one-line diff.

## Checking and refreshing by hand

```powershell
./scripts/Test-StationStreams.ps1 | Where-Object Verdict -ne 'alive' | Format-Table
./scripts/Test-StationStreams.ps1 -Title 'Europa FM', 'Radio Zu'
./scripts/Update-StationUrls.ps1 -WhatIf        # report only
./scripts/Update-StationUrls.ps1 -ReportPath report.md
```

Both need PowerShell 7 and curl.

## The weekly refresh

`refresh-stations.yml` (Mondays 04:17 UTC, or **Run workflow** by hand):

1. Probes every station, and the failures again a minute later, so a blip is not taken for a move.
2. For each station that failed twice, collects candidates from its page on
   [myradioonline.ro](https://myradioonline.ro/) and from radio-browser.info (exact name only), probes them,
   and takes the first one that is alive. A station without one keeps its url and is listed as unresolved.
3. Commits the changed urls to `automation/station-refresh`, opens (or updates) a pull request whose body is the
   report, squash-merges it, and asks Pages to rebuild.

It does **not** merge when more than 15 urls changed at once: the runners are in the United States, and a wave
of failures is more likely Romanian geo-blocking seen from there than fifteen stations moving in one week. That
pull request stays open for someone to check from Romania. Unresolved stations are in every run's summary.
