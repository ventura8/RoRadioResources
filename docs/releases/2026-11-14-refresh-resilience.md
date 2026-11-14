# Weekly refresh: retires gone stations, recovers by itself, reports to Sentry, 2026-11-14

The weekly refresh now looks after itself. It retires stations that are gone, restores them when they come back,
handles its own failures, reports to Sentry and records metrics to improve its sources. The station list itself does
not change in this release. `RetiredStations.json` starts empty and is ready for stations retired by hand.

## Retired stations

- **Retiring.** A station that is dead, and for which no source finds anything, in every run for 30 days leaves
  `RadioStationsData.json`. It goes to `RetiredStations.json` with its block, category, place, last url and logo,
  dates and evidence.
- **Rechecking and restoring.** Retired stations are rechecked 30 days after retirement, then 60, then 90, then 120.
  A url that plays in two probes restores the station to its old place.
- **Mass failures.** Nothing is retired or rechecked in a run where more than 10% of the stations fail.
- **App side.** RoRadio 2.x, 1.x and the Uno app keep the GUID of a removed favorite and of the last station, so a
  restored station is a favorite again. None of them crash when the station is missing.

## Failures it handles by itself

- Sources: a source that is down or rate-limited is retried, and is named in the report.
- GitHub: API calls are retried, and an expired `REFRESH_TOKEN` falls back to the workflow token.
- The pull request: a master that moved is rebased onto, a stale refresh pull request is closed, and the refresh's own
  failing CI is reported.
- Bad runs: a corrupt station list or a blocked network writes nothing, every write is atomic, and a failed run is
  retried every day until one succeeds.

## Sentry and metrics

- **Sentry:** every failure goes to the Sentry project `roradioresources-updater`, tagged with the run, the stage,
  the station and the source. Tokens are removed from every event.
- **Metrics:** one JSON line per run goes to the `refresh-data` branch. The tracking issue shows the trend. The
  strong sources are tried in the order of their hit rate.

## Checked

- `tests/Resilience.E2E.Tests.ps1` covers:
  - a station failing for less than 30 days, which is kept;
  - retirement at 30 days;
  - rechecks at 30, 60 and 90 days;
  - restoration from the old url or a new one;
  - a mass failure, a blocked network and a corrupt list;
  - the data branch race, the token fallback, Sentry events and the daily retry.
- `tests/Refresh.E2E.Tests.ps1` covers the pull request flow: a master that moved, a stale pull request, failing CI,
  and an API that fails once.
- The refresh's PowerShell is covered at 100% (2188 commands), and its Python at 100%.
