# Receiver: the cover theme keeps every text, and the blurred cover shows behind (2026-11-14)

- The cover colour theme never drops a text. The tablet run seemed to lose the album and the year with the theme on.
  The cause was the device E2E's theme step, which sent the song without them. The receiver showed what it got. The
  E2E now sends one song to the song step and both theme steps. A new step checks that theme on and off report the
  same text boxes, and the layout check now also runs on the theme-on screenshot. The browser suite checks that the
  same texts show with the theme on and off.
- The blurred cover behind the song is clear to see again. It had a 14vmin blur under an 80-92% tint, which looked like
  an even dark olive wash on the tablet. Now:
  - the blur is 3vmin;
  - the backdrop is no longer zoomed;
  - the default scrim is 64-78% dark;
  - with the theme on, the tint is a 30-45% layer over a neutral 52-68% dark one.

  The cover's colours and shapes now show through. The text's WCAG AA contrast is still measured on the real pixels,
  including over a white cover with the album shrunk to fit, at three sizes, with the theme off and on.
- The page's test report gives each drawn text's words, and leaves out a text hidden by visibility or a zero opacity.
  The E2E compares the words, so a year that leaves the album's line is caught.
