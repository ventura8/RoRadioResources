# Cast receiver previous and next, 2026-11-14

The receiver page (`receiver/index.html`) offers the app's previous and next station (owner, 2026-11-14: "on the
cast app can we also have back and forward buttons?"). It needs RoRadio 2.4.5, whose sender handles the presses;
merge this before that release ships.

## What changed

- **Previous and next on the device.** While the station has others in its group, the page declares `QUEUE_PREV` and
  `QUEUE_NEXT`. A smart display, Google TV and the Google Home app then show the standard previous / next (skip)
  buttons beside play/pause.
  - They are hidden when the station is alone in its group.
  - There is no previous on the group's first station and no next on its last, exactly as in the app.
- **A press switches the station in the app.** The page plays nothing itself. It broadcasts a media status whose
  `customData` is `{"step": "previous"|"next", "stepId": n}`, with the ids rising. The app steps through the station's
  group with its own previous / next code, then loads the new station here.
- **Every way to press works.**
  - The device's own `QUEUE_PREV` / `QUEUE_NEXT`.
  - A sender's queue jump (`QUEUE_UPDATE` with `jump` 1 or -1).
- **The item's `customData` is JSON text: `{"caption", "previous", "next"}`.** A plain string, as older app builds send
  it, is still the caption alone, with no buttons.

## Checked

- The page's script parses (no syntax error), and the app's unit tests cover the sender side against a loopback Cast
  receiver: the steps the app sends, a press reaching the app once, and a repeated status not counting as a second
  press.
- The receiver's own tests (`tests/receiver.test.js`, in CI's test job) run the page's script with the Cast framework
  stubbed: a bare-string caption, the JSON item and the commands it declares, step ids that rise even on a clock that
  stands still, and a queue jump of +1 / -1 (a step) against the app's song update (shown, no step).
- On a device once GitHub Pages serves it:
  - cast a station from a group of several to the Pixel Tablet;
  - the tablet's media controls and the Google Home app show previous and next;
  - next plays the group's next station on the tablet, and the app's player shows it too;
  - a station alone in its group shows no buttons.
