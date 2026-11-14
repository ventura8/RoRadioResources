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

/** The year of a release date ("2015" or "2015-03-01"); empty when there is none. */
function yearOf(date) {
    return typeof date === 'string' ? date.slice(0, 4) : '';
}

/**
 * Sets an image's source once it has loaded, so a broken url never shows a broken picture. Only the newest
 * request for an image applies: a slow old cover never replaces a newer one, nor brings back a removed one.
 */
function showImage(image, url, onShown = () => undefined) {
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

/** Text from the app's JSON, or nothing for any other value. */
const text = (value) => (typeof value === 'string' ? value : '');

/**
 * The app's data for this item: {"caption", "previous", "next", "station", "logo"} as JSON text; a plain string (older
 * app builds) is the caption alone, with no steps.
 */
function appData(customData) {
    const none = { caption: '', logo: '', next: false, previous: false, station: '' };
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

/**
 * Previous / next as the app offers them: declared only for a step the station has, so the device's own media
 * controls (smart display, Google TV, Google Home) and the page's own buttons show exactly those.
 */
function showSteps(previous, next) {
    if (baseCommands === null) {
        baseCommands = player.getSupportedMediaCommands() & ~stepCommands;
    }

    const commands = baseCommands | (previous ? Command.QUEUE_PREV : 0) | (next ? Command.QUEUE_NEXT : 0);
    player.setSupportedMediaCommands(commands, true);
    byId('previous').classList.toggle('hidden', !previous);
    byId('next').classList.toggle('hidden', !next);
}

/*
 * One press is one step. A device's controller resends a jump it got no answer to, with the same request id, and a
 * press could fire twice within a moment: one tap on the Pixel Tablet's next went seven stations on (2026-11-14). A
 * request id seen before is the same press, and a step within STEP_GAP_MS of the last one is the same press too.
 */
const STEP_GAP_MS = 600;
const seenRequests = new Set();
let lastStepAt = -Infinity;
let lastStepId = 0;

/** A previous / next press, for the app: a media status whose customData names it, numbered upwards. */
function step(name, request) {
    const key = request && request.requestId !== undefined ? `${request.senderId}/${request.requestId}` : '';
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
    player.broadcastStatus(false, undefined, { step: name, stepId: lastStepId });
}

/** The idle screen's status line: ready, or why the last station stopped. */
function showStatus(failed) {
    document.body.classList.remove('playing');
    document.body.classList.toggle('failed', failed);
    byId('status').textContent = failed
        ? 'The station stopped: its stream could not be played. Pick it again, or another one, in RoRadio.'
        : 'Ready to play';
}

/** Draws the song of `media`: its metadata, its pictures (the cover, then the station's logo), its caption. */
function show(media) {
    const metadata = media.metadata || {};
    byId('title').textContent = metadata.title || metadata.songName || '';
    byId('artist').textContent = metadata.artist || metadata.subtitle || '';
    byId('album').textContent = metadata.albumName || '';
    byId('year').textContent = yearOf(metadata.releaseDate);
    byId('release').classList.toggle('empty', !metadata.albumName && !yearOf(metadata.releaseDate));
    const data = appData(media.customData);
    showSteps(data.previous, data.next);
    byId('captionText').textContent = data.caption;
    byId('captions').classList.toggle('empty', !data.caption);
    document.body.classList.toggle('captioned', Boolean(data.caption));

    // The app sends [cover, station logo] when the song has a cover, and [station logo] alone when it has none: the
    // logo then takes the cover's place, whole, and is not shown twice. Since 2.4.5 the customData also names the
    // station and its logo, so the logo shows beside the cover whatever the images hold.
    const images = metadata.images || [];
    const cover = images[0] && images[0].url;
    const logo = (images[1] && images[1].url) || (data.logo === cover ? '' : data.logo);
    byId('stationName').textContent = data.station;
    byId('cover').classList.toggle('logo', Boolean(cover) && !logo);
    const backdrop = byId('backdrop');
    const showBackdrop = (url) => {
        // No picture for this song (none sent, or it did not load): no backdrop from the last one.
        backdrop.style.backgroundImage = url ? `url("${url}")` : '';
        backdrop.classList.toggle('shown', Boolean(url));
    };
    if (!cover) {
        showBackdrop(null);
    }

    showImage(byId('cover'), cover, showBackdrop);
    const station = byId('station');
    station.classList.toggle('empty', !logo && !data.station);
    showImage(station.querySelector('img'), logo);
    document.body.classList.remove('failed');
    document.body.classList.add('playing');
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
        show(media);
        const playing = player.getMediaInformation();
        if (playing) {
            // The new song's metadata whole: an album or a year the new song has none of must not stay.
            playing.metadata = media.metadata;
            playing.customData = media.customData;
            player.setMediaInformation(playing, true);
        }
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

/** The pause button shows what a tap does: pause while it plays, play while it is paused. */
function showPaused(paused) {
    const button = byId('playPause');
    button.textContent = paused ? '▶' : '⏸';
    button.setAttribute('aria-label', paused ? 'Play' : 'Pause');
}

player.addEventListener(EventType.PAUSE, () => showPaused(true));
player.addEventListener(EventType.PLAYING, () => showPaused(false));

// A touch display's taps: previous / next step through the group in the app, as the device's own buttons do.
byId('previous').addEventListener('click', () => step('previous'));
byId('next').addEventListener('click', () => step('next'));
byId('playPause').addEventListener('click', () => {
    if (player.getPlayerState() === cast.framework.messages.PlayerState.PAUSED) {
        player.play();
    } else {
        player.pause();
    }
});

/** Whether this device takes touch (Pixel Tablet, Nest Hub): its buttons show on the page then. */
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
