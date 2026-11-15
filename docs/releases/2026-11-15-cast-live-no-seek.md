# No time bar on the cast receiver, 2026-11-15

A radio station is live, so the cast receiver no longer offers seeking. A touch display (Pixel Tablet) drew a
progress / time bar in its system media bar that could not move a live stream. The RoRadio app has no time bar
either.

## What changed

- **No SEEK.** The receiver declares pause, volume and mute, plus previous / next for a station that has them
  (`options.supportedCommands` at start, `setSupportedMediaCommands` on every station). SEEK, the framework's
  default, is never declared.
- **Always LIVE.** A LOAD is made `streamType: LIVE` with no `duration`, whatever the sender sent, and a media
  status reports no `liveSeekableRange`. The app's senders (Windows and Android, both through Sharpcaster) already
  send LIVE with no duration.
- Previous / pause / next on the device's media bar work as before.

## Checked

- `tests/receiver.browser.test.js` (real Cast framework in headless Chrome):
  - The receiver starts without SEEK and keeps pause and the volume; a station with steps adds exactly previous /
    next, never SEEK.
  - A BUFFERED LOAD with a duration comes out LIVE without one; a status loses its seekable range.
- `tests/receiver.test.js`: the declared commands no longer include SEEK.
- `scripts/e2e/Test-ReceiverOnTablet.ps1` on the Pixel Tablet and the Google TV Streamer.
