// Copyright 2026 Sergiu Alexandrescu
// The Cast receiver's script (receiver/receiver.js): song, pictures, captions, previous / next, touch buttons, status.
// Each test loads the script afresh with the Cast framework and the page stubbed as globals, plays messages through the
// interceptors the page registered, and checks what the page declared, drew and broadcast. Loaded with require, so
// Node's coverage measures it: scripts/ci/Invoke-Tests.ps1 fails below 100 % lines, branches and functions.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const script = path.join(__dirname, '..', 'receiver', 'receiver.js');
const html = fs.readFileSync(path.join(__dirname, '..', 'receiver', 'index.html'), 'utf8');
assert.ok(html.includes('<script src="receiver.js"></script>'), 'receiver/index.html loads receiver.js');
assert.ok(!/<script>/.test(html), 'receiver/index.html has no inline script');
const source = fs.readFileSync(script, 'utf8');

test('metadata that looks like markup is drawn as text, never parsed as HTML', () => {
    const markup = '<img src=x onerror=alert(1)>';
    const data = JSON.stringify({ caption: markup, station: markup });
    const did = run([
        { type: 'LOAD', request: { media: { metadata: { title: markup, artist: markup }, customData: data } } },
    ]);
    assert.equal(did.title, markup);
    assert.equal(did.artist, markup);
    assert.equal(did.caption, markup);
    assert.equal(did.stationName, markup);
    // No API that parses HTML or code anywhere in the page's script.
    for (const sink of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', "setTimeout('"]) {
        assert.ok(!source.includes(sink), `receiver/receiver.js uses ${sink}`);
    }
});

test('only http(s) pictures are shown, and a quote cannot break out of the backdrop url', () => {
    for (const bad of ['javascript:alert(1)', 'data:image/svg+xml,<svg onload=alert(1)>', 'not a url', 42]) {
        const did = run([loadWith([bad], JSON.stringify({ logo: bad }))]);
        assert.equal(did.cover, undefined, String(bad));
        assert.equal(did.logo, undefined, String(bad));
        assert.equal(did.backdrop, '', String(bad));
    }

    const did = run([loadWith(['https://x/a.jpg?q=")"; background:red'], '')]);
    assert.equal(did.cover, 'https://x/a.jpg?q=%22)%22;%20background:red');
    assert.equal(did.backdrop, 'url("https://x/a.jpg?q=%22)%22;%20background:red")');
});

test('the Content-Security-Policy allows the page\'s own receiver.js, no inline script and never eval', () => {
    const csp = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/);
    assert.ok(csp, 'receiver/index.html declares a Content-Security-Policy');
    const scriptSrc = csp[1].match(/script-src ([^;]*)/)[1];
    assert.match(csp[1], /^default-src 'none';/);
    assert.ok(scriptSrc.split(' ').includes("'self'"), "script-src allows 'self' (receiver.js)");
    assert.match(scriptSrc, /https:\/\/www\.gstatic\.com/);
    assert.ok(!scriptSrc.includes("'sha256-"), 'no inline-script hash: the page has no inline script');
    assert.ok(!scriptSrc.includes("'unsafe-inline'"));
    assert.ok(!csp[1].includes('unsafe-eval'));
});

// The framework's own values (cast.framework.messages.Command).
const Command = { PAUSE: 1, SEEK: 2, STREAM_VOLUME: 4, STREAM_MUTE: 8, QUEUE_NEXT: 64, QUEUE_PREV: 128 };
const BASE = Command.PAUSE | Command.SEEK | Command.STREAM_VOLUME | Command.STREAM_MUTE;
const { QUEUE_NEXT, QUEUE_PREV } = Command;

function element() {
    const classes = new Set();
    return {
        textContent: '',
        dataset: {},
        listeners: {},
        attributes: {},
        addEventListener(type, handler) {
            this.listeners[type] = handler;
        },
        setAttribute(name, value) {
            this.attributes[name] = value;
        },
        style: {},
        classList: {
            toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)),
            add: (name) => classes.add(name),
            remove: (name) => classes.delete(name),
            has: (name) => classes.has(name),
            contains: (name) => classes.has(name),
        },
        removeAttribute(name) {
            delete this[name];
        },
        hasAttribute(name) {
            return this[name] !== undefined;
        },
    };
}

