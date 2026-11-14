# Cast receiver: the year on its own line, one logo on the splash, 2026-11-14

Two changes the owner asked for on the cast screen. Merge this before RoRadio 2.4.5 ships.

## What changed

- **The year on its own line.** The release year now shows alone, under the album, instead of on the album's line
  ("Test album · 2025"). It joins the album's line again only when the song's column has no room for one more
  line. The title, artist and album keep their two-line fitting, and nothing goes under the system bar. With no
  album, the year is that line on its own. The fitting moved to `receiver/fit.js`.
- **One logo on the splash.** The "RoRadio" wordmark is gone. The idle screen shows only the app's icon. The icon
  is the page's heading, with the alt text "RoRadio", so the screen still has a named heading for screen readers.

## Checked

- `tests/receiver.test.js`:
  - The year is on its own line while there is room.
  - It joins the album's line when the column is full.
  - With no album, the year is that line on its own.
  - Coverage of all five scripts is 100 %.
- `tests/receiver.browser.test.js`, real framework, at 1920 x 1080, 2560 x 1600 and 1280 x 720:
  - The year is on its own line for a short song.
  - It joins the album's line only when space is tight.
  - Nothing overlaps or goes under the bar, and size, contrast and axe checks pass.
  - The splash has one image, no wordmark, and its icon is named "RoRadio".
