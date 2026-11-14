# Cast receiver under the tablet's system bar, 2026-11-14

What the Pixel Tablet showed after #36, fixed. Merge this before RoRadio 2.4.5 ships.

## What changed

- **Nothing under the system media bar.** A touch display draws its own media bar over the bottom of the page
  (progress, LIVE, the output chip, previous / pause / next), from about 73 % of the height down, whatever the
  receiver declares. On a touch display the page now ends above it: the cover, the song, the captions and the
  idle screen keep out of the bottom 30 %, and the song's text is a size smaller there.
- **No buttons of the page's own.** The system bar already gives previous, pause and next, and its presses reach
  the page as queue jumps. The page's own buttons only duplicated them, and drew as broken glyphs, so they are gone.
- **No background behind the cover or the logo.** No tile, plate, card, fill or shadow: the pictures sit directly
  on the page, beside a cover and in the cover's place alike.
- **A fixed layout.** The song column is the cover's height. The song's text starts at the cover's top, and the
  station's logo and name end level with the cover's bottom, so nothing moves between a song and the station alone.
- **The station's name once.** With no song, the app sends the station's name as title and artist, and "Pro FM"
  showed three times. A field that is only the station's name is left out. A song's own fields may still repeat
  each other.
- **Test mode for the device E2E.** A sender that adds `"rects": true` to the item's `customData` gets each drawn
  box, its text colour, the pixel ratio and the viewport in the `shown` status.
- **Accessibility and layout suite.** Headless Chrome with the real framework checks every state (idle, error,
  loading, a song with a cover, the station alone, long texts) at 1920 x 1080, 2560 x 1600 (touch) and
  1280 x 720. It checks that no box overlaps another, that nothing is off screen, under the bar or cut without an
  ellipsis, that text is at least 24 px at 1080p and meets WCAG AA contrast against the real pixels, that axe-core
  finds no violation, and that controls are at least 48 px. The idle screen became a named region for axe.
- **The on-device E2E** (`scripts/e2e/Test-ReceiverOnTablet.ps1`):
  - It waits for the stream to play after a LOAD. The device can answer IDLE first, which failed the "load" step.
  - It taps the system bar by its position, since uiautomator sees only the web view, and checks exactly one step
    per press.
  - It checks overlaps and contrast on the tablet's own screenshot, using the test mode's boxes.
  - It reports a fallback only when the Default Media Receiver starts. Its id is in every Cast mDNS record and in
    the "App stopping" line of a receiver the launch replaced, which an earlier check took for a fallback.
- eslint stays at 10.14.0, with an npm override to minimatch 11.0.3 for its advisory; `npm audit` finds nothing.
