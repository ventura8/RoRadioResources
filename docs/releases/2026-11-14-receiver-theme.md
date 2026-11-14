# Cast receiver: a blurred backdrop, and the app's cover colours, 2026-11-14

The receiver's screen takes the song's cover as its background, and the app's opt-in cover colour theme when the
user has it on. Merge this before RoRadio 2.4.5 ships.

## What changed

- **The cover as the background.** The current cover is the full-screen background, very blurred, under the dark
  scrim. When there is no cover, the station's logo is used. Each song and station crossfades into the next
  (800 ms). Nothing sits behind the foreground pictures.
- **The app's cover colours.** When the user has the app's cover colour theme on, the app sends its own colours
  in the item's `customData`: `{"theme": {"accent": "#rrggbb", "tint": "#rrggbb"}}`. The accent comes from the
  cover. The tint is the app's window tint (`AppColorHelper.ReadableTint`), the colour white text reads on. The
  page's scrim takes the tint and its highlights take the accent. Anything but two `#rrggbb` colours is ignored.
  Without a theme, which is how every song arrives once the user switches it off, the page has its default look.
  `receiver/theme.js` does this.
- **What the screen shows, on request.** Every media status the page sends now carries `shown`, including the
  answer to a sender's `GET_STATUS`. So a test can read it at any time, from any session, and the app's own cast
  included (`scripts/e2e/cast-client.mjs … shown`). `shown.theme` names the colours on screen, or null.
- The test mode's layout report moved to `receiver/layout-report.js`.

## Checked

- `tests/receiver.test.js`:
  - The theme's colours go on the page and into the status.
  - Off, the page has its default look again.
  - Anything that is not two colours is ignored.
  - With no cover, the logo is the backdrop.
  - Every media status carries `shown`, and a step press keeps its own data.
  - Coverage of all four scripts is 100 %.
- `tests/receiver.browser.test.js` at 1920 x 1080, 2560 x 1600 and 1280 x 720, with the real framework:
  - The blurred backdrop follows the song, and then the station's logo.
  - The theme turns on, and then off.
  - Overlap, size and contrast checks pass on the real pixels over the backdrop and the themed scrim.
- `scripts/e2e/Test-ReceiverOnTablet.ps1`: the theme on and off on the tablet, read back from `shown`.
