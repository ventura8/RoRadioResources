# Cast receiver, 2026-11-13

RoRadio's own Chromecast receiver page, `receiver/index.html`, served by GitHub Pages at
`https://ventura8.github.io/RoRadioResources/receiver/`. RoRadio 2.4.5 casts to it once its app id is registered
in the Google Cast developer console (a Custom Receiver with this url, casting to audio-only devices allowed).
Devices that refuse it play on Google's Default Media Receiver, as before.

## What it shows

- The song while it plays: cover, title, artist, album, year, and the station's logo as a small badge.
- The live captions, on a two-line band of their own, while captions are on in the app.
- A "Ready to play" screen before a station is cast.

## Why a page of its own

Google's Default Media Receiver keeps the song a cast started with: it ignores the song updates (`QUEUE_UPDATE`)
the app sends while the station plays (measured on a Sony HT-A7000, 2026-11-13). This page intercepts them, shows
the new song and caption, and hands the song to the senders' notifications and the Google Home app.

## Layout

- Everything stays inside a 5 % safe area.
- Text is at least 24 px at 720p: white on a dark scrim over the blurred cover.
- A fixed grid keeps elements from growing into each other; long text ends with an ellipsis, the title and the
  captions at two lines.
- Checked at 1024 x 600 (Nest Hub), 1280 x 720, 1280 x 800, 1920 x 1080 and 800 x 1280, with long and short text:
  no element overlaps another and none leaves the safe area.
- Audio-only devices draw nothing and play the audio.
