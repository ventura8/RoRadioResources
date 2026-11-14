// Copyright 2026 Sergiu Alexandrescu
// The RoRadio Cast receiver's script, loaded by receiver/index.html after Google's Cast framework (see the page's
// comment for what it shows). tests/receiver.test.js runs it in Node at 100 % line, branch and function coverage;
// tests/receiver.browser.test.js runs it in Chrome with the real framework.
// One function around the whole script, so nothing of it leaks into the page's global scope (the body is not indented
// for it: it is the script itself).
(function receiver() {
'use strict';

const context = cast.framework.CastReceiverContext.getInstance();
const player = context.getPlayerManager();
const byId = (id) => document.getElementById(id);

const YEAR_DIGITS = 4;

/** The year of a release date ("2015" or "2015-03-01"); empty when there is none. */
function yearOf(date) {
    return typeof date === 'string' ? date.slice(0, YEAR_DIGITS) : '';
}

/**
 * An image url from the app's metadata, only when it is http(s), normalized (quotes, spaces and newlines
 * percent-encoded) so it is safe inside CSS url("..."); anything else (javascript:, data:, junk) is none.
 */
function imageUrl(url) {
    if (typeof url !== 'string') {
        return '';
    }

    try {
        const parsed = new URL(url);
        return parsed.protocol === 'https:' || parsed.protocol === 'http:' ? parsed.href : '';
    } catch {
        return '';
    }
}

/**
 * Sets an image's source once it has loaded, so a broken url never shows a broken picture. Only the newest
 * request for an image applies: a slow old cover never replaces a newer one, nor brings back a removed one.
 */
function showImage(image, url, onShown) {
    const request = String(Number(image.dataset.request || 0) + 1);
    image.dataset.request = request;
    if (!url) {
        image.removeAttribute('src');
        return;
    }

    const probe = new Image();
    probe.onload = () => {
        if (image.dataset.request === request) {
            image.src = url;
            onShown(url);
        }
    };
    probe.onerror = () => {
        // A picture that does not load: none, rather than the last song's.
        if (image.dataset.request === request) {
            image.removeAttribute('src');
            onShown(null);
        }
    };
    probe.src = url;
}

/** Whether a logo is too dark for the screen (receiver/logo-tone.js, loaded before this script). */
const { isDark } = window.logoTone;
/** The app's cover colour theme (receiver/theme.js, loaded before this script), and the one on screen. */
const { applyTheme, themeOf } = window.receiverTheme;
/** The test mode's layout report (receiver/layout-report.js). */
const { layoutNow } = window.layoutReport;
let theme = null;

/**
 * The light treatment for a dark logo (class "light", a white glow in the page's styles; never a plate behind it),
 * measured on a CORS copy of the picture (GitHub Pages, where the app's logos are, allows it).
 */
function markTone(image, url) {
    image.classList.remove('light');
    if (!url) {
        return;
    }

    const { request } = image.dataset;
    const probe = new Image();
    probe.crossOrigin = 'anonymous';
    probe.onload = () => {
        if (image.dataset.request === request) {
            image.classList.toggle('light', isDark(probe));
        }
    };
    probe.src = url;
}

/** Text from the app's JSON, or nothing for any other value. */
const text = (value) => (typeof value === 'string' ? value : '');

/**
 * The app's data for this item: {"caption", "previous", "next", "station", "logo"} as JSON text; a plain string (older
 * app builds) is the caption alone, with no steps.
 */
function appData(customData) {
    const none = { caption: '', logo: '', next: false, previous: false, rects: false, station: '', theme: null };
    if (typeof customData !== 'string') {
        return none;
    }

    if (customData.startsWith('{')) {
        try {
            const data = JSON.parse(customData);
            return {
                caption: text(data.caption),
                logo: text(data.logo),
                next: data.next === true,
                previous: data.previous === true,
                rects: data.rects === true,
                station: text(data.station),
                theme: themeOf(data.theme),
            };
        } catch {
            // Not the app's JSON: a caption that starts with a brace.
        }
    }

    return { ...none, caption: customData };
}

const { Command } = cast.framework.messages;
const stepCommands = Command.QUEUE_PREV | Command.QUEUE_NEXT;
let baseCommands = null;

/** The steps the station has, as declared to the device (and reported in "shown"). */
const steps = { next: false, previous: false };

/**
 * Previous / next as the app offers them: declared only for a step the station has, so the device's own media
 * controls (smart display, Google TV, Google Home) show exactly those.
 */
function showSteps(previous, next) {
    if (baseCommands === null) {
        baseCommands = player.getSupportedMediaCommands() & ~stepCommands;
    }

    const commands = baseCommands | (previous ? Command.QUEUE_PREV : 0) | (next ? Command.QUEUE_NEXT : 0);
    player.setSupportedMediaCommands(commands, true);
    steps.next = next;
    steps.previous = previous;
}

/*
 * One press is one step. A device's controller sends again a jump it got no answer to, with the same request id, and a
 * press could fire twice within a moment: one tap on the Pixel Tablet's next went seven stations on (2026-11-14). A
 * request id seen within RETRY_MS is the same press, and a step within STEP_GAP_MS of the last one is the same press
 * too. A request id counts for a few seconds only, and 0 (or none) not at all: the tablet's own media bar sends every
 * press with the same request id, and a remembered id took every later previous / next for the first one's repeat
 * (one previous worked, then nothing, 2026-11-14). A resend is the same direction too, and comes within RETRY_MS:
 * next, then previous a moment later with the bar's one request id, is two presses (Greptile, #43).
 */
const STEP_GAP_MS = 600;
const RETRY_MS = 1500;

/** Test mode, asked for by a test sender only ({"rects": true} in its customData). */
let withRects = false;
const seenRequests = new Map();
let lastStepAt = -Infinity;
let lastStepId = 0;

/** The press a request is: its sender, request id and direction, or '' when it carries no id to tell a resend by. */
function pressKey(request, name) {
    return request && request.requestId ? `${request.senderId}/${request.requestId}/${name}` : '';
}

/**
 * Whether a press with `key` at `now` repeats one already stepped on: the same request within RETRY_MS, or any press
 * within STEP_GAP_MS. A clock set back (the device synced its time) is no repeat.
 */
function isRepeat(key, now) {
    const within = (at, span) => now >= at && now - at < span;
    const resent = Boolean(key) && seenRequests.has(key) && within(seenRequests.get(key), RETRY_MS);
    return resent || within(lastStepAt, STEP_GAP_MS);
}

/** A previous / next press, for the app: a media status whose customData names it, numbered upwards. */
function step(name, request) {
    const key = pressKey(request, name);
    const now = Date.now();
    const repeat = isRepeat(key, now);
    // Each resend starts a resend's time again: a controller resending for longer than RETRY_MS never steps twice.
    seenRequests.set(key, now);
    if (repeat) {
        // Test mode: a press taken for a repeat is reported too, so the device test sees what was dropped and why.
        report(withRects ? { skipped: name, via: key } : {});
        return;
    }

    lastStepAt = now;
    lastStepId = Math.max(now, lastStepId + 1);
    // "via" names the request that made the step, for the on-device test (older apps read only step and stepId).
    report({ step: name, stepId: lastStepId, via: key });
}

/** The idle screen's status line: ready, or why the last station stopped. */
function showStatus(failed) {
    document.body.classList.remove('playing');
    document.body.classList.toggle('failed', failed);
    byId('status').textContent = failed
        ? 'The station stopped: its stream could not be played. Pick it again, or another one, in RoRadio.'
        : 'Ready to play';
}

/**
 * What the screen shows, for the senders: {"title", "artist", "station", "caption", "logo", "cover", "steps",
 * "defaultTitle"} in the media status's customData, so an E2E test (or the app) can check the screen without OCR.
 * "logo" and "cover" are true once the picture loaded; "defaultTitle" is true while no song is known (the title is
 * empty or the station's own name).
 */
function shownNow() {
    const title = byId('title').textContent;
    const station = byId('stationName').textContent;
    return {
        artist: byId('artist').textContent,
        caption: byId('captionText').textContent,
        cover: byId('cover').hasAttribute('src'),
        defaultTitle: !title || title === station,
        logo: byId('station').querySelector('img').hasAttribute('src'),
        station,
        steps: { ...steps },
        theme,
        title,
        ...(withRects ? layoutNow() : {}),
    };
}


/**
 * Tells the senders what the screen shows now; a step press carries it too (stepPress). Request id 0 is the Cast
 * protocol's unsolicited status, to every sender. Older apps read only {"step", "stepId"} and ignore the rest.
 */
function report(stepPress = {}) {
    player.broadcastStatus(false, 0, { ...stepPress, shown: shownNow() });
}

/** The blurred backdrop of `url`, or none: no backdrop from the last song when this one has no picture. */
function showBackdrop(url) {
    const backdrop = byId('backdrop');
    backdrop.style.backgroundImage = url ? `url("${url}")` : '';
    backdrop.classList.toggle('shown', Boolean(url));
    report();
}

/** A text shrinks by this much a step, down to 24 px at 1080p (10-foot UI), before its second line is cut. */
const FIT_STEP = 0.9;
const READABLE_AT_1080P = 24;
const FULL_HD_HEIGHT = 1080;
const FITTED = ['title', 'artist', 'release'];
const TOO_TALL = 2.5;
const HALF_PIXEL = 0.5;

/**
 * Up to two lines for a text (the styles clamp it at two): it keeps its full size while it fits, and shrinks in
 * steps to the readable minimum while it needs more; only then does its second line end in an ellipsis.
 */
function fitText(element, minimum) {
    element.style.fontSize = '';
    // More than two lines: its full height passes two and a half lines (a line's glyphs may overhang it a little).
    const tooTall = () => element.scrollHeight > TOO_TALL * parseFloat(getComputedStyle(element).lineHeight);
    while (tooTall() && shrink(element, minimum)) {
        // Shrunk one step; measured again.
    }
}

/** One step smaller, never under `minimum`; whether it could shrink at all. */
function shrink(element, minimum) {
    const size = parseFloat(getComputedStyle(element).fontSize);
    // Within half a pixel of it is the minimum: the browser rounds a size it was given (35.5556 for 35.55555), and
    // an exact test shrank to the same size forever (tablet, 2026-11-14).
    if (size <= minimum + HALF_PIXEL) {
        return false;
    }

    element.style.fontSize = `${Math.max(size * FIT_STEP, minimum)}px`;
    return true;
}

/**
 * The song's texts fitted to their two lines, then together to the song's column: while the column's texts pass the
 * station's line at its bottom, all three shrink a step (again when the screen's size changes).
 */
function fitSong() {
    const minimum = (READABLE_AT_1080P * window.innerHeight) / FULL_HD_HEIGHT;
    const texts = FITTED.map(byId);
    texts.forEach((element) => fitText(element, minimum));
    while (crowded(texts) && texts.map((element) => shrink(element, minimum)).includes(true)) {
        // All three shrunk a step; measured again.
    }
}

/** Whether the song's texts need more than their column: past its bottom, or into the station's line under them. */
function crowded(texts) {
    const song = byId('song');
    const station = byId('station');
    const line = station.classList.contains('empty') ? Infinity : station.getBoundingClientRect().top;
    return song.scrollHeight > song.clientHeight + 1 || texts.some((element) => element.getBoundingClientRect().bottom > line + 1);
}

/** The song's text, the station's name and the caption. */
function showText(metadata, data) {
    // The station's name once (owner, 2026-11-14): with no song the app sends it as title and artist too, and "Pro FM"
    // showed three times. A field that is only the station's name is left out; a song's own fields may repeat each
    // other (a title, album and artist that are the same string are the song's data).
    const station = data.station.trim().toLowerCase();
    const notStation = (value) => ((value || '').trim().toLowerCase() === station ? '' : value || '');
    byId('title').textContent = notStation(metadata.title || metadata.songName);
    byId('artist').textContent = notStation(metadata.artist || metadata.subtitle);
    byId('album').textContent = notStation(metadata.albumName);
    byId('year').textContent = yearOf(metadata.releaseDate);
    byId('release').classList.toggle('empty', !byId('album').textContent && !yearOf(metadata.releaseDate));
    byId('stationName').textContent = data.station;
    showCaption(data.caption);
}

/** The live caption on its own line, or none. */
function showCaption(caption) {
    byId('captionText').textContent = caption;
    byId('captions').classList.toggle('empty', !caption);
    document.body.classList.toggle('captioned', Boolean(caption));
}

/**
 * The pictures. The app sends [cover, station logo] when the song has a cover, and [station logo] alone when it has
 * none: the logo then takes the cover's place, whole, and is not shown twice. Since 2.4.5 the customData also names
 * the station and its logo, so the logo shows beside the cover whatever the images hold. Only http(s) pictures,
 * normalized (imageUrl): the cover, the logo and so the backdrop's CSS url.
 */
function showPictures(metadata, data) {
    const images = metadata.images || [];
    const cover = imageUrl(images[0] && images[0].url);
    const dataLogo = imageUrl(data.logo);
    const logo = imageUrl(images[1] && images[1].url) || (dataLogo === cover ? '' : dataLogo);
    byId('cover').classList.toggle('logo', Boolean(cover) && !logo);
    if (!cover) {
        // No picture in the cover's place: the station's logo blurred behind (the app's customData), else none.
        showBackdrop(logo || null);
    }

    // A cover that does not load leaves the station's logo as the backdrop, not none (CodeRabbit, #46).
    showImage(byId('cover'), cover, (shown) => showBackdrop(shown || logo || null));
    showLogo(logo, data.station, byId('cover').classList.contains('logo') ? cover : '');
}

/** The station's logo beside the cover (or the logo in the cover's place), each with its tone measured. */
function showLogo(logo, station, coverLogo) {
    const image = byId('station').querySelector('img');
    byId('station').classList.toggle('empty', !logo && !station);
    // The logo's line takes its full height once the logo has loaded: the song's texts are fitted again above it.
    showImage(image, logo, () => {
        fitSong();
        report();
    });
    markTone(image, logo);
    markTone(byId('cover'), coverLogo);
}

/** The item's modes: the test mode, and the app's cover colour theme (or the default look without one). */
function applyModes(data) {
    ({ rects: withRects, theme } = data);
    applyTheme(theme);
}

/** Draws the song of `media`: its metadata, its pictures (the cover, then the station's logo), its caption. */
function show(media) {
    const metadata = media.metadata || {};
    const data = appData(media.customData);
    applyModes(data);
    showText(metadata, data);
    showSteps(data.previous, data.next);
    showPictures(metadata, data);
    // The song's screen shows first: hidden (the idle screen), the texts measured nothing and never shrank (#46).
    document.body.classList.remove('failed');
    document.body.classList.add('playing');
    fitSong();
    report();
}

/** The app's song update: drawn here, and the player's media information follows for the senders' notifications. */
function updateSong(media) {
    show(media);
    const playing = player.getMediaInformation();
    if (playing) {
        // The new song's metadata whole: an album or a year the new song has none of must not stay.
        playing.metadata = media.metadata;
        playing.customData = media.customData;
        player.setMediaInformation(playing, true);
    }
}

const { MessageType } = cast.framework.messages;

/** A LOAD: the station starts; its song is shown with it. */
player.setMessageInterceptor(MessageType.LOAD, (request) => {
    if (request.media) {
        show(request.media);
    }

    return request;
});

/**
 * Every media status the page sends says what the screen shows, a sender's GET_STATUS answer too: a sender (or a
 * test) asks at any time, without waiting for the next change. A status that already carries custom data (a step
 * press) keeps it.
 */
player.setMessageInterceptor(MessageType.MEDIA_STATUS, (status) => {
    status.customData ||= { shown: shownNow() };
    return status;
});

/**
 * A song change or a caption (the app's QUEUE_UPDATE of the item playing): shown here, and given to the player's
 * media information so the senders' notifications and the Google Home app show the new song too.
 */
player.setMessageInterceptor(MessageType.QUEUE_UPDATE, (request) => {
    // A sender's previous / next (the Google Home app, an Android notification) is a jump in the queue: the app steps
    // instead, and loads the station it reaches.
    if (request.jump === 1 || request.jump === -1) {
        step(request.jump === 1 ? 'next' : 'previous', request);
        return null;
    }

    const media = request.items && request.items[0] && request.items[0].media;
    if (media && media.metadata) {
        updateSong(media);
    }

    return request;
});

/*
 * The device's own previous / next (a smart display's touch controls, Google TV's remote, the Assistant) reach the
 * page as a QUEUE_UPDATE jump, above. No interceptor for QUEUE_NEXT / QUEUE_PREV: the framework names them in
 * MessageType but throws "Unknown message type" for an interceptor, which stopped this script before context.start(),
 * so the page never answered the launch and the app fell back to the Default Media Receiver (Pixel Tablet, 2026-11-14).
 */

const { EventType } = cast.framework.events;

// The station ended: the idle screen again, saying why when its stream failed.
player.addEventListener(EventType.MEDIA_FINISHED, (event) => showStatus(Boolean(event) && event.endedReason === 'ERROR'));
player.addEventListener(EventType.ERROR, () => showStatus(true));

/*
 * No buttons of the page's own: a touch display (Pixel Tablet) always draws its system media bar (progress,
 * LIVE, the output chip, previous / pause / next) over the page's bottom, whatever the receiver declares. Its
 * previous / next reach the page as a QUEUE_UPDATE jump (above), so a second set of buttons only duplicated them.
 */

/** Whether this device takes touch (Pixel Tablet, Nest Hub): the page then keeps clear of the system media bar. */
function isTouch() {
    try {
        const capabilities = context.getDeviceCapabilities() || {};
        if (capabilities[cast.framework.system.DeviceCapabilities.TOUCH_INPUT_SUPPORTED]) {
            return true;
        }
    } catch {
        // Not ready yet, or off a device: the pointer decides.
    }

    return typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches;
}

const markTouch = () => document.body.classList.toggle('touch', isTouch());
context.addEventListener(cast.framework.system.EventType.READY, markTouch);
markTouch();
// The touch layout and the screen's size change the room a text has: fitted again.
window.addEventListener('resize', fitSong);

// The page's own media element: with Google's cast-media-player a touch display drew its default audio UI (the
// station's name twice, no logo) over this page (Pixel Tablet, 2026-11-14).
player.setMediaElement(byId('media'));

const options = new cast.framework.CastReceiverOptions();
// A radio station plays until it is stopped; the receiver stays while it is idle between two stations.
options.maxInactivity = 3600;
// This page is the touch UI (Cast's smart display guide): no default controls or opaque scrim over it.
options.uiConfig = new cast.framework.ui.UiConfig();
options.uiConfig.touchScreenOptimizedApp = true;
context.start(options);
}());
