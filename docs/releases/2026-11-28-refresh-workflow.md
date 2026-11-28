# Weekly refresh fixed, 2026-11-28

The scheduled refresh (`.github/workflows/refresh-stations.yml`) failed on every run from 2026-11-24 to 2026-11-28.
It stopped in its search stage, before it published anything, so no broken stream url was replaced in those days.

## Cause

The search stage runs the repository's whole test suite. `tests/receiver.browser.test.js` loads axe-core from
`scripts/ci/node_modules`, but only the CI workflow ran `npm ci`. In the refresh the receiver tests stopped with
`ENOENT ... axe-core/axe.min.js`, and the run ended with "Python tests passed, receiver tests failed".

## Fix

- The refresh workflow installs the pinned npm packages exactly as CI does
  (`npm ci --prefix scripts/ci --ignore-scripts`, with no package lifecycle scripts).
- A regression test in `tests/Resilience.E2E.Tests.ps1` checks that the refresh installs the same Python tools and
  npm packages as CI.

The station list and the logos are unchanged.
