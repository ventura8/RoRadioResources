# RoRadioResources

The station list of [RoRadio](https://github.com/ventura8/RoRadio), in one place.

| File | What it is |
| :--- | :--- |
| `RadioStationsData.json` | Every station: categories, and for each station its `GUID`, `Title`, `Url`, `ImageUrl`, `Description`. UTF-8 with BOM, LF (CRLF in a Windows checkout with `core.autocrlf`). |
| `RadioLogos/` | The station logos, one file per `ImageUrl` (the name exactly, case included: Pages is case-sensitive). PNG preferred, at most 400 px on the longest side, a few tens of KB. |
| `scripts/Test-StationStreams.ps1` | Probes the streams and says which are `alive`, `dead`, `http-NNN` or `no-audio`. |
| `scripts/Update-StationUrls.ps1` | Finds a verified current url for every broken station and writes it into the list. |
| `scripts/Update-StationLogos.ps1` | Finds a logo for every station without one, checks it and adds it to `RadioLogos/` and the list. |
| `scripts/New-RefreshNote.ps1` | Writes a weekly refresh's release note from the two reports. |
| `scripts/lib/` | What the scripts share: checked and pinned requests (`Net.ps1`), name matching (`Names.ps1`), the logo check (`normalize_logo.py`, Pillow). |
| `docs/releases/` | One release note per change to the list: what changed, where each url or logo was found, the logos themselves. |
| `tests/` | The list's integrity and the scripts' helpers (Pester), the logo check (Python `unittest`). |
| `.github/workflows/ci.yml` | Every linter and every test on each pull request and push to `master`. |
| `.github/workflows/refresh-stations.yml` | Runs the refresh every Monday, opens a pull request with the release note and merges it. |

## Who reads the list

- **Every running RoRadio app**, first: GitHub Pages serves this repository's `master`, so the app downloads
  `https://ventura8.github.io/RoRadioResources/RadioStationsData.json`. A change pushed here reaches listeners
  within minutes, without an app release.
- **The app's offline copy**: RoRadio includes this repository as the git submodule `RoRadioResources/` on both
  release lines (2.x on `master`, 1.x on `release/1.x`) and bundles this file. A new submodule pointer ships with
  the next app release.
- **The logos** work the same way: the apps bundle `RadioLogos/` from the submodule, and a logo their package does
  not have yet (added or replaced here after the release) is loaded from
  `https://ventura8.github.io/RoRadioResources/RadioLogos/<ImageUrl>`. Apps older than that change (2.0.1, 1.6.x)
  only know their bundled logos: a station given a new `ImageUrl` shows no logo there until they update, so an
  existing logo is replaced in place (same file name) when it only needs refreshing.

## Rules for editing the list

- A station's `GUID` never changes: listeners' favorites refer to it. Fix a station by changing its `Url`.
- GUIDs, titles and urls are unique, and no url contains another one (`tests/Catalogue.Tests.ps1` fails otherwise;
  the apps find a station by its title and favor one entry per stream).
- Never write a url that `Test-StationStreams.ps1` has not reported `alive`.
- Every change to the list gets a release note in `docs/releases/` (`<date>-<subject>.md`): what changed and why,
  where each url or logo was found, with the logos shown. The pull request's body is the same text.
- A station with no working stream anywhere is not deleted automatically: removing it drops it from listeners'
  favorites, so that is the owner's decision.
- Keep the encoding (UTF-8 with BOM) and the line endings, so a fix is a one-line diff.

## Checking and refreshing by hand

```powershell
./scripts/Test-StationStreams.ps1 | Where-Object Verdict -ne 'alive' | Format-Table
./scripts/Test-StationStreams.ps1 -Title 'Europa FM', 'Radio Zu'
./scripts/Update-StationUrls.ps1 -WhatIf        # report only
./scripts/Update-StationUrls.ps1 -ReportPath report.md
./scripts/Update-StationLogos.ps1 -WhatIf -ReportPath logos.md
```

They need PowerShell 7 and curl; the logo script also Python 3 with Pillow (`python -m pip install -r scripts/ci/requirements.txt`).

## Checks (CI and local)

`.github/workflows/ci.yml` runs on every pull request and every push to `master`, through the same two scripts a
developer runs:

```powershell
./scripts/ci/Invoke-Lint.ps1    # every linter at its strictest, no inline suppressions
./scripts/ci/Invoke-Tests.ps1   # the list's integrity, the helpers, the logo check
```

The linters are PSScriptAnalyzer (every rule, every severity), ruff (every rule, lint and format), yamllint
(strict), actionlint, zizmor, markdownlint, cspell, editorconfig-checker and gitleaks (working tree and history).
A finding is fixed in the file; a comment or attribute that silences a linter fails the run. Two paths are left
out of spelling on purpose: `RadioStationsData.json` and `docs/releases/` are station names, not English.

One-time setup: `python -m pip install -r scripts/ci/requirements.txt`, `npm ci --prefix scripts/ci`,
`Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser`,
`Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -SkipPublisherCheck`, and actionlint and
gitleaks (`winget install rhysd.actionlint Gitleaks.Gitleaks`). Dependabot proposes updates to the pinned
versions. A pull request the weekly workflow opens starts no CI (GitHub's rule for its own token), so the workflow
runs the tests itself before it commits.

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
4. Finds a logo for each station without one (`Update-StationLogos.ps1`), when the repository variable
   `REFRESH_LOGOS` is `true`: from radio-browser.info (the entry with the station's stream, or its name in Romania
   or Moldova with the station's name in its host), the icons its homepage declares, and myradioonline.ro (only
   when that page plays from the station's own host; otherwise a suggestion). A logo must be an image of at least
   128 px, logo-shaped and not blank; the same image for several stations is a placeholder and is not used. It is
   written as `<slug>.png`, at most 400 px. An existing logo is never replaced or renamed by the workflow.
5. Runs the tests (`scripts/ci/Invoke-Tests.ps1`), writes the release note `docs/releases/<date>-refresh.md`,
   commits the list, the logos and the note to `automation/station-refresh`, opens (or updates) a pull request
   whose body is the note (logos shown from that commit), squash-merges it, and asks Pages to rebuild.

It does **not** merge when more than 15 urls or 20 logos changed at once: a wave of urls that size is more likely
the runner's network than fifteen stations moving in one week, and that many logos is worth a look first. That
pull request stays open for someone to check.

**`REFRESH_LOGOS` stays unset until the app releases that load logos from Pages are out** (RoRadio after 2.0.1 on
Windows, after 1.6.x on Xbox). The released apps look for a logo only in their own package: a station that gets a
new logo file shows an empty tile there instead of the default icon. Once those releases have reached listeners,
set it under Settings > Secrets and variables > Actions > Variables.
