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

/** The contrast a logo's pixel needs on the receiver's background to be seen (as in transparent_logo.py). */
const VISIBLE_CONTRAST = 2;
/** A logo with more than this share of its opaque pixels too dark to see gets the light treatment. */
const DARK_SHARE = 0.5;
/** The size logos are measured at: the decision needs shapes, not detail. */
const MEASURED = 64;
/** A pixel at least this opaque is part of the logo's mark. */
const OPAQUE = 128;
/** One RGBA pixel's bytes. */
const RGBA = 4;

/** WCAG 2.x relative luminance, and the receiver's background (#08090c) by it. */
const WCAG = {
    background: 0.0029,
    blue: 0.0722,
    channel: 255,
    flare: 0.05,
    gamma: 2.4,
    green: 0.7152,
    knee: 0.03928,
    offset: 0.055,
    red: 0.2126,
    scale: 1.055,
    slope: 12.92,
};

/** The linear light of one sRGB channel value, 0-255. */
function linear(value) {
    const channel = value / WCAG.channel;
    return channel <= WCAG.knee ? channel / WCAG.slope : ((channel + WCAG.offset) / WCAG.scale) ** WCAG.gamma;
}

/** Whether one RGBA pixel is part of the mark and too dark to see on the receiver's background: [mark, dark]. */
function darkPixel([red, green, blue, alpha]) {
    if (alpha < OPAQUE) {
        return [0, 0];
    }

    const luminance = WCAG.red * linear(red) + WCAG.green * linear(green) + WCAG.blue * linear(blue);
    return [1, (luminance + WCAG.flare) / (WCAG.background + WCAG.flare) < VISIBLE_CONTRAST ? 1 : 0];
}

/** The share of a picture's mark that is too dark, from its RGBA bytes; 0 when nothing is opaque. */
function darkShare(data) {
    let mark = 0;
    let dark = 0;
    for (let index = 0; index < data.length; index += RGBA) {
        const [isMark, isDarkPixel] = darkPixel(data.slice(index, index + RGBA));
        mark += isMark;
        dark += isDarkPixel;
    }

    return mark > 0 ? dark / mark : 0;
}

/**
 * Whether a loaded logo is mostly too dark to see on the receiver's dark background (dark lettering on
 * transparency). A picture from a host without CORS cannot be read: it is taken as readable.
 */
function isDark(picture) {
    const canvas = document.createElement('canvas');
    canvas.width = MEASURED;
    canvas.height = MEASURED;
    const context2d = canvas.getContext('2d');
    try {
        context2d.drawImage(picture, 0, 0, MEASURED, MEASURED);
        return darkShare(context2d.getImageData(0, 0, MEASURED, MEASURED).data) > DARK_SHARE;
    } catch {
        return false;
    }
}

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
    const none = { caption: '', logo: '', next: false, previous: false, rects: false, station: '' };
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
 * request id seen before is the same press, and a step within STEP_GAP_MS of the last one is the same press too.
 */
const STEP_GAP_MS = 600;
const seenRequests = new Set();
let lastStepAt = -Infinity;
let lastStepId = 0;

/** A previous / next press, for the app: a media status whose customData names it, numbered upwards. */
function step(name, request) {
    const key = request && 'requestId' in request ? `${request.senderId}/${request.requestId}` : '';
    const now = Date.now();
    // A clock set back (the device synced its time) is no repeat: only a press just after the last one is.
    const repeat = now >= lastStepAt && now - lastStepAt < STEP_GAP_MS;
    if (seenRequests.has(key) || repeat) {
        return;
    }

    if (key) {
        seenRequests.add(key);
    }

    lastStepAt = now;
    lastStepId = Math.max(now, lastStepId + 1);
    report({ step: name, stepId: lastStepId });
}

/** The idle screen's status line: ready, or why the last station stopped. */
function showStatus(failed) {
    document.body.classList.remove('playing');
    document.body.classList.toggle('failed', failed);
    byId('status').textContent = failed
        ? 'The station stopped: its stream could not be played. Pick it again, or another one, in RoRadio.'
        : 'Ready to play';
}

/** Asked for by a test sender only ({"rects": true} in its customData). */
let withRects = false;

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
        title,
        ...(withRects ? layoutNow() : {}),
    };
}

/** The leaves an on-device test measures on the device's own screenshot. */
const LEAVES = ['cover', 'stationName', 'title', 'artist', 'release', 'captionText'];

/**
 * Test mode: each visible leaf's box (CSS px, [left, top, right, bottom]), its text colour, the device pixel ratio
 * and the viewport, so an on-device E2E can check overlaps and contrast on the device's real screenshot.
 */
function layoutNow() {
    const rects = {};
    for (const id of [...LEAVES, 'station']) {
        const box = (id === 'station' ? byId(id).querySelector('img') : byId(id)).getBoundingClientRect();
        if (box.width > 0 && box.height > 0) {
            rects[id] = { box: [box.left, box.top, box.right, box.bottom], color: getComputedStyle(byId(id)).color };
        }
    }

    return { rects, scale: window.devicePixelRatio, viewport: [window.innerWidth, window.innerHeight] };
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
        showBackdrop(null);
    }

    showImage(byId('cover'), cover, showBackdrop);
    showLogo(logo, data.station, byId('cover').classList.contains('logo') ? cover : '');
}

/** The station's logo beside the cover (or the logo in the cover's place), each with its tone measured. */
function showLogo(logo, station, coverLogo) {
    const image = byId('station').querySelector('img');
    byId('station').classList.toggle('empty', !logo && !station);
    showImage(image, logo, () => report());
    markTone(image, logo);
    markTone(byId('cover'), coverLogo);
}

/** Draws the song of `media`: its metadata, its pictures (the cover, then the station's logo), its caption. */
function show(media) {
    const metadata = media.metadata || {};
    const data = appData(media.customData);
    withRects = data.rects;
    showText(metadata, data);
    showSteps(data.previous, data.next);
    showPictures(metadata, data);
    document.body.classList.remove('failed');
    document.body.classList.add('playing');
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