/** Loads the page in a fresh context, plays `messages` and returns what the page did. */
function run(
    messages,
    { touch = false, taps = [], playerState = 'PLAYING', pictures = 'load', coarse, capabilities, playingMedia } = {},
) {
    const elements = {};
    const stationImage = element();
    const station = element();
    station.querySelector = () => stationImage;
    elements.station = station;
    const interceptors = {};
    const did = { commands: [], broadcasts: [], statuses: [], mediaInformation: [], results: [] };
    // The device starts with QUEUE_PREV on: the page must drop it unless the station has a previous one.
    let supported = BASE | QUEUE_PREV;
    let playing = playingMedia === undefined ? { metadata: { title: 'Before' }, customData: '' } : playingMedia;
    const player = {
        getSupportedMediaCommands: () => supported,
        setSupportedMediaCommands: (commands, broadcast) => {
            supported = commands;
            did.commands.push({ commands, broadcast });
        },
        // Every status the page sends says what it shows (did.shown, the last one); a step press is also in did.broadcasts.
        broadcastStatus: (includeMedia, requestId, customData) => {
            did.statuses.push({ includeMedia, requestId, customData });
            did.shown = customData.shown;
            if (customData.step) {
                did.broadcasts.push({ includeMedia, customData });
            }
        },
        getMediaInformation: () => playing,
        setMediaInformation: (media, broadcast) => {
            playing = media;
            did.mediaInformation.push({ customData: media.customData, title: media.metadata.title, broadcast });
        },
        setMessageInterceptor: (type, handler) => {
            // As the real framework (2026-11-14): these are message types, but no interceptor may take them.
            if (type === 'QUEUE_NEXT' || type === 'QUEUE_PREV') {
                throw new Error(`Unknown message type - ${type}`);
            }

            interceptors[type] = handler;
        },
        addEventListener: (type, handler) => (did.playerEvents[type] = handler),
        getPlayerState: () => playerState,
        play: () => did.calls.push('play'),
        pause: () => did.calls.push('pause'),
        setMediaElement: (media) => (did.mediaElement = media),
    };
    did.playerEvents = {};
    did.calls = [];
    const types = ['LOAD', 'QUEUE_UPDATE', 'QUEUE_NEXT', 'QUEUE_PREV'];
    const context = {
        getPlayerManager: () => player,
        start: (options) => {
            did.started = true;
            did.options = options;
        },
        addEventListener: (type, handler) => (did.contextEvents = { [type]: handler }),
        getDeviceCapabilities: () => {
            if (capabilities === 'throws') {
                throw new Error('not ready');
            }

            return capabilities === 'none' ? null : { touch_input_supported: touch };
        },
    };
    // Pictures load at once ('load'), fail ('error'), or wait for the test to settle them ('later').
    did.probes = [];
    function Image() {
        const probe = {};
        Object.defineProperty(probe, 'src', {
            set(url) {
                probe.url = url;
                if (pictures === 'load') {
                    probe.onload();
                } else if (pictures === 'error') {
                    probe.onerror();
                } else {
                    did.probes.push(probe);
                }
            },
        });
        return probe;
    }
    const sandbox = {
        cast: {
            framework: {
                CastReceiverContext: { getInstance: () => context },
                CastReceiverOptions: function CastReceiverOptions() {},
                messages: {
                    Command,
                    MessageType: Object.fromEntries(types.map((type) => [type, type])),
                    PlayerState: { PLAYING: 'PLAYING', PAUSED: 'PAUSED' },
                },
                events: { EventType: { MEDIA_FINISHED: 'MEDIA_FINISHED', ERROR: 'ERROR', PAUSE: 'PAUSE', PLAYING: 'PLAYING' } },
                system: { DeviceCapabilities: { TOUCH_INPUT_SUPPORTED: 'touch_input_supported' }, EventType: { READY: 'ready' } },
                ui: { UiConfig: function UiConfig() {} },
            },
        },
        window: coarse === undefined ? {} : { matchMedia: (query) => ({ matches: coarse && query === '(pointer: coarse)' }) },
        document: { getElementById: (id) => (elements[id] ??= element()), body: element() },
        Image,
    };
    // The page's globals for one fresh load of the script. The clock moves on a second before each message and tap
    // unless the message says otherwise (`gap`): a press repeated within a moment is the same press.
    const saved = Object.fromEntries(Object.keys(sandbox).map((name) => [name, globalThis[name]]));
    const now = Date.now;
    did.clock = 1000;
    Object.assign(globalThis, sandbox);
    Date.now = () => did.clock;
    try {
        delete require.cache[script];
        require(script);
        play(messages, interceptors, did);
        for (const id of taps) {
            did.clock += 1000;
            elements[id].listeners.click();
        }
    } finally {
        Date.now = now;
        Object.assign(globalThis, saved);
    }

    did.body = sandbox.document.body;
    did.stationImage = stationImage;
    // Later work in the same page (more messages, a framework event, a picture that settles), with its globals.
    did.within = (work) => {
        Object.assign(globalThis, sandbox);
        Date.now = () => did.clock;
        try {
            return work((more) => play(more, interceptors, did));
        } finally {
            Date.now = now;
            Object.assign(globalThis, saved);
        }
    };
    return finish(did, elements, stationImage, sandbox, () => supported);
}

