// Copyright 2026 Sergiu Alexandrescu
// The Cast receiver page (receiver/index.html) in headless Chrome with Google's REAL Cast receiver framework (CAF v3,
// loaded from gstatic.com as on a device). The stubs of tests/receiver.test.js cannot catch what the framework itself
// rejects: #33 set an interceptor for QUEUE_NEXT, the real framework threw "Unknown message type - QUEUE_NEXT" before
// context.start(), and every device fell back to the Default Media Receiver. This test fails on exactly that.
//
// Nothing to install: Node's own test runner, http server and WebSocket drive Chrome over the DevTools protocol.
// Chrome comes from CHROME_PATH, else the usual install paths (ubuntu-latest has google-chrome). The page is served
// unchanged from a local server; one probe script, inserted right after the framework's <script> tag, wraps the real
// CastReceiverContext and PlayerManager (every call still reaches the framework) to record what the page did.
'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const SDK = 'https://www.gstatic.com/cast/sdk/libs/caf_receiver/v3/cast_receiver_framework.js';
const page = fs.readFileSync(path.join(__dirname, '..', 'receiver', 'index.html'), 'utf8');
const sdkTag = `<script src="${SDK}"></script>`;
assert.ok(page.includes(sdkTag), 'receiver/index.html loads the real framework from gstatic.com');

/**
 * Runs in the page right after the framework loaded: records what the page's script asks of the real framework,
 * calling the framework every time, so an error the framework throws still reaches the page.
 */
function probe() {
    const record = {
        started: false,
        interceptors: [],
        interceptorErrors: [],
        commands: [],
        broadcasts: [],
        mediaInformation: [],
    };
    window.probe = record;
    window.interceptors = {};
    const Context = cast.framework.CastReceiverContext;
    const getInstance = Context.getInstance.bind(Context);
    let wrapped = null;
    Context.getInstance = () => {
        const context = getInstance();
        if (wrapped) {
            return context;
        }

        wrapped = context;
        const start = context.start.bind(context);
        context.start = (options) => {
            record.started = true;
            record.maxInactivity = options && options.maxInactivity;
            // Off a device the framework has no platform to answer it; reaching start() is the page's part.
            try {
                return start(options);
            } catch (e) {
                record.startError = String(e);
                return context;
            }
        };
        const player = context.getPlayerManager();
        const setMessageInterceptor = player.setMessageInterceptor.bind(player);
        player.setMessageInterceptor = (type, handler) => {
            try {
                setMessageInterceptor(type, handler);
            } catch (e) {
                record.interceptorErrors.push(`${type}: ${e.message}`);
                throw e;
            }

            record.interceptors.push(type);
            window.interceptors[type] = handler;
        };
        const addEventListener = player.addEventListener.bind(player);
        window.events = {};
        player.addEventListener = (type, handler) => {
            window.events[type] = handler;
            return addEventListener(type, handler);
        };
        const setSupported =player.setSupportedMediaCommands.bind(player);
        player.setSupportedMediaCommands = (commands, broadcast) => {
            record.commands.push(commands);
            return setSupported(commands, broadcast);
        };
        player.broadcastStatus = (includeMedia, requestId, customData) => {
            record.broadcasts.push(customData);
        };
        // No media session off a device: the media information the page gives the player is kept here.
        let playing = null;
        player.getMediaInformation = () => playing;
        player.setMediaInformation = (media) => {
            playing = media;
            record.mediaInformation.push(JSON.parse(JSON.stringify(media)));
        };
        window.setPlaying = (media) => {
            playing = media;
        };
        return context;
    };
}

/** The page as a device gets it, with the probe after the framework; pictures served from /img/<name>.png. */
function serve(withPage) {
    const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        'base64',
    );
    const server = http.createServer((request, response) => {
        if (request.url === '/receiver/') {
            const html = withPage.replace(sdkTag, `${sdkTag}\n<script>(${probe})();</script>`);
            response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
            response.end(html);
        } else if (request.url.startsWith('/img/')) {
            response.writeHead(200, { 'content-type': 'image/png' });
            response.end(png);
        } else {
            response.writeHead(404);
            response.end();
        }
    });
    return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

