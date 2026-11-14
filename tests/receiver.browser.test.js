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
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { problems, resize, contrast } = require('./receiver-layout');

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
    record.cspViolations = [];
    document.addEventListener('securitypolicyviolation', (e) => {
        record.cspViolations.push(`${e.effectiveDirective} ${e.blockedURI}`);
    });
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
            record.touchScreenOptimizedApp = Boolean(options && options.uiConfig && options.uiConfig.touchScreenOptimizedApp);
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
        // No stream off a device: a tap's pause / play is recorded instead.
        record.playback = [];
        player.pause = () => record.playback.push('pause');
        player.play = () => record.playback.push('play');
        // Every status says what the screen shows (record.shown, the last one); step presses are also in broadcasts.
        player.broadcastStatus = (includeMedia, requestId, customData) => {
            record.shown = customData.shown;
            record.statusRequestIds = [...new Set([...(record.statusRequestIds || []), requestId])];
            if (customData.step) {
                record.broadcasts.push(customData);
            }
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

/** Waits `ms`: separate presses are a moment apart (the page takes a press repeated within 600 ms as the same). */
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The receiver's files beside its page, with their content types. */
const ownFiles = {
    '/receiver/receiver.js': 'text/javascript; charset=utf-8',
    '/receiver/logo-tone.js': 'text/javascript; charset=utf-8',
    '/receiver/theme.js': 'text/javascript; charset=utf-8',
    '/receiver/layout-report.js': 'text/javascript; charset=utf-8',
    '/receiver/fit.js': 'text/javascript; charset=utf-8',
    '/receiver/icon.png': 'image/png',
};

/** The page as a device gets it, with the probe after the framework; pictures served from /img/<name>.png. */
function serve(withPage) {
    const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        'base64',
    );
    const server = http.createServer((request, response) => {
        if (request.url === '/receiver/') {
            // The page's Content-Security-Policy stays in force; the injected probe is allowed by its own hash.
            const probeScript = `(${probe})();`;
            const probeHash = crypto.createHash('sha256').update(probeScript, 'utf8').digest('base64');
            const html = withPage
                .replace("script-src 'self'", `script-src 'sha256-${probeHash}' 'self'`)
                .replace(sdkTag, `${sdkTag}\n<script>${probeScript}</script>`);
            response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
            response.end(html);
        } else if (ownFiles[request.url]) {
            // The page's own files as GitHub Pages serves them: a missing one is a 404 here too.
            response.writeHead(200, { 'content-type': ownFiles[request.url] });
            response.end(fs.readFileSync(path.join(__dirname, '..', request.url)));
        } else if (request.url.startsWith('/logos/')) {
            // A real station logo (a bright, busy picture for the layout and contrast checks).
            const name = path.basename(request.url);
            response.writeHead(200, { 'content-type': 'image/png' });
            response.end(fs.readFileSync(path.join(__dirname, '..', 'RadioLogos', name)));
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
    // CHROME_PATH, when set, is the only Chrome: a wrong one fails rather than falling back to another install.
    if (process.env.CHROME_PATH) {
        return process.env.CHROME_PATH;
    }

    const found = candidates.find((candidate) => candidate && fs.existsSync(candidate));
    assert.ok(found, 'Chrome is needed for the receiver page test: install it or set CHROME_PATH');
    return found;
}

/** `promise`, or a rejection naming `what` once `ms` have passed; the timer never outlives it. */
function within(promise, ms, what) {
    let timer;
    const deadline = new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`Timed out waiting for ${what}`)), Math.max(ms, 0));
    });
    return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

/** Polls `condition` until it returns a truthy value; a condition that never settles still ends at the deadline. */
async function waitFor(condition, what, timeout = 20000) {
    const end = Date.now() + timeout;
    for (;;) {
        const value = await within(Promise.resolve().then(condition), end - Date.now(), what);
        if (value) {
            return value;
        }

        if (Date.now() > end) {
            throw new Error(`Timed out waiting for ${what}`);
        }

        await new Promise((resolve) => setTimeout(resolve, 100));
    }
}

