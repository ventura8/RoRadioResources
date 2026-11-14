# Cast receiver: every previous / next press steps, 2026-11-14

On the Pixel Tablet one press of the system bar's previous or next stepped, and every later press did nothing.
Merge this before RoRadio 2.4.5 ships.

## What changed

- **Cause.** The tablet's own media bar sends each press as a queue jump with the same sender and request id
  every time. The page remembered each request id forever to drop a resent jump (#36), so it took every later
  press for a resend of the first. The on-device test showed it: previous stepped when it was the first press, and
  previous, next or a second previous after another press gave nothing.
- **Fix.** A resend is the same sender, request id and direction, within 1.5 s of the last time it was seen. Each
  resend starts that time again, so a controller that keeps resending still steps once. An id of 0 (or none) never
  marks a resend. Next, then previous a moment later, is two presses (Greptile, #43). Two presses within 600 ms are
  still one press.
- **Two lines for the title, the artist and the album** (owner). Each takes up to two lines. A text that needs
  more shrinks in steps, down to 24 px at 1080p, before its second line ends in an ellipsis. When the three
  together pass the station's line at the bottom of the song's column, all three shrink a step more. They are
  fitted again once the logo has loaded and when the screen's size changes. A short text stays on one line at
  full size. The fixed layout stays: nothing moves between states, and nothing goes under the system bar.
- The logo darkness measure moved to its own file, `receiver/logo-tone.js`, loaded before `receiver.js`.
  Coverage of both is gated at 100 %.
- Each step's media status names the request it came by (`via`). In test mode (`"rects": true`) a press the page
  took for a repeat is reported too (`skipped`). Apps read only `step` and `stepId`.

## Checked

- `tests/receiver.test.js`:
  - The bar's presses with one request id all step: next, previous 2 s later, next 0.8 s after.
  - The same direction 2 s apart is two presses.
  - Seven resends 0.7 s apart step once.
  - Request id 0 never dedupes.
  - Test mode reports what it dropped.
- `tests/receiver.browser.test.js` (real framework): next, previous 1 s later and next 2 s later, with one request
  id, all step.
- `scripts/e2e/Test-ReceiverOnTablet.ps1`: next, previous and next again on the tablet's bar, each exactly one step.
