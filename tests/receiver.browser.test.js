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
            // The page's Content-Security-Policy stays in force; the injected probe is allowed by its own hash.
            const probeScript = `(${probe})();`;
            const probeHash = crypto.createHash('sha256').update(probeScript, 'utf8').digest('base64');
            const html = withPage
                .replace("script-src 'sha256-", `script-src 'sha256-${probeHash}' 'sha256-`)
                .replace(sdkTag, `${sdkTag}\n<script>${probeScript}</script>`);
            response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
            response.end(html);
        } else if (request.url === '/receiver/icon.png') {
            // The page's own files as GitHub Pages serves them: a missing one is a 404 here too.
            response.writeHead(200, { 'content-type': 'image/png' });
            response.end(fs.readFileSync(path.join(__dirname, '..', 'receiver', 'icon.png')));
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
        assert.deepEqual(record.interceptors, ['LOAD', 'QUEUE_UPDATE']);
    });

    await t.test('shows the idle screen before a station is cast', async () => {
        const screen = await evaluate(SCREEN);
        assert.equal(screen.playing, false);
        assert.equal(screen.idleVisible, true);
        assert.equal(screen.mainVisible, false);
        assert.equal(await evaluate('document.querySelector("#idle p").textContent'), 'Ready to play');
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

    await t.test('on a touch display the buttons stay on screen, under the song, with a full song and a caption, and tap', async () => {
        const long = 'A song title long enough to wrap over two lines on any screen the receiver meets';
        const data = JSON.stringify({ caption: `${long} ${long}`, previous: true, next: true, station: 'Pro FM' });
        const m = media(origin, { title: long, artist: long, album: long, releaseDate: '2025', cover: 'cover', logo: 'logo', customData: data });
        await evaluate('document.body.classList.add("touch")');
        await evaluate(intercept('LOAD', loadRequest(m)));
        await settle(session, (s) => s.logo !== null, 'the logo');
        const placed = await evaluate(`(() => {
            // Their own row in the safe area, under the song and clear of the caption band.
            const main = document.querySelector('main').getBoundingClientRect();
            const song = document.getElementById('song').getBoundingClientRect();
            const captions = document.getElementById('captions').getBoundingClientRect();
            return ['previous', 'playPause', 'next'].map((id) => {
                const r = document.getElementById(id).getBoundingClientRect();
                const inside = r.top >= song.bottom - 0.5 && r.bottom <= captions.top + 0.5 && r.bottom <= main.bottom + 0.5;
                return { id, width: r.width, inside };
            });
        })()`);
        for (const button of placed) {
            assert.ok(button.width > 0, `${button.id} is drawn`);
            assert.equal(button.inside, true, `${button.id} is under the song, above the captions, in the safe area`);
        }

        const before = (await evaluate('window.probe')).broadcasts.length;
        await evaluate('document.getElementById("next").click(); document.getElementById("previous").click()');
        const steps = (await evaluate('window.probe')).broadcasts.slice(before).map((b) => b.step);
        assert.deepEqual(steps, ['next', 'previous']);
        await evaluate('document.body.classList.remove("touch")');
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
