# Dead stations reviewed, 2026-11-14

A dry run of the weekly refresh before RoRadio 2.4.5 left twelve stations whose streams failed both probes and for
which it found no candidate. Each was looked up by hand (myradioonline.ro, the station's own site and player,
radio-browser.info, the Shoutcast directory, the TuneIn OPML API, onlineradiobox.com, the Wayback Machine). Two get a
working url; the other ten have no stream that plays today and keep their url and their place in the list (this
review never deletes a station: that would drop it from listeners' favorites). Urls only: no GUID, title, category or
logo changed.

Each new url was probed from Romania with `scripts/Test-StationStreams.ps1` (verdict `alive`), and a few seconds of
it were decoded with ffmpeg (real, non-silent audio).

## Stream urls

| Logo | Station | Old url | New url | Found on, and how it was tied to the station |
| :--- | :--- | :--- | :--- | :--- |
| <img src="../../RadioLogos/radio-sos.png" width="48" alt="Radio SOS"> | Radio SOS | `http://5.2.180.231:8000/stream` | `https://radiosos.ro:8002/stream` | The player on [radiosos.ro](http://radiosos.ro/) and the station's onlineradiobox page (101.7 FM Ploiești); `icy-name` "Radio S.O.S. 101.7 FM Ploiesti", the name the logo was matched to. AAC 64 kbps, 48 kHz stereo. |
| <img src="../../RadioLogos/slager-radio.png" width="48" alt="Sláger Rádió"> | Sláger Rádió | `http://89.37.193.61:8000/raspi` | `https://slagerfm.netregator.hu:7813/slagerfm320.mp3` | radio-browser.info "Sláger Rádió - Slager FM Sepsiszentgyörgy/Sfântu Gheorghe 105.9 FM": the same 105.9 MHz Covasna station and the same Facebook page (`facebook.com/radioslager`) as the onlineradiobox page the logo came from; `icy-name` "Slager FM". MP3 320 kbps. |

## Left as they are

| Logo | Station | Url | Evidence |
| :--- | :--- | :--- | :--- |
| <img src="../../RadioLogos/radio-click.png" width="48" alt="Radio Click"> | Radio Click | `http://live.radioclick.ro:8008/` | Provider outage: myradioonline.ro and the Shoutcast directory give `https://sonicssl.namehost.ro/8008/stream` / `https://live.radioclick.ro:8008/stream`; both names are 188.212.100.62 (namehost.ro), which refused every connection from Romania and from a second network today. Re-check; no url could be probed. |
| <img src="../../RadioLogos/radio-liberty-popular.png" width="48" alt="Radio Liberty popular"> | Radio Liberty popular | `http://populara.radioliberty.ro:1989/;` | Same outage: the player on [radioliberty.ro](https://www.radioliberty.ro/listen/radio-liberty-popular) streams `https://sonicssl.namehost.ro/7780/stream` (also in the Shoutcast directory), on 188.212.100.62, unreachable. The other Radio Liberty channels on `sonicpanel.namehost.ro` play. |
| <img src="../../RadioLogos/radio-sud-constanta.png" width="48" alt="Radio Sud Constanța"> | Radio Sud Constanța | `http://asculta.radiosudconstanta.com:8750/stream` | Same outage: the station's site player streams `https://sonicssl.namehost.ro/8750/stream`, and `asculta.radiosudconstanta.com` is 188.212.100.62, unreachable. |
| <img src="../../RadioLogos/vox-fm.png" width="48" alt="Vox FM"> | Vox FM | `http://stream.voxfm.ro:8000/` | Off air at the source: the station's Shoutcast 2.6 server answers (`icy-name` "VOXFM 88.6", `statistics?json=1` lists `/stream/1`, its `listen.pls`) but sends no audio byte on any mount. The url is the station's own server. |
| <img src="../../RadioLogos/traditionalhiphop.png" width="48" alt="Radio Traditional"> | Radio Traditional | `http://178.32.183.159:7500/;` | Off air: [radiotraditional.ro](https://www.radiotraditional.ro/radio-hip-hop-romanesc/)'s Hip Hop player streams port 7500 of `asculta.ascultatare.ro`, whose SonicPanel answers "Stream is Offline" (no AutoDJ, no source). Its Manele channel on the same server plays. |
| - | Radio Tradiţional Popular | `http://populara.radiotraditional.ro:7600/` | Off air: the same site's Popular player streams port 7600 of the same server: "Stream is Offline". |
| <img src="../../RadioLogos/AtlasFM.jpg" width="48" alt="Atlas FM"> | Atlas FM | `http://5.2.168.50:8000/` | Gone: dead since 2026-09-29; `atlasfm.ro` no longer resolves (its last Wayback capture, March 2026, is a parked page); in no directory. |
| - | Hot 107.1 FM | `http://192.99.34.205:8607/stream` | Gone: dead since 2026-09-29; the server the Shoutcast directory last named (`94.130.162.80:8607`) answers 401 "resource currently unavailable" (no source), and the station is no longer in the directory. Never identified (no site, no logo). |
| - | Radio Amma | `http://54.39.28.158:8024/stream` | Gone: the server refuses connections, Shoutcast directory id 99627489 is delisted (empty playlist), `radioammamanele.ro` does not resolve, and no directory lists it. |
| <img src="../../RadioLogos/radio-intexfm.png" width="48" alt="Radio Intexfm"> | Radio Intexfm | `http://149.202.158.82:9788/;` | Closed: `radiointexfm.ro` no longer resolves; the player its site used (Wayback, 2024: `carina.streamerr.co/AudioPlayer/radiointexfmromania`) now answers "Service not found"; in no directory. |

The three namehost.ro stations should play again when that host is back, with no change; the weekly refresh will
pick up a moved url. The owner decides whether the four gone stations stay in the list.
