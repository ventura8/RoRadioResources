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

## Checked

- `tests/receiver.test.js`: the options declare the touch UI and the page's media element; the buttons show on touch
  only; taps step, pause and play; a step the station lacks hides its button.
- `tests/receiver.browser.test.js` (the real framework in Chrome): the icon is served and loads (no 404) and shows on
  the idle screen; the touch UI is declared and there is no `cast-media-player`.
- On the Pixel Tablet after the merge (owner): the page's own screen with the logo, the station's name and the song.
