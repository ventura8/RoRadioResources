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
const logoTone = path.join(__dirname, '..', 'receiver', 'logo-tone.js');
const themeScript = path.join(__dirname, '..', 'receiver', 'theme.js');
const layoutScript = path.join(__dirname, '..', 'receiver', 'layout-report.js');
const html = fs.readFileSync(path.join(__dirname, '..', 'receiver', 'index.html'), 'utf8');
assert.ok(html.includes('<script src="receiver.js"></script>'), 'receiver/index.html loads receiver.js');
assert.ok(
    html.indexOf('<script src="logo-tone.js"></script>') < html.indexOf('<script src="receiver.js"></script>'),
    'receiver/index.html loads logo-tone.js before receiver.js',
);
assert.ok(!/<script>/.test(html), 'receiver/index.html has no inline script');
const source = fs.readFileSync(script, 'utf8');

test('metadata that looks like markup is drawn as text, never parsed as HTML', () => {
    const markup = '<img src=x onerror=alert(1)>';
    const station = `${markup} FM`;
    const data = JSON.stringify({ caption: markup, station });
    const did = run([
        { type: 'LOAD', request: { media: { metadata: { title: markup, artist: markup }, customData: data } } },
    ]);
    assert.equal(did.title, markup);
    assert.equal(did.artist, markup);
    assert.equal(did.caption, markup);
    assert.equal(did.stationName, station);
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
        // Text fitting: a text `textHeight` line widths long at 40 px wraps to fewer lines as it shrinks; a line is
        // 1.25 times its font size.
        textHeight: 0,
        clientHeight: 0,
        get scrollHeight() {
            const size = parseFloat(this.style.fontSize || '40px');
            return Math.ceil((this.textHeight * size) / 40) * size * 1.25;
        },
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
        // Drawn boxes for the test mode's rects: a box the test set, else none (not drawn).
        getBoundingClientRect() {
            return this.box || { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
        },
    };
}

/** Loads the page in a fresh context, plays `messages` and returns what the page did. */
function run(
    messages,
    {
        touch = false,
        taps = [],
        playerState = 'PLAYING',
        pictures = 'load',
        coarse,
        capabilities,
        playingMedia,
        logoPixels = [255, 255, 255, 255],
        textHeights = {},
        roundFont = 0,
        boxes = {},
    } = {},
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
    const types = ['LOAD', 'QUEUE_UPDATE', 'QUEUE_NEXT', 'QUEUE_PREV', 'MEDIA_STATUS'];
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
                    // The tone measure's probe has no error handler: a logo it cannot read stays as it is.
                    if (probe.onerror) {
                        probe.onerror();
                    }
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
        window: {
            devicePixelRatio: 2,
            innerWidth: 1280,
            innerHeight: 800,
            addEventListener: (type, handler) => (did.windowEvents[type] = handler),
            ...(coarse === undefined ? {} : { matchMedia: (query) => ({ matches: coarse && query === '(pointer: coarse)' }) }),
        },
        // `roundFont`: a browser's rounding, a hair above the size it was given.
        getComputedStyle: (e) => {
            const fontSize = e.style.fontSize ? `${parseFloat(e.style.fontSize) + roundFont}px` : '40px';
            return { color: 'rgb(255, 255, 255)', fontSize, lineHeight: `${parseFloat(fontSize) * 1.25}px` };
        },
        document: {
            getElementById: (id) => (elements[id] ??= element()),
            body: element(),
            // The root's CSS variables (the theme's colours).
            documentElement: {
                style: {
                    vars: {},
                    setProperty(name, value) {
                        this.vars[name] = value;
                    },
                    removeProperty(name) {
                        delete this.vars[name];
                    },
                },
            },
            // A canvas that reads back `logoPixels` (RGBA), or throws as a picture without CORS does.
            createElement: () => ({
                getContext: () => ({
                    drawImage: () => undefined,
                    getImageData: () => {
                        if (logoPixels === 'tainted') {
                            throw new Error('The canvas has been tainted by cross-origin data.');
                        }

                        return { data: logoPixels };
                    },
                }),
            }),
        },
        Image,
    };
    // The page's globals for one fresh load of the script. The clock moves on a second before each message and tap
    // unless the message says otherwise (`gap`): a press repeated within a moment is the same press.
    const saved = Object.fromEntries(Object.keys(sandbox).map((name) => [name, globalThis[name]]));
    const now = Date.now;
    did.clock = 1000;
    Object.assign(globalThis, sandbox);
    Date.now = () => did.clock;
    did.windowEvents = {};
    for (const [id, height] of Object.entries(textHeights)) {
        sandbox.document.getElementById(id).textHeight = height;
    }

    for (const [id, drawn] of Object.entries(boxes)) {
        sandbox.document.getElementById(id).box = drawn;
    }

    try {
        // The page's scripts, in its order: the logo measure, the theme, then the receiver.
        delete require.cache[logoTone];
        require(logoTone);
        delete require.cache[themeScript];
        require(themeScript);
        delete require.cache[layoutScript];
        require(layoutScript);
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
    did.root = sandbox.document.documentElement.style;
    did.interceptors = interceptors;
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
    // Resent 0.7 s apart: past the moment between presses, within the time a resend comes in.
    const resent = { type: 'QUEUE_UPDATE', request: { jump: 1, requestId: 7, senderId: 'tablet' }, gap: 700 };
    const did = run([load(appData('', true, true)), resent, resent, resent, resent, resent, resent, resent]);
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

test('the tablet bar sends every press with one request id: later presses still step (one previous worked, then nothing)', () => {
    const bar = (jump, gap) => ({ type: 'QUEUE_UPDATE', request: { jump, requestId: 1, senderId: 'local' }, gap });
    const did = run([load(appData('', true, true)), bar(1), bar(-1, 7000), bar(1, 7000), bar(-1, 6000)]);
    assert.deepEqual(
        did.broadcasts.map((entry) => entry.customData.step),
        ['next', 'previous', 'next', 'previous'],
    );
    assert.equal(did.broadcasts[0].customData.via, 'local/1/next');

    // Next, then previous 2 s later and next again 0.8 s after: the bar's one request id, three presses (Greptile, #43).
    const quick = run([load(appData('', true, true)), bar(1), bar(-1, 2000), bar(1, 800)]);
    assert.deepEqual(
        quick.broadcasts.map((entry) => entry.customData.step),
        ['next', 'previous', 'next'],
    );

    // The same direction twice, 2 s apart (past a resend's time): two presses.
    const twice = run([load(appData('', true, true)), bar(1), bar(1, 2000)]);
    assert.equal(twice.broadcasts.length, 2);

    // Request id 0 (or none) tells no resend: only the moment between presses does.
    const zero = (gap) => ({ type: 'QUEUE_UPDATE', request: { jump: -1, requestId: 0, senderId: 'local' }, gap });
    const zeros = run([load(appData('', true, true)), zero(), zero(1000), zero(1000)]);
    assert.equal(zeros.broadcasts.length, 3);
    assert.equal(zeros.broadcasts[0].customData.via, '');
});

test('test mode reports a press taken for a repeat, and why; other apps never see it', () => {
    const data = JSON.stringify({ rects: true, previous: true, next: true });
    const resent = { type: 'QUEUE_UPDATE', request: { jump: 1, requestId: 9, senderId: 'tablet' }, gap: 700 };
    const did = run([load(data), resent, resent]);
    assert.deepEqual(did.statuses.at(-1).customData.skipped, 'next');
    assert.equal(did.statuses.at(-1).customData.via, 'tablet/9/next');

    // A resend after the device set its clock back is no resend: it steps.
    const setBack = run([load(appData('', true, true)), resent, { ...resent, gap: -60000 }]);
    assert.equal(setBack.broadcasts.length, 2);

    const plain = run([load(appData('', true, true)), resent, resent]);
    assert.ok(plain.statuses.every((s) => s.customData.skipped === undefined));
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
        theme: null,
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

test('test mode ({"rects": true}): the drawn boxes, their colours, the pixel ratio and the viewport, for the device E2E', () => {
    const data = JSON.stringify({ rects: true, station: 'Pro FM' });
    const did = run([{ type: 'LOAD', request: { media: { metadata: { title: 'Song' }, customData: data } } }]);
    assert.deepEqual(did.shown.rects, {});
    assert.equal(did.shown.scale, 2);
    assert.deepEqual(did.shown.viewport, [1280, 800]);

    did.elements.title.box = { left: 10, top: 20, right: 110, bottom: 60, width: 100, height: 40 };
    did.stationImage.box = { left: 0, top: 70, right: 50, bottom: 120, width: 50, height: 50 };
    did.within((more) => more([{ type: 'LOAD', request: { media: { metadata: { title: 'Song' }, customData: data } } }]));
    assert.deepEqual(did.shown.rects, {
        title: { box: [10, 20, 110, 60], color: 'rgb(255, 255, 255)' },
        station: { box: [0, 70, 50, 120], color: 'rgb(255, 255, 255)' },
    });

    // Without the flag (every app): no rects.
    assert.equal(run([load('')]).shown.rects, undefined);
});

/** RGBA pixels: `dark` dark opaque ones, `light` white opaque ones and `clear` see-through ones. */
const pixels = (dark, light, clear) => [
    ...Array(dark).fill([0, 20, 40, 255]).flat(),
    ...Array(light).fill([255, 255, 255, 255]).flat(),
    ...Array(clear).fill([0, 0, 0, 0]).flat(),
];

test('a dark logo (dark lettering on transparency) gets the light treatment; a light one does not', () => {
    const images = ['https://x/cover.jpg', 'https://x/logo.png'];
    assert.equal(run([loadWith(images, '')], { logoPixels: pixels(8, 2, 6) }).stationImage.classList.has('light'), true);
    assert.equal(run([loadWith(images, '')], { logoPixels: pixels(2, 8, 6) }).stationImage.classList.has('light'), false);
    // Nothing opaque, or a picture the canvas may not read (no CORS): readable as it is.
    assert.equal(run([loadWith(images, '')], { logoPixels: pixels(0, 0, 6) }).stationImage.classList.has('light'), false);
    assert.equal(run([loadWith(images, '')], { logoPixels: 'tainted' }).stationImage.classList.has('light'), false);
});

test('the logo in the cover\'s place is measured too; a song\'s cover never is', () => {
    const asCover = run([loadWith(['https://x/logo.png'], '')], { logoPixels: pixels(9, 1, 0) });
    assert.equal(asCover.elements.cover.classList.has('light'), true);
    const song = run([loadWith(['https://x/cover.jpg', 'https://x/logo.png'], '')], { logoPixels: pixels(9, 1, 0) });
    assert.equal(song.elements.cover.classList.has('light'), false);
});

test('a slow tone measure of an old logo never marks the new one', () => {
    const did = run([loadWith(['https://x/c.jpg', 'https://x/old.png'], '')], { pictures: 'later', logoPixels: pixels(9, 1, 0) });
    did.within((more) => more([loadWith(['https://x/c.jpg', 'https://x/new.png'], '')]));
    for (const probe of did.probes.filter((p) => p.url === 'https://x/old.png')) {
        did.within(() => probe.onload());
    }

    assert.equal(did.stationImage.classList.has('light'), false);
});

test('a text that fits two lines keeps its full size; a longer one shrinks in steps, never under 24 px at 1080p', () => {
    // Lengths in line widths at 40 px. At 800 px high the readable minimum is 24 * 800 / 1080 = 17.8 px.
    const did = run([load('', 'Song')], { textHeights: { title: 0.9, artist: 2.6, release: 30 } });
    assert.equal(did.elements.title.style.fontSize, '');
    // 2.6 lines at 40 px: 2.34 at 36 px, 2.1 at 32.4 px, 1.9 at 29.16 px: two lines.
    assert.equal(parseFloat(did.elements.artist.style.fontSize).toFixed(2), '29.16');
    // Far too long: down to the minimum, and no further (the styles then end its second line in an ellipsis).
    assert.equal(parseFloat(did.elements.release.style.fontSize).toFixed(2), (24 * 800 / 1080).toFixed(2));

    // The song's column too full for its three texts (a constant 50 px over its height): all shrink together, to
    // the minimum at most.
    const full = run([load('', 'Song')], { textHeights: { title: 1, artist: 1, release: 1, song: 1 } });
    for (const id of ['title', 'artist', 'release']) {
        assert.equal(parseFloat(full.elements[id].style.fontSize).toFixed(2), (24 * 800 / 1080).toFixed(2), id);
    }

    // The album line reaching into the station's line under it (tablet, a long song): all shrink too. With no
    // station's line (none sent), only the column's own height counts.
    const box = (top, bottom) => ({ left: 0, right: 10, width: 10, top, bottom, height: bottom - top });
    const into = run([load(JSON.stringify({ station: 'Pro FM' }), 'Song')], { boxes: { release: box(300, 420), station: box(400, 500) } });
    assert.equal(parseFloat(into.elements.release.style.fontSize).toFixed(2), (24 * 800 / 1080).toFixed(2));
    const noStation = run([load('', 'Song')], { boxes: { release: box(300, 420), station: box(400, 500) } });
    assert.equal(noStation.elements.release.style.fontSize, '');

    // A size the browser rounded a little above the minimum is the minimum: no endless shrinking to the same size.
    const rounded = run([load('', 'Song')], { textHeights: { release: 30 }, roundFont: 0.0001 });
    assert.ok(parseFloat(rounded.elements.release.style.fontSize) < 24 * 800 / 1080 + 0.5);

    // The screen changes size: fitted again from the full size.
    did.elements.artist.textHeight = 1.5;
    did.within(() => did.windowEvents.resize());
    assert.equal(did.elements.artist.style.fontSize, '');
});

test('no song (the station alone): its name once, never repeated as the title or the artist', () => {
    const did = run([
        { type: 'LOAD', request: { media: { metadata: { title: 'Pro FM', artist: ' pro fm ', albumName: 'Pro FM' }, customData: JSON.stringify({ station: 'Pro FM' }) } } },
    ]);
    assert.equal(did.stationName, 'Pro FM');
    assert.equal(did.title, '');
    assert.equal(did.artist, '');
    assert.equal(did.elements.album.textContent, '');
    assert.equal(did.elements.release.classList.has('empty'), true);
    const texts = [did.stationName, did.title, did.artist, did.elements.album.textContent].filter(Boolean);
    assert.equal(new Set(texts).size, texts.length, 'no text twice on screen');
});

test("a song's own fields may repeat each other: a title, album and artist that are one string all show", () => {
    const did = run([
        { type: 'LOAD', request: { media: { metadata: { title: 'Abba', artist: 'Abba', albumName: 'Abba' }, customData: JSON.stringify({ station: 'Pro FM' }) } } },
    ]);
    assert.deepEqual([did.title, did.artist, did.elements.album.textContent], ['Abba', 'Abba', 'Abba']);
});

test('a touch display is marked, so the page keeps clear of its system media bar', () => {
    assert.equal(run([], { touch: true }).touch, true);
    assert.equal(run([]).touch, false);
});

test('no buttons of its own: the system media bar has previous / pause / next, and a step the station lacks is not declared', () => {
    const did = run([load(JSON.stringify({ previous: false, next: true }))], { touch: true });
    assert.deepEqual(did.shown.steps, { next: true, previous: false });
    assert.equal(did.supported, BASE | QUEUE_NEXT);
    assert.equal(did.elements.previous, undefined);
    assert.equal(did.elements.next, undefined);
    assert.equal(did.elements.playPause, undefined);
    assert.ok(!/<button/.test(html), 'receiver/index.html has no buttons');
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

    // No picture in the cover's place: the station's logo is the backdrop.
    const logoOnly = run([loadWith([], JSON.stringify({ logo: 'https://x/logo.png' }))]);
    assert.equal(logoOnly.elements.backdrop.style.backgroundImage, 'url("https://x/logo.png")');
});

test('every outgoing media status, a GET_STATUS answer too, says what the screen shows; a step press keeps its data', () => {
    const did = run([load(JSON.stringify({ station: 'Pro FM' }), 'Song')]);
    const status = did.within(() => did.interceptors.MEDIA_STATUS({ playerState: 'PLAYING' }));
    assert.equal(status.customData.shown.title, 'Song');
    const press = { step: 'next', stepId: 5 };
    assert.equal(did.within(() => did.interceptors.MEDIA_STATUS({ customData: press })).customData, press);
});

test("the app's cover colour theme: its colours on the page and in the status; off, the default look", () => {
    const themed = JSON.stringify({ theme: { accent: '#F0E040', tint: '#5A5418' } });
    const did = run([load(themed)]);
    assert.equal(did.body.classList.has('themed'), true);
    assert.deepEqual(did.root.vars, { '--theme-tint': '#5a5418', '--accent': '#f0e040' });
    assert.deepEqual(did.shown.theme, { accent: '#f0e040', tint: '#5a5418' });

    // Switched off in the app: the next song comes without a theme, and the page is back to its own look.
    did.within((more) => more([update('', 'Next')]));
    assert.equal(did.body.classList.has('themed'), false);
    assert.deepEqual(did.root.vars, {});
    assert.equal(did.shown.theme, null);

    // Anything but two #rrggbb colours is no theme (never CSS from a sender).
    for (const bad of [{ accent: 'red', tint: '#000000' }, { accent: '#000000' }, { accent: ['#f0e040'], tint: '#000000' }, 'dark', null, 5]) {
        const plain = run([load(JSON.stringify({ theme: bad, station: 'Pro FM', next: true }), 'Song')]);
        assert.equal(plain.body.classList.has('themed'), false, JSON.stringify(bad));
        // A bad theme costs nothing else of the item: its station and steps stay (#46).
        assert.equal(plain.stationName, 'Pro FM', JSON.stringify(bad));
        assert.equal(plain.supported, BASE | QUEUE_NEXT, JSON.stringify(bad));
    }
});

test('a slow old picture never replaces a newer one, loaded or failed', () => {
    const did = run([loadWith(['https://x/old.jpg'], '')], { pictures: 'later' });
    did.within((more) => more([loadWith(['https://x/new.jpg'], '')]));
    const [oldCover, newCover] = did.probes.filter((probe) => probe.crossOrigin === undefined);
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
