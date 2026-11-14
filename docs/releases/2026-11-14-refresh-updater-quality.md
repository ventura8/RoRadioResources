# Weekly refresh: tested end to end, 100% coverage, nothing left silent, 2026-11-14

The weekly refresh (`refresh-stations.yml`) finds broken stream urls, finds their current ones, verifies them and
merges the fix itself. This change makes it prove that, and stops it hiding what it could not do. The station list
itself does not change.

## Problems found and fixed

- **Stations it could not fix stayed dead for weeks, unseen.** The unresolved and "needs review" stations were
  written only into the run's summary. Atlas FM, Hot 107.1 FM, Radio Intexfm, Radio SOS, Radio Traditional, Radio
  Tradiţional Popular and Sláger Rádió were reported unresolved on 2026-10-19, 10-26, 11-02 and 11-09, and nobody
  looked. The 11-02 run left 24 stations, fixed none and opened nothing. Every run now rewrites the issue "Stations
  the weekly refresh could not fix", and the first run that leaves nothing closes it.
- **A source that was down looked like "no candidate".** When myradioonline.ro, radio-browser.info or the Shoutcast
  directory could not be read, every station was simply listed unresolved. The report now has a "Sources that could
  not be read" section.
- **The candidate order was lost.** `Group-Object` sorts by url. Candidates were tried in url order instead of
  source order (myradioonline.ro, then radio-browser.info, then the old server), in both the url and the logo
  refresh.
- **One probe was enough to write a url.** A stream that answered once and then failed could be written. The chosen
  candidate is now probed a second time first.
- **Two stations could be given the same new stream in one run.** That would fail the list's tests and the whole
  run. A url taken by an earlier station in the run is now dropped.
- **An HLS playlist without a segment counted as alive.** An empty playlist, or playlists nested deeper than two
  levels, are now `no-audio`.
- **Nothing checked the written list as a whole.** It must now be the same stations, in the same order, with only
  the verified urls changed. Otherwise nothing is written.
- **Dry runs left temporary files behind.** Under `-WhatIf`, the download helpers skipped deleting their scratch
  files.
- **A relative note path was resolved against the process's start folder.** `New-RefreshNote.ps1` now uses
  PowerShell's location.
- The pull request and merge logic moved from inline bash to `scripts/Publish-Refresh.ps1`, so it can be tested.
  Every git and gh command in it is checked.

## New

- **End-to-end tests** (`tests/Refresh.E2E.Tests.ps1`): the real scripts run against `tests/e2e/fake_station_server.py`
  on 127.0.0.1, with a fake GitHub CLI and a real git remote. They cover:
  - streams that work, are dead, moved or flaky, or answer with ICY, HLS or a redirect;
  - the source pages the refresh scrapes, and logos.
- **100% coverage** of the refresh's PowerShell (Pester code coverage) and Python (`pytest --cov-fail-under=100`).
  `scripts/ci/Invoke-Tests.ps1` fails below it.
- **Dry run against the live list:** the workflow's `dry_run` input, or
  `./scripts/Update-StationUrls.ps1 -ReplaceOnlyDead -WhatIf`.
- The tests open loopback addresses with `RORADIO_REFRESH_ALLOW_LOOPBACK=1`. Private networks and the metadata
  address stay refused, and no workflow sets it.