/** Plays `messages` through the page's interceptors. */
function play(messages, interceptors, did) {
    for (const message of messages) {
        did.clock += message.gap ?? 1000;
        const result = interceptors[message.type](message.request ?? {});
        did.results.push(result === null ? null : 'request');
    }
}

/** What the page shows, read into `did`. */
function finish(did, elements, stationImage, sandbox, supported) {

    did.touch = sandbox.document.body.classList.has('touch');
    did.elements = elements;

    did.caption = elements.captionText ? elements.captionText.textContent : '';
    did.title = elements.title ? elements.title.textContent : '';
    did.stationName = elements.stationName ? elements.stationName.textContent : '';
    did.logo = elements.station ? stationImage.src : undefined;
    did.stationShown = elements.station ? !elements.station.classList.has('empty') : false;
    did.cover = elements.cover ? elements.cover.src : undefined;
    did.backdrop = elements.backdrop ? elements.backdrop.style.backgroundImage : undefined;
    did.artist = elements.artist ? elements.artist.textContent : '';
    did.supported = supported();
    return did;
}

/** A LOAD of a station whose item carries `customData`. */
const load = (customData, title = 'Song') => ({ type: 'LOAD', request: { media: { metadata: { title }, customData } } });

/** The app's QUEUE_UPDATE of the item playing: a song change or a caption. */
const update = (customData, title = 'Next song') => ({
    type: 'QUEUE_UPDATE',
    request: { items: [{ media: { metadata: { title }, customData } }] },
});

/** The customData the app sends: JSON text. */
const appData = (caption, previous, next) => JSON.stringify({ caption, previous, next });

test('a bare string (older app builds) is the caption alone, with no steps', () => {
    const did = run([load('Hello from an old build')]);
    assert.equal(did.caption, 'Hello from an old build');
    assert.deepEqual(did.commands, [{ commands: BASE, broadcast: true }]);
});

test('a caption that starts with a brace but is not JSON stays the caption', () => {
    const did = run([load('{not json')]);
    assert.equal(did.caption, '{not json');
    assert.equal(did.supported, BASE);
});

test('JSON declares exactly the steps the station has', () => {
    const cases = [
        [false, false, BASE],
        [true, false, BASE | QUEUE_PREV],
        [false, true, BASE | QUEUE_NEXT],
        [true, true, BASE | QUEUE_PREV | QUEUE_NEXT],
    ];
    for (const [previous, next, expected] of cases) {
        const did = run([load(appData('Live words', previous, next))]);
        assert.equal(did.caption, 'Live words');
        assert.equal(did.supported, expected, `previous ${previous}, next ${next}`);
    }
});

test('only true is a step, and a missing or non-text caption is none', () => {
    const did = run([load(JSON.stringify({ previous: 'yes', next: 1, caption: 5 }))]);
    assert.equal(did.caption, '');
    assert.equal(did.supported, BASE);
});

test('a later item without steps removes the buttons the earlier one declared', () => {
    const did = run([load(appData('', true, true)), update(appData('', false, false))]);
    assert.deepEqual(
        did.commands.map((entry) => entry.commands),
        [BASE | QUEUE_PREV | QUEUE_NEXT, BASE],
    );
});

test('the page starts the receiver, or the launch is never answered and the app falls back', () => {
    assert.equal(run([]).started, true);
});

