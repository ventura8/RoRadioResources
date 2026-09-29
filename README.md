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

What the manual revival of 2026-09-29 (137 failing stations, two rounds) taught, beyond what the scripts do:

- Old Shoutcast 1 servers answer `ICY 200 OK`; current curl reads that only with `--http0.9`. The probe retries
  that way since then - before, Pure Jazz Radio, Radio SasNet, Europa FM's old mount and the Radio Caprice
  channels were reported dead while they played.
- Where streams were found: the broadcaster's own player page (most), myradioonline.ro, the Shoutcast directory
  (`POST https://directory.shoutcast.com/Search/UpdateSearch`, then `yp.shoutcast.com/sbin/tunein-station.pls?id=`),
  the old server's status page (Radio Transilvania moved every town to `stream2.radiotransilvania.ro`), radio.garden
  (needs a browser User-Agent, `Accept: application/json` and its Referer), the TuneIn OPML API
  (`opml.radiotime.com/Search.ashx`, `Tune.ashx?id=`), Zeno's per-station API (`zeno.fm/api/stations/<slug>/`,
  field `streamURL`) and the Wayback Machine for a dead site's player config (https only; http is rate-limited).
  A bare-IP url names nobody: the Wayback index of that `host:port` (`web.archive.org/cdx/search/cdx?url=<ip:port>*`)
  usually has the old Shoutcast status page, which does (Radio RVE was RVE Suceava). The m3u playlists in
  `junguler/m3u-radio-music-playlists` on GitHub name old IP urls too; liveradious.com carries `data-stream-url`;
  an empty `streams` list from instant.audio (`api.instant.audio/data/streams/82/<slug>`) is a quick sign a station
  is gone. fmstream.org answers 429 after about five quick queries.
- A logo, a frequency, a town or the `icy-name` header ties a stream to the station; a name alone does not.
- About a third of the long-dead stations are gone for good (domain expired, 410 Gone, taken over by another
  station): those stay for the owner to remove, never deleted by a script.

## The weekly refresh

`refresh-stations.yml` (Mondays 04:17 UTC, or **Run workflow** by hand):

1. Probes every station, and the failures again a minute later, so a blip is not taken for a move.
2. For each station that failed twice, collects candidates and probes them:
   - **strong** (the first live one replaces the url): its page on [myradioonline.ro](https://myradioonline.ro/);
     radio-browser.info (same name, Romanian or Moldovan, homepage or stream host carrying the station's name);
     the old server's own status page (Icecast `status-json.xsl`, Shoutcast `statistics?json=1`, on the old port
     and on 8000), mounts carrying the station's name - a station that moved its mount on the same server;
   - **weak** (a live one is only suggested, under "Needs review"): the Shoutcast directory (entries whose name
     contains the title; most Romanian manele web radios are listed only there) and radio.net (the exact name, in
     Romania or Moldova). A name is not proof: round one found same-name stations in Spain, Switzerland, a game.

   A station without a candidate keeps its url and is listed as unresolved.
3. Replaces only streams that are **dead** (no connection at all). The runners are in the United States: an HTTP
   error or a non-audio answer from there can be Romanian geo-blocking, not a moved stream (the first run, on
   2026-09-29, got HTTP 404 from Europa FM, which plays fine in Romania). Those stations are listed under "Needs
   review from Romania" with the candidate it found; check them with
   `./scripts/Update-StationUrls.ps1 -Title '<station>'` from here.
4. Commits the changed urls to `automation/station-refresh`, opens (or updates) a pull request whose body is the
   report, squash-merges it, and asks Pages to rebuild.

It does **not** merge when more than 15 urls changed at once: a wave of that size is more likely the runner's
network than fifteen stations moving in one week. That pull request stays open for someone to check from Romania.
