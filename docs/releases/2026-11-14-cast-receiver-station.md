# Cast receiver station name and logo, 2026-11-14

The receiver page (`receiver/index.html`) names the station and shows its logo beside the song's cover (owner,
2026-11-14). Merge this before RoRadio 2.4.5 ships.

## What changed

- **The page starts again (the cause of "Default Media Receiver" on the Pixel Tablet).** Since the previous / next
  change (#33), the page set an interceptor for `QUEUE_NEXT` / `QUEUE_PREV`. The framework names those types but throws
  "Unknown message type - QUEUE_NEXT" for an interceptor. The script stopped before `context.start()`, so the page never
  answered the app's launch. After 30 s the app gave up and launched Google's Default Media Receiver, whose own screen
  says "Default Media Receiver" top left. The tablet's log showed it: F38F9694 loaded at 17:38:14, never connected, and
  was replaced by CC1AD845 at 17:38:44. The device's previous / next still arrive as a `QUEUE_UPDATE` jump, which the
  page already handles.

- **The station's name beside its logo.** The item's `customData` may carry `"station"`, the station's name. The page
  shows it next to the logo. When the app sends no name, the page shows nothing there, never a placeholder.
- **The logo with the cover.** The `customData` may carry `"logo"`, the station logo's url. The page shows it beside the
  song's cover even when the item's images hold the cover alone. A logo that is already the cover (a song with no
  cover) is not shown twice.
- Both fields are optional: `{"caption", "previous", "next"}` and a plain-string caption from older app builds still
  work as before.

## Checked

- `tests/receiver.test.js`: the name from the app and none without it, the logo from the images or from the
  `customData`, and no second logo when it is already the cover.
- On the Pixel Tablet, once GitHub Pages serves it: cast a station whose song has a cover; the logo and the station's
  name show beside it.
