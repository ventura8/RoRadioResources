# Cast receiver on touch displays, and a real splash, 2026-11-14

The receiver page (`receiver/index.html`) shows itself on a Pixel Tablet or a Nest Hub, with buttons to tap, and its
idle screen carries the app's icon. Merge this before RoRadio 2.4.5 ships.

## What changed

- **The page, not Google's default audio UI, on a touch display.** The page played through Google's
  `cast-media-player` element. On a touch display that element draws its own audio UI over the page ("RoRadio", the
  cover, the item's title and artist, previous / pause / next), so the station's logo and name never showed. The page
  now plays through its own `<audio>` element (`player.setMediaElement`) and declares
  `uiConfig.touchScreenOptimizedApp`, as Google's smart display guide asks of a receiver with its own UI.
- **Previous, pause and next to tap.** On a device that reports touch input, the song column ends with three buttons.
  Previous / next send the same step to the app as the device's own buttons, and show only for a step the station has.
  Pause pauses or plays the stream and shows which a tap does.
- **A splash with the app's icon.** The idle screen shows the RoRadio icon (`receiver/icon.png`, the app's 256 px
  unplated icon) on a tile, the name, "Ready to play" and a short line, over a soft accent glow. It is sized for a
  1920 x 1080 TV and a 2560 x 1600 tablet alike.

- **One press is one step.** One tap on the Pixel Tablet's next went from Pro FM to Radio 7, seven stations on.
  The device's controller sends again a queue jump it got no answer to, and every repeat broadcast a new step. The
  page now takes a jump with a request id it has seen (sender and id) as the same press, and any step within 600 ms
  of the last as the same press too. The touch buttons go through the same check.
- **The logo beside the cover.** With a song's cover, the station's logo shows beside it, from the item's second
  image or the `customData` `logo`.
- **The screen, reported.** Every media status the page sends carries `{"shown": {"artist", "caption", "cover",
  "defaultTitle", "logo", "station", "steps": {"next", "previous"}, "title"}}`, updated on every change and once
  a picture has loaded. An E2E test reads what the screen shows without OCR. A step press keeps its `step` and
  `stepId` beside it, so older apps still read the press.
- **Merged with the security audit (#37).** `imageUrl()` (http(s) only, normalized through `new URL().href`) lives
  in `receiver.js` and guards the cover, the logo and the backdrop. The CSP allows `'self'` (receiver.js) instead
  of the inline script's hash, with `default-src 'none'` and no `unsafe-eval` or `unsafe-inline` for scripts.
- **A failed stream says so.** When the stream fails (`MEDIA_FINISHED` with `ERROR`, or the player's `ERROR`), the
  idle screen comes back and says the station's stream could not be played. The next station clears it.
- **The script is its own file, at 100 % coverage.** `receiver/receiver.js` holds the whole script. The unit tests
  load it with `require`, and `Invoke-Tests.ps1` fails below 100 % line, branch and function coverage.
- **Strict lint of the receiver.** ESLint (`eslint:all` on the script), html-validate and stylelint, all pinned in
  `scripts/ci/package.json`. The suppression ban covers their disable comments too.
- **An on-device E2E.** `scripts/e2e/Test-ReceiverOnTablet.ps1` plays the flows on a Pixel Tablet over adb and Cast
  and saves a screenshot per step.

## Checked

- `tests/receiver.test.js`: the options declare the touch UI and the page's media element; the buttons show on touch
  only; taps step, pause and play; a step the station lacks hides its button.
- `tests/receiver.browser.test.js` (the real framework in Chrome): the icon is served and loads (no 404) and shows on
  the idle screen; the touch UI is declared and there is no `cast-media-player`.
- On the Pixel Tablet after the merge (owner): the page's own screen with the logo, the station's name and the song.
