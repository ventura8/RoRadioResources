# Cast receiver: every previous / next press steps, 2026-11-14

On the Pixel Tablet one press of the system bar's previous or next stepped, and every later press did nothing.
Merge this before RoRadio 2.4.5 ships.

## What changed

- **Cause.** The tablet's own media bar sends each press as a queue jump with the same sender and request id
  every time. The page remembered each request id forever to drop a resent jump (#36), so it took every later
  press for a resend of the first. The on-device test showed it: previous stepped when it was the first press, and
  previous, next or a second previous after another press gave nothing.
- **Fix.** A request id now marks a resend for 5 s only, and an id of 0 (or none) never does. Two presses within
  600 ms are still one press, so a resent or doubled jump steps once.
- Each step's media status names the request it came by (`via`). In test mode (`"rects": true`) a press the page
  took for a repeat is reported too (`skipped`). Apps read only `step` and `stepId`.

## Checked

- `tests/receiver.test.js`: the bar's presses with one request id, 6 to 7 s apart, all step. Request id 0 never
  dedupes. A resend within 5 s steps once. Test mode reports what it dropped.
- `tests/receiver.browser.test.js` (real framework): next, then previous 6 s later with the same request id, both
  step.
- `scripts/e2e/Test-ReceiverOnTablet.ps1`: next, previous and next again on the tablet's bar, each exactly one step.
