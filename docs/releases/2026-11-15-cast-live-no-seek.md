# No seeking on the cast receiver, 2026-11-15

A radio station is live, so the cast receiver no longer offers seeking. The RoRadio app has no time bar either.

The Pixel Tablet's system UI still draws its time bar and LIVE counter: the system draws them, and the receiver
cannot remove them. The bar moves nothing: before this change a drag across it did nothing, and now seeking is not
offered at all (the device's media session no longer lists seek). The Google TV Streamer shows no bar.

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
- `tests/receiver.test.js`: the declared commands no longer include SEEK; a status with media is made LIVE.
- `scripts/e2e/Test-ReceiverOnTablet.ps1` passed on the Pixel Tablet and the Google TV Streamer.