function chromePath() {
    const candidates = [
        process.env.CHROME_PATH,
        'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
        'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    ];
    const found = candidates.find((candidate) => candidate && fs.existsSync(candidate));
    assert.ok(found, 'Chrome is needed for the receiver page test: install it or set CHROME_PATH');
    return found;
}

async function waitFor(condition, what, timeout = 20000) {
    const end = Date.now() + timeout;
    for (;;) {
        const value = await condition();
        if (value) {
            return value;
        }

        if (Date.now() > end) {
            throw new Error(`Timed out waiting for ${what}`);
        }

        await new Promise((resolve) => setTimeout(resolve, 100));
    }
}

/** Headless Chrome and one DevTools connection to a fresh page target. */
async function launch() {
    const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'receiver-chrome-'));
    const chrome = spawn(
        chromePath(),
        [
            '--headless=new',
            '--remote-debugging-port=0',
            `--user-data-dir=${profile}`,
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-gpu',
            '--no-sandbox',
            '--window-size=1280,720',
            'about:blank',
        ],
        { stdio: 'ignore' },
    );
    const portFile = path.join(profile, 'DevToolsActivePort');
    const port = await waitFor(() => fs.existsSync(portFile) && fs.readFileSync(portFile, 'utf8').split('\n')[0], 'Chrome');
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const target = targets.find((t) => t.type === 'page');
    const socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
        socket.onopen = resolve;
        socket.onerror = reject;
    });
    let nextId = 0;
    const pending = new Map();
    const listeners = [];
    socket.onmessage = (event) => {
        const message = JSON.parse(event.data);
        if (message.id && pending.has(message.id)) {
            const { resolve, reject } = pending.get(message.id);
            pending.delete(message.id);
            if (message.error) {
                reject(new Error(message.error.message));
            } else {
                resolve(message.result);
            }
        } else if (message.method) {
            listeners.forEach((listener) => listener(message));
        }
    };
    const send = (method, params = {}) =>
        new Promise((resolve, reject) => {
            nextId += 1;
            pending.set(nextId, { resolve, reject });
            socket.send(JSON.stringify({ id: nextId, method, params }));
        });
    const close = async () => {
        // Browser.close ends every Chrome process; a kill of the first one alone left its children running.
        await Promise.race([send('Browser.close').catch(() => undefined), new Promise((r) => setTimeout(r, 5000))]);
        socket.close();
        if (chrome.exitCode === null) {
            chrome.kill();
            await new Promise((resolve) => chrome.once('exit', resolve));
        }

        fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    };
    return { send, listeners, close };
}

/**
 * Loads the page (or `withPage`, a changed copy) in headless Chrome; returns its errors, the probe's record and an
 * `evaluate` that runs an expression in the page.
 */
async function open(withPage = page) {
    const server = await serve(withPage);
    const browser = await launch();
    const errors = [];
    const ownUrl = `http://127.0.0.1:${server.address().port}/receiver/`;
    browser.listeners.push((message) => {
        if (message.method === 'Runtime.exceptionThrown') {
            const details = message.params.exceptionDetails;
            errors.push(`uncaught: ${(details.exception && details.exception.description) || details.text}`);
        } else if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') {
            const frame = message.params.stackTrace && message.params.stackTrace.callFrames[0];
            // Console errors from our page's script; the framework's own off-device complaints are its business.
            if (!frame || frame.url === ownUrl) {
                errors.push(`console.error: ${message.params.args.map((a) => a.value ?? a.description).join(' ')}`);
            }
        }
    });
    const evaluate = async (expression) => {
        const result = await browser.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
        if (result.exceptionDetails) {
            throw new Error(`${expression}: ${result.exceptionDetails.exception.description}`);
        }

        return result.result.value;
    };
    await browser.send('Runtime.enable');
    await browser.send('Page.enable');
    await browser.send('Page.navigate', { url: ownUrl });
    await waitFor(
        () => evaluate('document.readyState === "complete" && Boolean(window.probe)').catch(() => false),
        'the page',
        30000,
    );
    const close = async () => {
        await browser.close();
        server.closeAllConnections();
        server.close();
    };
    return { errors, evaluate, close, origin: `http://127.0.0.1:${server.address().port}` };
}

