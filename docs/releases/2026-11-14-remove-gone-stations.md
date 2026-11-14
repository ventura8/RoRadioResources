# Four gone stations removed, 2026-11-14

The owner decided to remove the four stations that have not played since 2026-09-29 and that the review of
2026-11-14 (`2026-11-14-dead-stations.md`) found closed: no site, no directory entry and no server that plays. The
list loses them, and their two logos go with them (no other station used them). No other station changes.

## Retired stations (for RetiredStations.json)

Each removed station, as the updater's retirement list will hold it. The logos are removed from `RadioLogos/`; both
files stay in git history (the parent of this pull request's commit) if a station comes back.

| Station | GUID | Category | Last url | Logo | Retired | Evidence it is gone |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Atlas FM | `9909e9cd-9046-47ba-bfb8-c18bfdfcce23` | Other | `http://5.2.168.50:8000/` | `AtlasFM.jpg` | 2026-11-14 | Dead in every probe since 2026-09-29; `atlasfm.ro` no longer resolves (its last Wayback capture, March 2026, is a parked page); in no directory (radio-browser.info, Shoutcast, TuneIn). |
| Hot 107.1 FM | `6a2d918b-21d3-4196-b125-fb9db4cc9deb` | Hip hop | `http://192.99.34.205:8607/stream` | none | 2026-11-14 | Dead since 2026-09-29; the last server the Shoutcast directory named (`94.130.162.80:8607`) answers 401 "resource currently unavailable" (no source); the station left the directory; never identified (no site). |
| Radio Amma | `b13eafe3-6b8f-486c-bf83-2d4bdab4b4b2` | Other | `http://54.39.28.158:8024/stream` | none | 2026-11-14 | The server refuses connections; Shoutcast directory id 99627489 is delisted (empty playlist); `radioammamanele.ro` does not resolve; in no directory. |
| Radio Intexfm | `40c7aec6-8f72-41e9-90a6-5ac382b3374d` | Dance | `http://149.202.158.82:9788/;` | `radio-intexfm.png` | 2026-11-14 | Dead since 2026-09-29; `radiointexfm.ro` no longer resolves; its player host (`carina.streamerr.co/AudioPlayer/radiointexfmromania`, from a 2024 Wayback capture) answers "Service not found"; in no directory. |

## What listeners who had them see

RoRadio finds favourites and the last station by GUID in the list it downloads. A favourite whose GUID is no longer
in the list is not shown (nothing else changes), and when the last played station is missing the app starts
silent instead of resuming, and reports `LastStationMissing` with the GUID to analytics. Neither path shows an
error or stops the app (`RadioViewModel.PlayLastStation` and the favourites sync; unit test
`AStationThatLeftTheCatalogueCannotResumeAndSaysSo`). Apps that have not updated their bundled copy see the same
thing as soon as they download this list from GitHub Pages.
