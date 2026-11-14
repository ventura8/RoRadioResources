// Copyright 2026 Sergiu Alexandrescu
// The Cast receiver's script (receiver/index.html): captions, previous / next and the steps it sends the app.
// Each test runs the page's inline script in a fresh Node context with the Cast framework and the page stubbed, plays
// messages through the interceptors the page registered, and checks what the page declared, drew and broadcast.
// Node's own test runner and assert, nothing to install: scripts/ci/Invoke-Tests.ps1 runs `node --test tests/*.test.js`.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'receiver', 'index.html'), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1, 'receiver/index.html has one inline script');
const source = scripts[0][1];

// The framework's own values (cast.framework.messages.Command).
const Command = { PAUSE: 1, SEEK: 2, STREAM_VOLUME: 4, STREAM_MUTE: 8, QUEUE_NEXT: 64, QUEUE_PREV: 128 };
const BASE = Command.PAUSE | Command.SEEK | Command.STREAM_VOLUME | Command.STREAM_MUTE;
const { QUEUE_NEXT, QUEUE_PREV } = Command;

function element() {
    const classes = new Set();
    return {
        textContent: '',
        dataset: {},
        style: {},
        classList: {
            toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)),
            add: (name) => classes.add(name),
            remove: (name) => classes.delete(name),
            has: (name) => classes.has(name),
        },
        removeAttribute(name) {
            delete this[name];
        },
    };
}

/** Loads the page in a fresh context, plays `messages` and returns what the page did. */
function run(messages) {
    const elements = {};
    const stationImage = element();
    const station = element();
    station.querySelector = () => stationImage;
    elements.station = station;
    const interceptors = {};
    const did = { commands: [], broadcasts: [], mediaInformation: [], results: [] };
    // The device starts with QUEUE_PREV on: the page must drop it unless the station has a previous one.
    let supported = BASE | QUEUE_PREV;
    let playing = { metadata: { title: 'Before' }, customData: '' };
    const player = {
        getSupportedMediaCommands: () => supported,
        setSupportedMediaCommands: (commands, broadcast) => {
            supported = commands;
            did.commands.push({ commands, broadcast });
        },
        broadcastStatus: (includeMedia, requestId, customData) => did.broadcasts.push({ includeMedia, customData }),
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
        addEventListener: () => undefined,
    };
    const types = ['LOAD', 'QUEUE_UPDATE', 'QUEUE_NEXT', 'QUEUE_PREV'];
    const sandbox = {
        cast: {
            framework: {
                CastReceiverContext: { getInstance: () => ({ getPlayerManager: () => player, start: () => (did.started = true) }) },
                CastReceiverOptions: function CastReceiverOptions() {},
                messages: { Command, MessageType: Object.fromEntries(types.map((type) => [type, type])) },
                events: { EventType: { MEDIA_FINISHED: 'MEDIA_FINISHED' } },
            },
        },
        document: { getElementById: (id) => (elements[id] ??= element()), body: element() },
        // Pictures load at once here, so the logo shown is the url the page asked for.
        Image: function Image() {
            return {
                set src(url) {
                    this.onload();
                },
            };
        },
        // A clock that stands still: the step ids must still rise.
        Date: { now: () => 1000 },
    };
    vm.runInNewContext(source, sandbox, { filename: 'receiver/index.html' });

    for (const message of messages) {
        const result = interceptors[message.type](message.request ?? {});
        did.results.push(result === null ? null : 'request');
    }

    did.caption = elements.captionText ? elements.captionText.textContent : '';
    did.title = elements.title ? elements.title.textContent : '';
    did.stationName = elements.stationName ? elements.stationName.textContent : '';
    did.logo = elements.station ? stationImage.src : undefined;
    did.stationShown = elements.station ? !elements.station.classList.has('empty') : false;
    did.supported = supported;
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

test('repeated jumps broadcast steps with rising ids, and play nothing', () => {
    const jump = (by) => ({ type: 'QUEUE_UPDATE', request: { jump: by } });
    const did = run([load(appData('', true, true)), jump(1), jump(-1), jump(1)]);
    assert.deepEqual(did.results, ['request', null, null, null]);
    assert.deepEqual(
        did.broadcasts.map((entry) => entry.customData.step),
        ['next', 'previous', 'next'],
    );
    const ids = did.broadcasts.map((entry) => entry.customData.stepId);
    for (let i = 1; i < ids.length; i++) {
        assert.ok(ids[i] > ids[i - 1], `step id ${ids[i]} rises above ${ids[i - 1]} on a clock that stands still`);
    }
    assert.ok(did.broadcasts.every((entry) => entry.includeMedia === false));
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

test('a logo that is already the cover (no song cover) is not shown twice', () => {
    const did = run([loadWith(['https://x/logo.png'], JSON.stringify({ logo: 'https://x/logo.png' }))]);
    assert.equal(did.logo, undefined);
    assert.equal(did.stationShown, false);
});