/** What the page shows. */
const SCREEN = `(() => {
    const text = (id) => document.getElementById(id).textContent;
    const shown = (id) => !document.getElementById(id).classList.contains('empty');
    const cover = document.getElementById('cover');
    const logo = document.querySelector('#station img');
    return {
        playing: document.body.classList.contains('playing'),
        idleVisible: getComputedStyle(document.getElementById('idle')).display !== 'none',
        mainVisible: getComputedStyle(document.querySelector('main')).display !== 'none',
        title: text('title'),
        artist: text('artist'),
        album: text('album'),
        year: text('year'),
        caption: text('captionText'),
        captionShown: shown('captions'),
        stationName: text('stationName'),
        stationShown: shown('station'),
        cover: cover.getAttribute('src'),
        coverIsLogo: cover.classList.contains('logo'),
        logo: logo.getAttribute('src'),
        backdrop: document.getElementById('backdrop').style.backgroundImage,
    };
})()`;

/** Runs the interceptor the page registered for `type` with `request`; returns whether it passed the request on. */
const intercept = (type, request) =>
    `(() => { const r = window.interceptors.${type}(${JSON.stringify(request)}); return r === null ? null : 'request'; })()`;

/** Waits until the pictures asked for have loaded (or failed) and the screen settled. */
const settle = (session, check, what) =>
    waitFor(
        async () => {
            const screen = await session.evaluate(SCREEN);
            return check(screen) ? screen : null;
        },
        what,
        10000,
    );

const media = (origin, { title, artist, album, releaseDate, cover, logo, customData }) => {
    const images = [cover, logo].filter(Boolean).map((name) => ({ url: `${origin}/img/${name}.png` }));
    return { metadata: { title, artist, albumName: album, releaseDate, images }, customData };
};

const loadRequest = (m) => ({ media: m });
const updateRequest = (m) => ({ items: [{ media: m }] });

