# Cast receiver layout, 2026-11-13

The receiver page (`receiver/index.html`) uses the TV's space better (owner's review of the first render).

## What changed

- **The cover is the screen's picture.** It takes the safe area's full height on the left: 90 % of the height
  without captions and 70 % with them, and never more than half the width.
- **The station's logo is big, beside the cover.** It heads the song's column (22 % of the screen's smaller side), and
  its top is level with the cover's top at every size.
- **No cover for the song.** The station's logo takes the cover's place, whole, on white, and is not shown twice.
- **Bigger text.**
  - The title is 11 % of the smaller side, clamped at two lines.
  - The artist is 7 %.
  - The album and year share one line ("Deliria · 2015") at 5.5 %.
  - The captions are 4.6 %, on a band as wide as the safe area.
- **Upright displays stack it.** The cover is on top, with the logo and the song under it.

## Checked

At 1024 x 600 (Nest Hub), 1280 x 720, 1280 x 800, 1920 x 1080, 800 x 1280 and 720 x 1280 it was checked with a
one-line and a two-line title, without captions and with a two-line caption:

- no element overlaps another;
- nothing is cut off;
- everything stays inside the 5 % safe area;
- in landscape, the logo's top is level with the cover's top.