/** Headless Chrome and one DevTools connection to a fresh page target; on any failure nothing is left running. */
async function launch() {
    const executable = chromePath();
    const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'receiver-chrome-'));
    let socket = null;
    const pending = new Map();
    let gone = null;
    /** Every request still waiting for Chrome is rejected: none can hang once Chrome or its socket is gone. */
    const fail = (reason) => {
        gone = gone || reason;
        pending.forEach(({ reject }) => reject(new Error(gone)));
        pending.clear();
    };
    const chrome = spawn(
        executable,
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
    const exited = new Promise((resolve) => {
        const done = () => resolve();
        chrome.once('exit', done);
        // A spawn that fails (no such file) emits 'error' and never 'exit'.
        chrome.once('error', done);
    });
    let spawnError = null;
    chrome.on('error', (e) => {
        spawnError = e;
        fail(`Chrome could not start: ${e.message}`);
    });
    chrome.on('exit', (code, signal) => fail(`Chrome exited (${signal || code})`));
    const running = () => !spawnError && chrome.exitCode === null && chrome.signalCode === null;
    const stop = async () => {
        if (socket) {
            socket.close();
        }

        if (running() && chrome.pid !== undefined) {
            chrome.kill();
        }

        await within(exited, 10000, 'Chrome to exit').catch(() => undefined);
        fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    };

    const listeners = [];
    let nextId = 0;
    const send = (method, params = {}) =>
        new Promise((resolve, reject) => {
            if (gone) {
                reject(new Error(gone));
                return;
            }

            nextId += 1;
            pending.set(nextId, { resolve, reject });
            socket.send(JSON.stringify({ id: nextId, method, params }));
        });
    try {
        const portFile = path.join(profile, 'DevToolsActivePort');
        const port = await waitFor(() => {
            if (gone) {
                throw new Error(gone);
            }

            return fs.existsSync(portFile) && fs.readFileSync(portFile, 'utf8').split('\n')[0].trim();
        }, 'Chrome');
        const targets = await within(
            fetch(`http://127.0.0.1:${port}/json/list`).then((r) => r.json()),
            10000,
            'the DevTools target list',
        );
        const target = targets.find((t) => t.type === 'page');
        assert.ok(target, 'Chrome has a page target');
        socket = new WebSocket(target.webSocketDebuggerUrl);
        socket.onclose = () => fail('the DevTools connection closed');
        await within(
            new Promise((resolve, reject) => {
                socket.onopen = resolve;
                socket.onerror = () => reject(new Error('the DevTools connection failed'));
            }),
            10000,
            'the DevTools connection',
        );
    } catch (e) {
        await stop();
        throw e;
    }

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
    const close = async () => {
        // Browser.close ends every Chrome process; a kill of the first one alone left its children running.
        await within(send('Browser.close'), 5000, 'Browser.close').catch(() => undefined);
        await stop();
    };
    return { send, listeners, close };
}

/**
 * Loads the page (or `withPage`, a changed copy) in headless Chrome; returns its errors, the probe's record and an
 * `evaluate` that runs an expression in the page.
 */