test('the receiver page in Chrome with the real Cast framework', { timeout: 300000 }, async (t) => {
    const session = await open();
    t.after(() => session.close());
    const { origin, evaluate } = session;
    const img = (name) => `${origin}/img/${name}.png`;

    await t.test('loads with no uncaught error and no console error from our script', () => {
        assert.deepEqual(session.errors, []);
    });

    await t.test('reaches context.start(), with the receiver kept for an hour of inactivity', async () => {
        const record = await evaluate('window.probe');
        assert.equal(record.started, true);
        assert.equal(record.maxInactivity, 3600);
    });

    await t.test('registers its interceptors on the real framework without an error', async () => {
        const record = await evaluate('window.probe');
        assert.deepEqual(record.interceptorErrors, []);
        assert.deepEqual(record.interceptors, ['LOAD', 'QUEUE_UPDATE']);
    });

    await t.test('shows the idle screen before a station is cast', async () => {
        const screen = await evaluate(SCREEN);
        assert.equal(screen.playing, false);
        assert.equal(screen.idleVisible, true);
        assert.equal(screen.mainVisible, false);
        assert.equal(await evaluate('document.querySelector("#idle p").textContent'), 'Ready to play');
    });

    await t.test('a LOAD with the old bare-string caption shows the song and the caption, with no steps', async () => {
        const m = media(origin, { title: 'Old song', artist: 'Old artist', customData: 'Hello from an old build' });
        assert.equal(await evaluate(intercept('LOAD', loadRequest(m))), 'request');
        const screen = await evaluate(SCREEN);
        assert.equal(screen.playing, true);
        assert.equal(screen.idleVisible, false);
        assert.equal(screen.mainVisible, true);
        assert.equal(screen.title, 'Old song');
        assert.equal(screen.artist, 'Old artist');
        assert.equal(screen.caption, 'Hello from an old build');
        assert.equal(screen.captionShown, true);
        assert.equal(screen.stationShown, false);
        const Command = await evaluate('({ next: cast.framework.messages.Command.QUEUE_NEXT, prev: cast.framework.messages.Command.QUEUE_PREV })');
        const commands = (await evaluate('window.probe.commands')).at(-1);
        assert.equal(commands & (Command.next | Command.prev), 0);
    });

    await t.test('a LOAD with the JSON customData shows caption, station, logo and declares the steps', async () => {
        const data = { caption: 'Live words', previous: true, next: true, station: 'Radio Test', logo: img('logo') };
        const m = media(origin, {
            title: 'JSON song',
            artist: 'JSON artist',
            album: 'Deliria',
            releaseDate: '2015-03-01',
            cover: 'cover',
            customData: JSON.stringify(data),
        });
        await evaluate(intercept('LOAD', loadRequest(m)));
        const screen = await settle(session, (s) => s.cover && s.logo, 'the cover and the logo');
        assert.equal(screen.title, 'JSON song');
        assert.equal(screen.album, 'Deliria');
        assert.equal(screen.year, '2015');
        assert.equal(screen.caption, 'Live words');
        assert.equal(screen.stationName, 'Radio Test');
        assert.equal(screen.stationShown, true);
        assert.equal(screen.cover, img('cover'));
        assert.equal(screen.coverIsLogo, false);
        assert.equal(screen.logo, img('logo'));
        assert.match(screen.backdrop, /cover\.png/);
        const Command = await evaluate('({ next: cast.framework.messages.Command.QUEUE_NEXT, prev: cast.framework.messages.Command.QUEUE_PREV })');
        const commands = (await evaluate('window.probe.commands')).at(-1);
        assert.equal(commands & (Command.next | Command.prev), Command.next | Command.prev);
    });

    await t.test('the station name and logo without a cover: the logo takes the cover\'s place, not shown twice', async () => {
        const m = media(origin, {
            title: 'No cover',
            logo: 'logo',
            customData: JSON.stringify({ station: 'Radio Test', logo: img('logo') }),
        });
        // The app sends [station logo] alone when the song has no cover.
        m.metadata.images = [{ url: img('logo') }];
        await evaluate(intercept('LOAD', loadRequest(m)));
        const screen = await settle(session, (s) => s.cover === img('logo'), 'the logo as the cover');
        assert.equal(screen.coverIsLogo, true);
        assert.equal(screen.logo, null);
        assert.equal(screen.stationName, 'Radio Test');
        assert.equal(screen.stationShown, true);
    });

    await t.test('the station name and logo with a cover from the images [cover, logo]', async () => {
        const m = media(origin, { title: 'With cover', cover: 'cover2', logo: 'logo2', customData: '{"station":"Radio Two"}' });
        await evaluate(intercept('LOAD', loadRequest(m)));
        const screen = await settle(session, (s) => s.cover === img('cover2') && s.logo === img('logo2'), 'cover and logo');
        assert.equal(screen.coverIsLogo, false);
        assert.equal(screen.stationName, 'Radio Two');
    });

    await t.test('previous / next jumps broadcast {step, stepId} with rising ids and are not passed on', async () => {
        const before = (await evaluate('window.probe.broadcasts')).length;
        assert.equal(await evaluate(intercept('QUEUE_UPDATE', { jump: 1 })), null);
        assert.equal(await evaluate(intercept('QUEUE_UPDATE', { jump: -1 })), null);
        assert.equal(await evaluate(intercept('QUEUE_UPDATE', { jump: 1 })), null);
        const steps = (await evaluate('window.probe.broadcasts')).slice(before);
        assert.deepEqual(
            steps.map((s) => s.step),
            ['next', 'previous', 'next'],
        );
        for (let i = 1; i < steps.length; i += 1) {
            assert.ok(steps[i].stepId > steps[i - 1].stepId, `stepId rises: ${JSON.stringify(steps)}`);
        }
    });

    await t.test('a metadata update during playback replaces title, artist and cover, never leaving the old one', async () => {
        const first = media(origin, {
            title: 'First',
            artist: 'First artist',
            album: 'First album',
            releaseDate: '1999',
            cover: 'first',
            logo: 'logo',
            customData: '{"station":"Radio Test"}',
        });
        await evaluate(intercept('LOAD', loadRequest(first)));
        await settle(session, (s) => s.cover === img('first'), 'the first cover');
        await evaluate(`window.setPlaying(${JSON.stringify(first)})`);

        const second = media(origin, {
            title: 'Second',
            artist: 'Second artist',
            cover: 'second',
            logo: 'logo',
            customData: '{"station":"Radio Test","caption":"now"}',
        });
        assert.equal(await evaluate(intercept('QUEUE_UPDATE', updateRequest(second))), 'request');
        const screen = await settle(session, (s) => s.cover === img('second'), 'the second cover');
        assert.equal(screen.title, 'Second');
        assert.equal(screen.artist, 'Second artist');
        assert.equal(screen.album, '', 'the old album does not stay');
        assert.equal(screen.year, '', 'the old year does not stay');
        assert.equal(screen.caption, 'now');
        assert.match(screen.backdrop, /second\.png/);
        const given = (await evaluate('window.probe.mediaInformation')).at(-1);
        assert.equal(given.metadata.title, 'Second');
        assert.equal(given.metadata.albumName, undefined, 'the player gets the new metadata whole');

        // A song with no cover after one with a cover: no old cover and no old backdrop.
        const third = media(origin, { title: 'Third', logo: 'logo', customData: '{"station":"Radio Test"}' });
        third.metadata.images = [{ url: img('logo') }];
        await evaluate(intercept('QUEUE_UPDATE', updateRequest(third)));
        const bare = await settle(session, (s) => s.cover === img('logo'), 'the logo in the cover\'s place');
        assert.equal(bare.title, 'Third');
        assert.equal(bare.artist, '');
        assert.doesNotMatch(bare.backdrop, /second\.png/, 'the old cover leaves the backdrop');
        assert.equal(bare.caption, '');
        assert.equal(bare.captionShown, false);
    });

    await t.test('a station switch clears the old song, its station and its pictures', async () => {
        const m = media(origin, { title: 'Other station', customData: '{"station":"Radio Other"}' });
        m.metadata.images = [];
        await evaluate(intercept('LOAD', loadRequest(m)));
        const screen = await settle(session, (s) => s.cover === null && s.logo === null, 'no pictures');
        assert.equal(screen.title, 'Other station');
        assert.equal(screen.artist, '');
        assert.equal(screen.album, '');
        assert.equal(screen.caption, '');
        assert.equal(screen.stationName, 'Radio Other');
        assert.equal(screen.backdrop, '');
    });

    await t.test('MEDIA_FINISHED brings the idle screen back', async () => {
        // The handler the page gave the real player for MEDIA_FINISHED (no media ends off a device).
        assert.equal(await evaluate('typeof window.events[cast.framework.events.EventType.MEDIA_FINISHED]'), 'function');
        await evaluate('window.events[cast.framework.events.EventType.MEDIA_FINISHED]({})');
        const screen = await evaluate(SCREEN);
        assert.equal(screen.playing, false);
        assert.equal(screen.idleVisible, true);
        assert.equal(screen.mainVisible, false);
    });

    await t.test('no error from our script after every message', () => {
        assert.deepEqual(session.errors, []);
    });
});
