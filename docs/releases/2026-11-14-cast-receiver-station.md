# Cast receiver station name and logo, 2026-11-14

The receiver page (`receiver/index.html`) names the station and shows its logo beside the song's cover (owner,
2026-11-14). Merge this before RoRadio 2.4.5 ships.

## What changed

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
