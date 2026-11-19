# Cast device E2E: pass step JSON via `@path` on Windows, 2026-11-18

`scripts/e2e/Test-ReceiverOnTablet.ps1` failed every `load` / `song` / `tap` step on Windows PowerShell
because native argv quoting strips `"` from the JSON string before Node sees it
(`Expected property name or '}' in JSON at position 1`). Launch (no payload) still worked.

## Fix

- `cast-client.mjs` accepts `@path` as the third argument and reads UTF-8 JSON from that file.
- The PowerShell driver writes each step's payload to `%TEMP%/roradio-cast-e2e-arg.json` and passes
  `@` that path, so quotes survive.

## Checked

- Pixel Tablet wireless adb (`adb-3406105H801UJL-TonHNR._adb-tls-connect._tcp`): launch, load (PLAYING),
  song, theme on/off, shown layout, play, switch, stop succeed after the `@path` change.