test('repeated jumps broadcast steps with rising ids, and play nothing, even on a clock set back', () => {
    const jump = (by) => ({ type: 'QUEUE_UPDATE', request: { jump: by }, gap: -100 });
    const did = run([load(appData('', true, true)), jump(1), jump(-1), jump(1)]);
    assert.deepEqual(did.results, ['request', null, null, null]);
    assert.deepEqual(
        did.broadcasts.map((entry) => entry.customData.step),
        ['next', 'previous', 'next'],
    );
    const ids = did.broadcasts.map((entry) => entry.customData.stepId);
    for (let i = 1; i < ids.length; i++) {
        assert.ok(ids[i] > ids[i - 1], `step id ${ids[i]} rises above ${ids[i - 1]} on a clock set back`);
    }
    assert.ok(did.broadcasts.every((entry) => entry.includeMedia === false));
});

test('one press is one step: a jump resent with its request id, or repeated at once, steps once (Pixel Tablet)', () => {
    const resent = { type: 'QUEUE_UPDATE', request: { jump: 1, requestId: 7, senderId: 'tablet' } };
    const did = run([load(appData('', true, true)), resent, resent, resent, resent, resent]);
    assert.deepEqual(
        did.broadcasts.map((entry) => entry.customData.step),
        ['next'],
    );

    const quick = { type: 'QUEUE_UPDATE', request: { jump: 1 }, gap: 100 };
    const fast = run([load(appData('', true, true)), quick, quick, quick]);
    assert.equal(fast.broadcasts.length, 1);

    // Another sender's request with the same number, a moment later, is its own press.
    const other = { type: 'QUEUE_UPDATE', request: { jump: -1, requestId: 7, senderId: 'phone' } };
    const both = run([resent, other]);
    assert.deepEqual(
        both.broadcasts.map((entry) => entry.customData.step),
        ['next', 'previous'],
    );
});

test('every status tells the senders what the screen shows: song, station, caption, pictures, steps', () => {
    const data = JSON.stringify({ caption: 'Words', previous: true, next: false, station: 'Pro FM' });
    const did = run([
        {
            type: 'LOAD',
            request: { media: { metadata: { title: 'Song', artist: 'Band', images: [{ url: 'https://x/c.jpg' }, { url: 'https://x/l.png' }] }, customData: data } },
        },
    ]);
    assert.deepEqual(did.shown, {
        title: 'Song',
        artist: 'Band',
        station: 'Pro FM',
        caption: 'Words',
        logo: true,
        cover: true,
        steps: { previous: true, next: false },
        defaultTitle: false,
    });
    assert.ok(did.statuses.every((s) => s.requestId === 0 && s.includeMedia === false));
});

test('the station alone, before its song: defaultTitle, and no picture that did not load', () => {
    const named = run([load(JSON.stringify({ station: 'Pro FM' }), 'Pro FM')], { pictures: 'error' });
    assert.equal(named.shown.defaultTitle, true);
    assert.equal(named.shown.cover, false);
    assert.equal(named.shown.logo, false);
    assert.equal(run([{ type: 'LOAD', request: { media: {} } }]).shown.defaultTitle, true);
});

test('a step press carries the screen too, and an older app still reads its step and id', () => {
    const did = run([load(appData('', true, true)), { type: 'QUEUE_UPDATE', request: { jump: 1 } }]);
    const press = did.broadcasts[0].customData;
    assert.equal(press.step, 'next');
    assert.equal(typeof press.stepId, 'number');
    assert.equal(press.shown.title, 'Song');
});

test('a double tap on a touch button within a moment is one step', () => {
    const did = run([load(appData('', true, true))], { taps: ['next'] });
    did.within(() => did.elements.next.listeners.click());
    assert.equal(did.broadcasts.length, 1);
});

test("a sender's queue jump of +1 / -1 is a step, and the song is left alone", () => {
    const did = run([
        load('caption', 'Playing'),
        { type: 'QUEUE_UPDATE', request: { jump: 1 } },
        { type: 'QUEUE_UPDATE', request: { jump: -1 } },
    ]);
    assert.deepEqual(did.results, ['request', null, null]);
    assert.deepEqual(
        did.broadcasts.map((entry) => entry.customData.step),
        ['next', 'previous'],
    );
    assert.equal(did.title, 'Playing');
    assert.deepEqual(did.mediaInformation, []);
});

