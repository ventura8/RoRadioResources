# Transparent station logos, 2026-11-14

Every station logo now shows on the cast receiver's dark screen without a plate behind it, and dark logos stay
readable there. Merge this before RoRadio 2.4.5 ships.

## What changed

- **Pro FM's "OPEN RADIO".** The app sends the logo's GitHub Pages copy (`RadioLogos/Profm.png`), which was
  already transparent with white lettering. The white tile came from the receiver page, which drew logos on a white
  plate until #39. The receiver now draws every logo directly on its dark background, and "OPEN RADIO" shows white
  on dark, as in the app's list.
- **61 logos made transparent.** These logos had a solid background, a white or coloured plate filling their
  edges. `scripts/lib/transparent_logo.py` flood-fills that background from the edges and makes it see-through.
  The pixels along the mark's edge are un-blended from the background (colour to alpha), so an anti-aliased grey
  edge becomes the mark's colour at partial opacity, not an opaque outline. Colour inside the mark, such as white
  lettering, stays. Artwork that covers its square (52 logos, whose edges are not one colour) is left as it is.
  The 15 such logos that were JPEGs are now PNGs of the same name, and `RadioStationsData.json` points to them.
- **New logos too.** The weekly refresh (`normalize_logo.py`) makes a new logo's solid background transparent in
  the same way, so a refreshed logo passes the check below.
- **Older apps.** A 2.x app shows a logo its package does not bundle from GitHub Pages, so the renamed logos still
  show there. An app built before that fallback shows its own bundled copy until it updates.
- **Dark logos get a light glow.** The receiver measures each logo it shows: dark lettering on transparency, too
  dark for the dark screen, gets a white glow around its own shapes. There is still no plate behind it. The page
  reads the GitHub Pages copy through CORS; a picture from a host without CORS is shown as it is.

## Checked

- `tests/test_transparent_logo.py`:
  - A plate goes, and the mark and the white inside it stay.
  - Transparent logos and artwork are left alone.
  - A JPEG becomes a transparent PNG.
  - Every logo in `RadioLogos` has no solid background left.
  - The receiver's darkness measure uses the same constants as this test.
- `tests/receiver.test.js`: dark and light logos, a picture without CORS, a logo with nothing opaque, the logo in
  the cover's place, and a slow measure of an old logo.
- `tests/receiver.browser.test.js`, with the real canvas: 24house gets the glow, Pro FM does not, and neither has
  a plate.