async function open(withPage = page) {
    const server = await serve(withPage);
    const closeServer = () =>
        new Promise((resolve) => {
            server.closeAllConnections();
            server.close(() => resolve());
        });
    let browser;
    try {
        browser = await launch();
    } catch (e) {
        await closeServer();
        throw e;
    }

    const close = async () => {
        await browser.close();
        await closeServer();
    };
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
    try {
        await browser.send('Runtime.enable');
        await browser.send('Page.enable');
        await browser.send('Page.navigate', { url: ownUrl });
        await waitFor(
            () =>
                evaluate('document.readyState === "complete" && Boolean(window.probe)').catch((e) => {
                    // Chrome gone: no point polling until the deadline.
                    if (/Chrome|DevTools/.test(e.message)) {
                        throw e;
                    }

                    return false;
                }),
            'the page',
            30000,
        );
    } catch (e) {
        await close();
        throw e;
    }

    return { errors, evaluate, close, send: browser.send, origin: `http://127.0.0.1:${server.address().port}` };
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
        // On its own line under the album, or joined to the album's line when space is tight.
        year: text('yearLine') || text('year'),
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

/** The background, padding and shadow behind an element: a logo has none, with a cover or without. */
const PLATE = (selector) => `(() => {
    const s = getComputedStyle(document.querySelector(${JSON.stringify(selector)}));
    return { background: s.backgroundColor, image: s.backgroundImage, shadow: s.boxShadow, padding: s.padding };
})()`;
const NO_PLATE = { background: 'rgba(0, 0, 0, 0)', image: 'none', shadow: 'none', padding: '0px' };

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

test('a Chrome that cannot start fails at once and leaves nothing open', { timeout: 30000 }, async () => {
    const resources = () => process.getActiveResourcesInfo().filter((r) => r !== 'TTYWrap' && r !== 'Timeout');
    const before = resources();
    const saved = process.env.CHROME_PATH;
    process.env.CHROME_PATH = path.join(os.tmpdir(), 'no-such-chrome', 'chrome.exe');
    const started = Date.now();
    try {
        await assert.rejects(open(), /Chrome could not start/);
    } finally {
        if (saved === undefined) {
            delete process.env.CHROME_PATH;
        } else {
            process.env.CHROME_PATH = saved;
        }
    }

    assert.ok(Date.now() - started < 10000, 'the failure is reported at once, not at a deadline');
    // The server's socket and Chrome's process handle are released (a closed handle leaves Node's list a moment later).
    const same = () => JSON.stringify(resources()) === JSON.stringify(before);
    await waitFor(same, 'the server and Chrome handles to close', 2000).catch(() => undefined);
    assert.deepEqual(resources(), before);
});

test('the receiver page in Chrome with the real Cast framework', { timeout: 300000 }, async (t) => {
    const session = await open();
    t.after(() => session.close());
    const { origin, evaluate } = session;
    const img = (name) => `${origin}/img/${name}.png`;

    await t.test('loads with no uncaught error and no console error from our script', () => {
        assert.deepEqual(session.errors, []);
    });

    await t.test('runs under its Content-Security-Policy with nothing blocked', async () => {
        const record = await evaluate('window.probe');
        assert.deepEqual(record.cspViolations, []);
    });

    await t.test('reaches context.start(), with the receiver kept for an hour of inactivity', async () => {
        const record = await evaluate('window.probe');
        assert.equal(record.started, true);
        assert.equal(record.maxInactivity, 3600);
    });

    await t.test('registers its interceptors on the real framework without an error', async () => {
        const record = await evaluate('window.probe');
        assert.deepEqual(record.interceptorErrors, []);
        assert.deepEqual(record.interceptors, ['LOAD', 'MEDIA_STATUS', 'QUEUE_UPDATE']);
        // The real framework's MEDIA_STATUS interceptor: a status the page sends says what the screen shows.
        const status = await evaluate('window.interceptors.MEDIA_STATUS({ playerState: "IDLE" })');
        assert.equal(typeof status.customData.shown, 'object');
    });

    await t.test('shows the idle screen before a station is cast', async () => {
        const screen = await evaluate(SCREEN);
        assert.equal(screen.playing, false);
        assert.equal(screen.idleVisible, true);
        assert.equal(screen.mainVisible, false);
        assert.equal(await evaluate('document.querySelector("#idle p").textContent'), 'Ready to play');
        // One logo, the app's icon: no "RoRadio" wordmark under it (owner, 2026-11-14). The icon is the heading, named.
        assert.equal(await evaluate('document.querySelector("#idle h1").textContent.trim()'), '');
        assert.equal(await evaluate('document.querySelector("#idle h1 img").alt'), 'RoRadio');
        assert.equal(await evaluate('document.querySelectorAll("#idle img").length'), 1);
    });

    await t.test('the idle screen shows the app icon, which loads (no 404)', async () => {
        const icon = await waitFor(
            async () => {
                const state = await evaluate(`(() => {
                    const icon = document.getElementById('appIcon');
                    return { complete: icon.complete, width: icon.naturalWidth, shown: icon.getBoundingClientRect().width > 0 };
                })()`);
                return state.complete ? state : null;
            },
            'the icon to load',
            10000,
        );
        assert.equal(icon.width, 256);
        assert.equal(icon.shown, true);
    });

    await t.test('declares the touch UI and plays through its own media element', async () => {
        const record = await evaluate('window.probe');
        assert.equal(record.touchScreenOptimizedApp, true);
        assert.equal(await evaluate('document.querySelector("cast-media-player")'), null);
        assert.equal(await evaluate('document.getElementById("media").tagName'), 'AUDIO');
    });

    await t.test('on a touch display a full song, its cover and a caption all end above the system media bar', async () => {
        const long = 'A song title long enough to wrap over two lines on any screen the receiver meets';
        const data = JSON.stringify({ caption: `${long} ${long}`, previous: true, next: true, station: 'Pro FM' });
        const m = media(origin, { title: long, artist: long, album: long, releaseDate: '2025', cover: 'cover', logo: 'logo', customData: data });
        await evaluate('document.body.classList.add("touch")');
        await evaluate(intercept('LOAD', loadRequest(m)));
        await settle(session, (s) => s.logo !== null, 'the logo');
        // The Pixel Tablet's system media bar covers the page from 73 % of its height down: nothing of ours goes there.
        const placed = await evaluate(`(() => ['cover', 'song', 'captions', 'title', 'station'].map((id) => {
            const r = document.getElementById(id).getBoundingClientRect();
            return { id, height: r.height, bottom: r.bottom / innerHeight };
        }))()`);
        // The caption is the first to give its room to the song, which is never cut: drawn, or yielded.
        const yielded = await evaluate('document.body.classList.contains("caption-yields")');
        for (const box of placed.filter((b) => !(yielded && b.id === 'captions'))) {
            assert.ok(box.height > 0, `${box.id} is drawn`);
            assert.ok(box.bottom <= 0.72, `${box.id} ends at ${(box.bottom * 100).toFixed(1)} % of the height, above the bar`);
        }

        assert.equal(await evaluate('document.querySelectorAll("button").length'), 0);
        await evaluate('document.body.classList.remove("touch")');
    });

    await t.test('a stream that fails shows the idle screen with why, and the next station clears it', async () => {
        await evaluate('window.events[cast.framework.events.EventType.MEDIA_FINISHED]({ endedReason: "ERROR" })');
        let screen = await evaluate(SCREEN);
        assert.equal(screen.idleVisible, true);
        assert.match(await evaluate('document.getElementById("status").textContent'), /could not be played/);
        assert.equal(await evaluate('document.body.classList.contains("failed")'), true);
        await evaluate(intercept('LOAD', loadRequest(media(origin, { title: 'Back', customData: '' }))));
        screen = await evaluate(SCREEN);
        assert.equal(screen.mainVisible, true);
        assert.equal(await evaluate('document.body.classList.contains("failed")'), false);
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
        assert.deepEqual(await evaluate(PLATE('#cover')), NO_PLATE);
    });

    await t.test('the station name and logo with a cover from the images [cover, logo]', async () => {
        const m = media(origin, { title: 'With cover', cover: 'cover2', logo: 'logo2', customData: '{"station":"Radio Two"}' });
        await evaluate(intercept('LOAD', loadRequest(m)));
        const screen = await settle(session, (s) => s.cover === img('cover2') && s.logo === img('logo2'), 'cover and logo');
        assert.equal(screen.coverIsLogo, false);
        assert.equal(screen.stationName, 'Radio Two');
        // The cover and the logo sit directly on the page: no tile, plate, card, colour fill or shadow behind either.
        assert.deepEqual(await evaluate(PLATE('#cover')), NO_PLATE);
        assert.deepEqual(await evaluate(PLATE('#song')), NO_PLATE);
        assert.deepEqual(await evaluate(PLATE('#station img')), NO_PLATE);
        assert.deepEqual(await evaluate(PLATE('#station')), NO_PLATE);
    });

    await t.test('previous / next jumps broadcast {step, stepId} with rising ids and are not passed on', async () => {
        await pause(700);
        const before = (await evaluate('window.probe.broadcasts')).length;
        // Separate presses: each a moment after the last.
        assert.equal(await evaluate(intercept('QUEUE_UPDATE', { jump: 1 })), null);
        await pause(700);
        assert.equal(await evaluate(intercept('QUEUE_UPDATE', { jump: -1 })), null);
        await pause(700);
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

    await t.test('one press is one step: the same jump delivered five times with one request id steps once', async () => {
        await pause(700);
        const before = (await evaluate('window.probe.broadcasts')).length;
        const jump = { jump: 1, requestId: 4242, senderId: 'tablet' };
        for (let i = 0; i < 5; i += 1) {
            assert.equal(await evaluate(intercept('QUEUE_UPDATE', jump)), null);
            // Resent after the press's moment has passed: only the request id tells it is the same press.
            await pause(700);
        }
        const steps = (await evaluate('window.probe.broadcasts')).slice(before);
        assert.deepEqual(steps.map((s) => s.step), ['next']);
    });

    await t.test('the media status tells the senders what the screen shows, pictures once loaded', async () => {
        const data = JSON.stringify({ caption: 'Live words', previous: true, next: false, station: 'Pro FM' });
        const m = media(origin, { title: 'A song', artist: 'A band', cover: 'cover', logo: 'logo', customData: data });
        await evaluate(intercept('QUEUE_UPDATE', updateRequest(m)));
        const shown = await waitFor(
            async () => {
                const s = (await evaluate('window.probe')).shown;
                return s && s.cover && s.logo && s.title === 'A song' ? s : null;
            },
            'the pictures in the reported screen',
            10000,
        );
        assert.deepEqual(shown, {
            title: 'A song',
            artist: 'A band',
            station: 'Pro FM',
            caption: 'Live words',
            logo: true,
            cover: true,
            steps: { previous: true, next: false },
            defaultTitle: false,
            theme: null,
        });
        assert.deepEqual((await evaluate('window.probe')).statusRequestIds, [0]);
    });

    await t.test('the system bar\'s presses all carry one request id: next, previous 1 s later, next 2 s later, all step', async () => {
        await pause(700);
        const before = (await evaluate('window.probe.broadcasts')).length;
        await evaluate(intercept('QUEUE_UPDATE', { jump: 1, requestId: 1, senderId: 'local' }));
        await pause(1000);
        await evaluate(intercept('QUEUE_UPDATE', { jump: -1, requestId: 1, senderId: 'local' }));
        await pause(2000);
        await evaluate(intercept('QUEUE_UPDATE', { jump: 1, requestId: 1, senderId: 'local' }));
        const steps = (await evaluate('window.probe.broadcasts')).slice(before);
        assert.deepEqual(steps.map((s) => s.step), ['next', 'previous', 'next']);
        assert.deepEqual(steps.map((s) => s.via), ['local/1/next', 'local/1/previous', 'local/1/next']);
    });

    await t.test('a double press on the system bar (two jumps at once, new ids) is one step', async () => {
        await pause(700);
        const before = (await evaluate('window.probe.broadcasts')).length;
        await evaluate(intercept('QUEUE_UPDATE', { jump: 1, requestId: 51, senderId: 'tablet' }));
        await evaluate(intercept('QUEUE_UPDATE', { jump: 1, requestId: 52, senderId: 'tablet' }));
        const steps = (await evaluate('window.probe.broadcasts')).slice(before);
        assert.deepEqual(steps.map((s) => s.step), ['next']);
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

test('layout and accessibility in every state, at 1920 x 1080, on the tablet (2560 x 1600) and at 1280 x 720', { timeout: 600000 }, async (t) => {
    const session = await open();
    t.after(() => session.close());
    const { origin, evaluate } = session;
    const logo = (name) => `${origin}/logos/${name}.png`;
    const long = 'A song title long enough to wrap over two lines and then some more on any screen the receiver meets';
    const song = (title, artist, data, images) => ({
        metadata: { title, artist, albumName: data.album, releaseDate: '2025', images: images.map((url) => ({ url })) },
        customData: JSON.stringify(data),
    });
    const states = {
        'idle (splash)': ['window.events[cast.framework.events.EventType.MEDIA_FINISHED]({})'],
        error: ['window.events[cast.framework.events.EventType.MEDIA_FINISHED]({ endedReason: "ERROR" })'],
        'loading (the station, no song yet)': [intercept('LOAD', { media: song('Pro FM', 'Pro FM', { station: 'Pro FM', previous: true, next: true }, []) })],
        'a song with a cover, steps on': [
            intercept('LOAD', { media: song('A summer song', 'A band featuring a singer', { station: 'Pro FM', previous: true, next: true, album: 'Single' }, [logo('90er-stream'), logo('Profm')]) }),
        ],
        'the station only (logo as cover), steps off': [
            intercept('LOAD', { media: song('Europa FM', 'Europa FM', { station: 'Europa FM', logo: logo('EuropaFM') }, [logo('EuropaFM')]) }),
        ],
        'long title, artist, album and caption': [
            intercept('LOAD', {
                media: song(long, long, { station: 'A station with a long name too', caption: `${long} ${long}`, album: long, previous: true, next: false }, [logo('90er-stream'), logo('Profm')]),
            }),
        ],
    };
    const sizes = [
        { name: '1920 x 1080', width: 1920, height: 1080, touch: false },
        { name: 'Pixel Tablet 2560 x 1600', width: 2560, height: 1600, touch: true },
        { name: '1280 x 720', width: 1280, height: 720, touch: false },
    ];
    for (const size of sizes) {
        for (const [state, steps] of Object.entries(states)) {
            await t.test(`${size.name}: ${state}`, async () => {
                await resize(session, size.width, size.height);
                await evaluate(`document.body.classList.toggle('touch', ${size.touch})`);
                for (const expression of steps) {
                    await evaluate(expression);
                }

                // The pictures loaded and the backdrop faded in (600 ms) before the screen is measured.
                await pause(1200);
                assert.deepEqual(await problems(session, size), []);
            });
        }
    }

    const where = `(() => {
        const box = (s) => document.querySelector(s).getBoundingClientRect();
        return { title: box('#title').top, cover: box('#cover').bottom, station: box('#station').bottom, song: box('#song').top };
    })()`;
    // Each text's lines, font size, CSS full size and whether it is cut in any way: its own box overflows, a clamp
    // or an ellipsis, or the song's column hides its end (owner: never cut, never an ellipsis).
    const lines = `(() => ['title', 'artist', 'release'].map((id) => {
        const e = document.getElementById(id);
        const s = getComputedStyle(e);
        const full = (() => { const k = e.style.fontSize; e.style.fontSize = ''; const f = parseFloat(getComputedStyle(e).fontSize); e.style.fontSize = k; return f; })();
        const column = document.getElementById('song').getBoundingClientRect();
        const hides = s.overflow !== 'visible';
        const cut = (hides && (e.scrollHeight > e.clientHeight + 1 || e.scrollWidth > e.clientWidth + 1)) || s.textOverflow === 'ellipsis'
            || (s.webkitLineClamp && s.webkitLineClamp !== 'none') || e.getBoundingClientRect().bottom > column.bottom + 1;
        return { id, lines: Math.round(e.clientHeight / parseFloat(s.lineHeight)), size: parseFloat(s.fontSize), full, cut };
    }))()`;
    const backdropNow = 'document.getElementById("backdrop").style.backgroundImage';
    // The song's texts on screen: each one's words and whether it shows.
    const textsShown = `(() => Object.fromEntries(['title', 'artist', 'release', 'yearLine', 'stationName'].map((id) => {
        const e = document.getElementById(id);
        return [id, { shown: e.checkVisibility(), text: e.textContent }];
    })))()`;
    for (const size of sizes) {
        await t.test(`${size.name}: the blurred backdrop follows the song; the app's cover theme on and off, readable over both`, async () => {
            await resize(session, size.width, size.height);
            await evaluate(`document.body.classList.toggle('touch', ${size.touch})`);
            // A song: its cover is the backdrop, very blurred.
            await evaluate(intercept('LOAD', { media: song('One song', 'A band', { station: 'Pro FM' }, [logo('90er-stream'), logo('Profm')]) }));
            await pause(1200);
            assert.match(await evaluate(backdropNow), /90er-stream/);
            assert.match(await evaluate('getComputedStyle(document.getElementById("backdrop")).filter'), /blur/);
            // The next station, with no cover: its logo is the backdrop.
            await evaluate(intercept('LOAD', { media: song('Europa FM', 'Europa FM', { station: 'Europa FM', logo: logo('EuropaFM') }, []) }));
            await pause(1200);
            assert.match(await evaluate(backdropNow), /EuropaFM/);
            assert.deepEqual(await problems(session, size), []);

            // The app's cover colour theme on: the scrim takes its tint, and the text stays readable on the real pixels.
            // The cover's shapes stay visible behind: a blur of at most 5% of the screen's short side (14% left an even
            // olive tint on the tablet); the text's contrast over it is checked on the pixels.
            const look = await evaluate(`(() => ({
                blur: parseFloat(getComputedStyle(document.getElementById('backdrop')).filter.match(/blur\\(([\\d.]+)px/u)[1]),
                short: Math.min(innerWidth, innerHeight),
            }))()`);
            assert.ok(look.blur <= look.short * 0.05 + 0.5, `the backdrop's blur ${look.blur}px on ${look.short}px`);
            const theme = { accent: '#f0e040', tint: '#4d4813' };
            const album = { album: 'An album' };
            await evaluate(intercept('QUEUE_UPDATE', updateRequest(song('A song', 'A band', { station: 'Pro FM', ...album }, [logo('90er-stream'), logo('Profm')]))));
            await pause(1200);
            const plainTexts = await evaluate(textsShown);
            await evaluate(intercept('QUEUE_UPDATE', updateRequest(song('A song', 'A band', { station: 'Pro FM', theme, ...album }, [logo('90er-stream'), logo('Profm')]))));
            await pause(1200);
            assert.equal(await evaluate('document.body.classList.contains("themed")'), true);
            // The theme never drops a text: the same texts show, with the same words, theme on and off.
            assert.deepEqual(await evaluate(textsShown), plainTexts);
            assert.ok(plainTexts.release.shown && plainTexts.release.text.includes('An album'), JSON.stringify(plainTexts));
            assert.deepEqual((await evaluate('window.probe')).shown.theme, theme);
            // The scrim is drawn in the tint (77, 72, 19; Chrome writes it as srgb fractions), not the default one (#46).
            const scrim = await evaluate('getComputedStyle(document.getElementById("scrim")).backgroundImage');
            assert.match(scrim, /color\(srgb 0\.30196\d* 0\.28235\d* 0\.07450\d*/u, `the themed scrim: ${scrim}`);
            assert.deepEqual(await problems(session, size), []);

            // Off in the app: the next song comes without it, and the receiver has its default look again.
            await evaluate(intercept('QUEUE_UPDATE', updateRequest(song('A plain song', 'A band', { station: 'Pro FM' }, [logo('90er-stream'), logo('Profm')]))));
            await pause(1200);
            assert.equal(await evaluate('document.body.classList.contains("themed")'), false);
            assert.equal((await evaluate('window.probe')).shown.theme, null);
            assert.deepEqual(await problems(session, size), []);
        });
    }

    await t.test('the first song after the idle screen is fitted too (its screen was hidden while it was measured, #46)', async () => {
        await resize(session, 1920, 1080);
        await evaluate('window.events[cast.framework.events.EventType.MEDIA_FINISHED]({})');
        const veryLong = 'A title long enough to need more than two lines at its full size on any screen at all, and then some more';
        await evaluate(intercept('LOAD', { media: song(veryLong, 'A band', { station: 'Pro FM' }, [logo('90er-stream'), logo('Profm')]) }));
        const title = (await evaluate(lines))[0];
        assert.ok(title.size < title.full, `the title shrank on the first load: ${JSON.stringify(title)}`);
        assert.equal(title.cut, false, JSON.stringify(title));
    });

    const yearState = `(() => ({
        alone: document.getElementById('yearLine').textContent,
        joined: document.getElementById('year').textContent,
        shown: document.getElementById('yearLine').checkVisibility(),
    }))()`;
    for (const size of sizes) {
        await t.test(`${size.name}: the year on its own line when there is room; on the album's line only when space is tight`, async () => {
            await resize(session, size.width, size.height);
            await evaluate(`document.body.classList.toggle('touch', ${size.touch})`);
            const short = { media: song('Hello', 'Adele', { station: 'Pro FM', album: '25' }, [logo('90er-stream'), logo('Profm')]) };
            short.media.metadata.releaseDate = '2015';
            await evaluate(intercept('LOAD', short));
            await pause(800);
            assert.deepEqual(await evaluate(yearState), { alone: '2015', joined: '', shown: true });
            assert.deepEqual(await problems(session, size), []);

            const words = 'A title that needs two lines of room at its full size on this screen, or a little more than that';
            const tight = { media: song(words, words, { station: 'Pro FM', album: words, caption: `${words} ${words}` }, [logo('90er-stream'), logo('Profm')]) };
            tight.media.metadata.releaseDate = '2015';
            await evaluate(intercept('LOAD', tight));
            await pause(800);
            const state = await evaluate(yearState);
            // Tight: joined to the album's line ("… · 2015"), or alone only where the column still had room.
            assert.ok(state.joined === '2015' || (state.alone === '2015' && state.shown), JSON.stringify(state));
            assert.deepEqual(await problems(session, size), []);
        });
    }

    await t.test('no room for its own line (a small screen with the system bar and a caption): the year joins the album\'s line', async () => {
        await resize(session, 1280, 720);
        await evaluate("document.body.classList.toggle('touch', true)");
        const words = 'A title that needs two lines of room at its full size on this screen, or a little more than that';
        const tight = { media: song(words, words, { station: 'Pro FM', album: words, caption: `${words} ${words}` }, [logo('90er-stream'), logo('Profm')]) };
        tight.media.metadata.releaseDate = '2015';
        await evaluate(intercept('LOAD', tight));
        await pause(800);
        assert.deepEqual(await evaluate(yearState), { alone: '', joined: '2015', shown: false });
        assert.deepEqual(await problems(session, { width: 1280, height: 720, touch: true }), []);
        await evaluate("document.body.classList.toggle('touch', false)");
    });

    for (const size of sizes) {
        await t.test(`${size.name}: a short text is one line at full size; long and extreme texts shrink and are never cut`, async () => {
            await resize(session, size.width, size.height);
            await evaluate(`document.body.classList.toggle('touch', ${size.touch})`);
            const floor = (16 * size.height) / 1080 - 0.5;
            await evaluate(intercept('LOAD', { media: song('Hello', 'Adele', { station: 'Pro FM', album: '25' }, [logo('90er-stream'), logo('Profm')]) }));
            await pause(300);
            for (const text of await evaluate(lines)) {
                assert.equal(text.lines, 1, `${text.id}: ${JSON.stringify(text)}`);
                assert.equal(text.size, text.full, `${text.id} keeps its full size`);
            }

            // Long, then extreme: a 200-character title, a long band, a long album, and a caption. Every text in full.
            const medium = 'A title that needs two lines of room at its full size on this screen, or a little more';
            const title = `${medium} ${medium} and twenty-eight more characters`.slice(0, 200);
            const band = 'The Very Long Name Of A Band Featuring Several Singers And An Orchestra From Somewhere Far';
            const album = 'An Album Whose Name Goes On And On: The Complete Recordings, Remastered, Deluxe Anniversary Edition';
            for (const [name, artist, albumName, caption] of [[medium, medium, medium, ''], [title, band, album, `${medium} ${medium}`]]) {
                const m = song(name, artist, { station: 'Pro FM', album: albumName, caption }, [logo('90er-stream'), logo('Profm')]);
                m.metadata.releaseDate = '2015';
                await evaluate(intercept('LOAD', { media: m }));
                await pause(800);
                for (const text of await evaluate(lines)) {
                    assert.equal(text.cut, false, `${text.id} is shown in full: ${JSON.stringify(text)}`);
                    assert.ok(text.size >= floor, `${text.id} at ${text.size} px is readable`);
                }

                assert.equal(await evaluate('document.getElementById("title").textContent'), name);
                assert.deepEqual(await problems(session, size), []);
            }
        });

        await t.test(`${size.name}: a fixed layout, the title where it was, the station's line level with the cover's bottom`, async () => {
            await resize(session, size.width, size.height);
            await evaluate(`document.body.classList.toggle('touch', ${size.touch})`);
            await evaluate(states['a song with a cover, steps on'][0]);
            await pause(800);
            const withCover = await evaluate(where);
            await evaluate(states['the station only (logo as cover), steps off'][0]);
            await pause(800);
            const stationOnly = await evaluate(where);
            assert.ok(Math.abs(withCover.title - stationOnly.title) < 1, `title at ${withCover.title} and ${stationOnly.title}`);
            assert.ok(Math.abs(withCover.station - withCover.cover) < 2, `station line ends ${withCover.station}, cover ${withCover.cover}`);
            assert.ok(Math.abs(stationOnly.station - stationOnly.cover) < 2, `station line ends ${stationOnly.station}, cover ${stationOnly.cover}`);
        });
    }

    await t.test('a dark logo gets the light glow on the real canvas; Pro FM\'s white lettering does not', async () => {
        await resize(session, 1920, 1080);
        for (const [name, light] of [['24house', true], ['Profm', false]]) {
            await evaluate(intercept('LOAD', { media: song(name, name, { station: name }, [logo(name)]) }));
            await waitFor(
                async () => (await evaluate('document.getElementById("cover").getAttribute("src")')) === logo(name),
                `${name} as the cover`,
                10000,
            );
            await pause(500);
            assert.equal(await evaluate('document.getElementById("cover").classList.contains("light")'), light, name);
            // The class is drawn: a glow around the logo's shapes, or nothing at all.
            const filter = await evaluate('getComputedStyle(document.getElementById("cover")).filter');
            assert.equal(filter.includes('drop-shadow'), light, `${name}: filter ${filter}`);
            assert.deepEqual(await evaluate(PLATE('#cover')), NO_PLATE);
        }
    });

    await t.test('no error from our script in any state', () => {
        assert.deepEqual(session.errors, []);
    });
});

test('the contrast measure matches WCAG: black on white 21:1, a colour on itself 1:1', () => {
    assert.equal(Math.round(contrast([0, 0, 0], [255, 255, 255])), 21);
    assert.equal(contrast([120, 40, 200], [120, 40, 200]), 1);
});
