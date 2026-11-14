# Cast receiver tested with the real framework, 2026-11-14

A broken receiver page can no longer merge. #33 crashed the page on load with "Unknown message type - QUEUE_NEXT",
thrown by Google's own Cast receiver framework before `context.start()`. The stub-based tests passed anyway, because
the stubs only knew what we had told them.

## What changed

- **`tests/receiver.browser.test.js`.** It loads `receiver/index.html` in headless Chrome with the real framework
  (`cast_receiver_framework.js` from gstatic.com, as a device loads it). Node's own test runner, HTTP server and
  WebSocket drive Chrome over the DevTools protocol, so there is nothing to install. The page is served unchanged. One
  probe script after the framework's tag records what the page asks of the real context and player, and passes every
  call on to the framework.
- **What it checks.** The page loads with no uncaught error and no console error from our script. It reaches
  `context.start()` and registers its LOAD and QUEUE_UPDATE interceptors on the real framework without an error. Then
  it checks the page's behaviour:
  - the idle screen before a cast and after `MEDIA_FINISHED`;
  - a LOAD with the old bare-string caption;
  - the JSON `customData` `{caption, previous, next, station, logo}` and the steps it declares;
  - the station's name and logo with and without a cover;
  - previous / next jumps broadcast `{step, stepId}` with rising ids;
  - a song change during playback replaces the title, artist, album, year, cover and backdrop, never leaving the old
    ones;
  - a station switch clears the old song.
- **Proved against #33.** With the `QUEUE_NEXT` interceptor put back, the test fails with the device's own error,
  "Unknown message type - QUEUE_NEXT".
- CI's test job already runs every `tests/*.test.js`; `ubuntu-latest` has Google Chrome. Locally, Chrome comes from
  `CHROME_PATH` or its usual install path.
