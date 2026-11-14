# Weekly refresh: retires gone stations, recovers by itself, reports to Sentry, 2026-11-14

The weekly refresh now looks after itself. It retires stations that are gone, restores them when they come back,
handles its own failures, reports to Sentry and records metrics to improve its sources.

The station list itself does not change. `RetiredStations.json` takes the four stations removed by hand in #42:
Atlas FM, Hot 107.1 FM, Radio Amma and Radio Intexfm. Their first recheck is on 2026-12-14.

## Retired stations

- **Retiring.** A station leaves `RadioStationsData.json` after 30 counted days of being dead with every source read
  and nothing found. It goes to `RetiredStations.json` with its block, category, place, last url, logo, dates and
  evidence.
- **Days that are not counted.** A run where a source could not be read for the station, or where too many stations
  fail at once, pauses the count instead of adding to it.
- **Logos.** The logo file stays, for when the station comes back.
- **Rechecking.** Retired stations are rechecked 30 days after retirement, then 60, then 90, then 120. A failed
  recheck is published too, so the next one waits.
- **Restoring.** A url that played in two probes restores the station. It goes after the station it followed while
  that one is in the same category, otherwise first in its category.
- **Mass failures.** Nothing is retired or rechecked in a run where more than 10% of the stations fail.
- **App side.** RoRadio 2.x, 1.x and the Uno app keep the GUID of a removed favorite and of the last station, so a
  restored station is a favorite again. None of them crash when the station is missing.

## Failures it handles by itself

- **Sources:** a source that is down or rate-limited is retried, and is named in the report.
- **GitHub:** API calls are retried, and an expired `REFRESH_TOKEN` falls back to the workflow token.
- **The pull request:**
  - a master that moved is rebased onto;
  - a stale refresh pull request is closed;
  - the refresh's own failing CI is reported.
- **Bad runs:** a corrupt station list (or a GUID twice) or a blocked network writes nothing, and every write is
  atomic. A failed run is retried every day until one succeeds, judged by the recorded runs.

## Sentry and metrics

- **Sentry:** every failure goes to the Sentry project `roradioresources-updater`, the retry check's included. Events
  are tagged with the run, the stage, the station and the source. Tokens are removed from every event.
- **Metrics:**
  - one JSON line per run goes to the `refresh-data` branch: failed runs too, with their stage and reason, and every
    stage's time;
  - the retries of every script are counted;
  - two runs racing keep both lines;
  - the tracking issue shows the trend, and the strong sources are tried in the order of their hit rate.

## Checked

- `tests/Resilience.E2E.Tests.ps1` covers:
  - retirement: a station failing for less than 30 days (kept), retirement at 30 days, outage days skipped, an
    incomplete search not counted;
  - rechecks at 30, 60 and 90 days;
  - restoration: from the old url or a new one, only on two probes, and its place;
  - bad runs: a mass failure, a blocked network, a corrupt list, a duplicate GUID;
  - the data branch: a race with both metrics lines kept, and failed runs recorded;
  - the token fallback, Sentry events, and the daily retry.
- `tests/Refresh.E2E.Tests.ps1` covers the pull request flow: a master that moved, a stale pull request, failing CI,
  and an API that fails once.
- The refresh's PowerShell is covered at 100% (2346 commands), and its Python at 100%.