test("the app's metadata update shows the song, reaches the senders and sends no step", () => {
    const data = appData('New words', false, true);
    const did = run([load('', 'Old'), update(data, 'New')]);
    assert.deepEqual(did.results, ['request', 'request']);
    assert.deepEqual(did.broadcasts, []);
    assert.equal(did.title, 'New');
    assert.equal(did.caption, 'New words');
    assert.equal(did.supported, BASE | QUEUE_NEXT);
    assert.deepEqual(did.mediaInformation, [{ customData: data, title: 'New', broadcast: true }]);
});

test('a jump other than +1 / -1 is passed on to the player', () => {
    const did = run([{ type: 'QUEUE_UPDATE', request: { jump: 2 } }]);
    assert.deepEqual(did.results, ['request']);
    assert.deepEqual(did.broadcasts, []);
});

/** A LOAD of a song with these `images` and the app's customData. */
const loadWith = (images, customData) => ({
    type: 'LOAD',
    request: { media: { metadata: { title: 'Song', images: images.map((url) => ({ url })) }, customData } },
});

test('the station name comes from the app, and nothing at all when the app sends none', () => {
    const named = run([loadWith(['https://x/cover.jpg'], JSON.stringify({ station: 'Rock FM' }))]);
    assert.equal(named.stationName, 'Rock FM');
    assert.ok(named.stationShown);

    for (const customData of ['', 'old caption', JSON.stringify({ station: 5 })]) {
        const did = run([loadWith([], customData)]);
        assert.equal(did.stationName, '');
        assert.equal(did.stationShown, false);
    }
});

test('the station logo shows beside the song cover', () => {
    const fromImages = run([loadWith(['https://x/cover.jpg', 'https://x/logo.png'], '')]);
    assert.equal(fromImages.logo, 'https://x/logo.png');

    const fromData = run([loadWith(['https://x/cover.jpg'], JSON.stringify({ logo: 'https://x/logo.png' }))]);
    assert.equal(fromData.logo, 'https://x/logo.png');
    assert.ok(fromData.stationShown);
});

test('a touch display gets this page, not the default audio UI: own media element and touchScreenOptimizedApp', () => {
    const did = run([]);
    assert.equal(did.options.uiConfig.touchScreenOptimizedApp, true);
    assert.equal(did.mediaElement, did.elements.media);
    assert.equal(did.options.maxInactivity, 3600);
});

test('the buttons show on a touch display only', () => {
    assert.equal(run([], { touch: true }).touch, true);
    assert.equal(run([]).touch, false);
});

test('tapping previous / next steps through the group in the app, like the device buttons', () => {
    const data = JSON.stringify({ previous: true, next: true });
    const did = run([load(data)], { touch: true, taps: ['next', 'previous'] });
    assert.deepEqual(
        did.broadcasts.map((b) => b.customData.step),
        ['next', 'previous'],
    );
    assert.equal(did.elements.previous.classList.has('hidden'), false);
    assert.equal(did.elements.next.classList.has('hidden'), false);
});

test('a step the station lacks hides its button', () => {
    const did = run([load(JSON.stringify({ previous: false, next: true }))], { touch: true });
    assert.equal(did.elements.previous.classList.has('hidden'), true);
    assert.equal(did.elements.next.classList.has('hidden'), false);
});

test('the pause button pauses while it plays, plays while paused, and shows which', () => {
    assert.deepEqual(run([], { taps: ['playPause'] }).calls, ['pause']);
    const paused = run([], { taps: ['playPause'], playerState: 'PAUSED' });
    assert.deepEqual(paused.calls, ['play']);
    paused.within(() => paused.playerEvents.PAUSE());
    assert.equal(paused.elements.playPause.attributes['aria-label'], 'Play');
    assert.equal(paused.elements.playPause.textContent, '▶');
    paused.within(() => paused.playerEvents.PLAYING());
    assert.equal(paused.elements.playPause.textContent, '⏸');
    assert.equal(paused.elements.playPause.attributes['aria-label'], 'Pause');
});

test('a logo that is already the cover (no song cover) is not shown twice', () => {
    const did = run([loadWith(['https://x/logo.png'], JSON.stringify({ logo: 'https://x/logo.png' }))]);
    assert.equal(did.logo, undefined);
    assert.equal(did.stationShown, false);
});

test('a song with no app data and no metadata fields shows empty text, not "undefined"', () => {
    const did = run([{ type: 'LOAD', request: { media: {} } }, { type: 'LOAD', request: {} }]);
    assert.equal(did.title, '');
    assert.equal(did.caption, '');
    assert.equal(did.elements.artist.textContent, '');
    assert.equal(did.elements.release.classList.has('empty'), true);
    assert.equal(did.body.classList.has('playing'), true);
});

test('the song name, subtitle, album and year are used when the main fields are missing', () => {
    const metadata = { songName: 'Name', subtitle: 'Sub', albumName: 'Album', releaseDate: '2015-03-01' };
    const did = run([{ type: 'LOAD', request: { media: { metadata } } }]);
    assert.equal(did.title, 'Name');
    assert.equal(did.elements.artist.textContent, 'Sub');
    assert.equal(did.elements.album.textContent, 'Album');
    assert.equal(did.elements.year.textContent, '2015');
    assert.equal(did.elements.release.classList.has('empty'), false);
});

test('a cover that loads is the backdrop; one that fails leaves no picture and no backdrop', () => {
    const shown = run([loadWith(['https://x/cover.jpg'], '')]);
    assert.equal(shown.elements.cover.src, 'https://x/cover.jpg');
    assert.equal(shown.elements.backdrop.style.backgroundImage, 'url("https://x/cover.jpg")');
    assert.equal(shown.elements.cover.classList.has('logo'), true);

    const failed = run([loadWith(['https://x/cover.jpg', 'https://x/logo.png'], '')], { pictures: 'error' });
    assert.equal(failed.elements.cover.src, undefined);
    assert.equal(failed.logo, undefined);
    assert.equal(failed.elements.backdrop.style.backgroundImage, '');
    assert.equal(failed.elements.backdrop.classList.has('shown'), false);
});

test('a slow old picture never replaces a newer one, loaded or failed', () => {
    const did = run([loadWith(['https://x/old.jpg'], '')], { pictures: 'later' });
    did.within((more) => more([loadWith(['https://x/new.jpg'], '')]));
    const [oldCover, newCover] = did.probes;
    did.within(() => newCover.onload());
    did.within(() => oldCover.onload());
    did.within(() => oldCover.onerror());
    assert.equal(did.elements.cover.src, 'https://x/new.jpg');
    assert.equal(did.elements.backdrop.style.backgroundImage, 'url("https://x/new.jpg")');
});

test('a station that ends goes back to the idle screen; a failed stream says why', () => {
    const did = run([load('')]);
    did.within(() => did.playerEvents.MEDIA_FINISHED({ endedReason: 'END_OF_STREAM' }));
    assert.equal(did.body.classList.has('playing'), false);
    assert.equal(did.body.classList.has('failed'), false);
    assert.equal(did.elements.status.textContent, 'Ready to play');

    did.within(() => did.playerEvents.MEDIA_FINISHED({ endedReason: 'ERROR' }));
    assert.equal(did.body.classList.has('failed'), true);
    assert.match(did.elements.status.textContent, /could not be played/);

    did.within(() => did.playerEvents.MEDIA_FINISHED());
    assert.equal(did.body.classList.has('failed'), false);

    did.within(() => did.playerEvents.ERROR({}));
    assert.equal(did.body.classList.has('failed'), true);
    did.within((more) => more([load('')]));
    assert.equal(did.body.classList.has('failed'), false);
    assert.equal(did.body.classList.has('playing'), true);
});

test('touch comes from the device, else from a coarse pointer; a device not ready yet leaves it to the pointer', () => {
    assert.equal(run([], { capabilities: 'throws', coarse: true }).touch, true);
    assert.equal(run([], { capabilities: 'none', coarse: false }).touch, false);
    assert.equal(run([], { capabilities: 'none' }).touch, false);
    const later = run([], { touch: true, capabilities: 'throws' });
    assert.equal(later.touch, false);
    later.within(() => later.contextEvents.ready());
    assert.equal(later.body.classList.has('touch'), false);
});

test('an update with no item, or before the player has media, is shown and passed on without failing', () => {
    const empty = run([{ type: 'QUEUE_UPDATE', request: { items: [] } }, { type: 'QUEUE_UPDATE', request: { items: [{}] } }]);
    assert.deepEqual(empty.results, ['request', 'request']);
    assert.deepEqual(empty.mediaInformation, []);

    const noPlayer = run([update('', 'New')], { playingMedia: null });
    assert.equal(noPlayer.title, 'New');
    assert.deepEqual(noPlayer.mediaInformation, []);
});
