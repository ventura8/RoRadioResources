// Copyright 2026 Sergiu Alexandrescu
// A minimal Cast V2 sender for scripts/e2e/Test-ReceiverOnTablet.ps1: no packages, Node's own TLS. It launches the
// RoRadio receiver (F38F9694) on a device and plays one step of the receiver's user flows a call, the way the app's
// SharpcasterTransport does: LOAD with the app's customData, QUEUE_UPDATE for a song, a step press read back from the
// media status, PAUSE / PLAY, STOP.
//
//   node cast-client.mjs <address> <step> [json|@path]
//   steps: avail | launch | load | song | tap | jump | pause | play | status | shown | stop
//   On Windows, pass @path (UTF-8 file) so PowerShell cannot strip the JSON's quotes from argv.
//   "shown" needs no session of its own: it reads what the receiver shows in whichever session runs it (the app's).
// Prints one JSON line: what the device answered. The session (transport id, media session id) is kept in
// %TEMP%/roradio-cast-e2e.json between calls, so each step is its own call and the script screenshots in between.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';

const APP_ID = 'F38F9694';
const SENDER = 'sender-roradio-e2e';
const NS = {
    connection: 'urn:x-cast:com.google.cast.tp.connection',
    heartbeat: 'urn:x-cast:com.google.cast.tp.heartbeat',
    receiver: 'urn:x-cast:com.google.cast.receiver',
    media: 'urn:x-cast:com.google.cast.media',
};
const stateFile = path.join(os.tmpdir(), 'roradio-cast-e2e.json');

/** Protobuf varint. */
function varint(value) {
    const bytes = [];
    let rest = value;
    while (rest > 0x7f) {
        bytes.push((rest & 0x7f) | 0x80);
        rest >>>= 7;
    }
    bytes.push(rest);
    return Buffer.from(bytes);
}

/** A length-delimited protobuf field. */
const text = (field, value) => {
    const data = Buffer.from(value, 'utf8');
    return Buffer.concat([varint((field << 3) | 2), varint(data.length), data]);
};

/** CastMessage: protocol_version CASTV2_1_0, source, destination, namespace, payload_type STRING, payload_utf8. */
function encode(destination, namespace, payload) {
    const body = Buffer.concat([
        Buffer.from([0x08, 0x00]),
        text(2, SENDER),
        text(3, destination),
        text(4, namespace),
        Buffer.from([0x28, 0x00]),
        text(6, JSON.stringify(payload)),
    ]);
    const size = Buffer.alloc(4);
    size.writeUInt32BE(body.length);
    return Buffer.concat([size, body]);
}

/** The text fields of a CastMessage (source 2, destination 3, namespace 4, payload 6). */
function decode(body) {
    const fields = {};
    let at = 0;
    while (at < body.length) {
        let key = 0;
        let shift = 0;
        let byte;
        do {
            byte = body[at++];
            key |= (byte & 0x7f) << shift;
            shift += 7;
        } while (byte & 0x80);
        if ((key & 7) === 0) {
            // A varint field (protocol_version, payload_type): skipped, byte by byte, to its last byte.
            while (body[at] & 0x80) {
                at += 1;
            }
            at += 1;
        } else {
            let length = 0;
            shift = 0;
            do {
                byte = body[at++];
                length |= (byte & 0x7f) << shift;
                shift += 7;
            } while (byte & 0x80);
            fields[key >> 3] = body.subarray(at, at + length).toString('utf8');
            at += length;
        }
    }
    return { source: fields[2], namespace: fields[4], payload: fields[6] ? JSON.parse(fields[6]) : null };
}

/** Connects, answers PINGs, and resolves each request with the device's answer of the same requestId. */
function connect(address) {
    const socket = tls.connect({ host: address, port: 8009, rejectUnauthorized: false });
    const waiting = new Map();
    const listeners = [];
    let buffer = Buffer.alloc(0);
    socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32BE(0)) {
            const message = decode(buffer.subarray(4, 4 + buffer.readUInt32BE(0)));
            buffer = buffer.subarray(4 + buffer.readUInt32BE(0));
            const payload = message.payload || {};
            if (payload.type === 'PING') {
                socket.write(encode(message.source, NS.heartbeat, { type: 'PONG' }));
            }

            listeners.forEach((listener) => listener(message));
            if (waiting.has(payload.requestId)) {
                waiting.get(payload.requestId)(message);
                waiting.delete(payload.requestId);
            }
        }
    });
    let requestId = 1;
    const send = (destination, namespace, payload) => socket.write(encode(destination, namespace, payload));
    const request = (destination, namespace, payload, timeoutMs = 20000) =>
        new Promise((resolve, reject) => {
            const id = ++requestId;
            const timer = setTimeout(() => reject(new Error(`No answer to ${payload.type} in ${timeoutMs} ms`)), timeoutMs);
            waiting.set(id, (message) => {
                clearTimeout(timer);
                resolve(message.payload);
            });
            send(destination, namespace, { ...payload, requestId: id });
        });
    return new Promise((resolve, reject) => {
        socket.once('error', reject);
        socket.once('secureConnect', () => {
            send('receiver-0', NS.connection, { type: 'CONNECT' });
            resolve({ socket, send, request, listeners });
        });
    });
}

/** What the page broadcasts while a press is made: its steps, the request each came by, what it dropped, the screen. */
function listen(cast) {
    const heard = { steps: [], vias: [], skipped: [], shown: null };
    cast.listeners.push((message) => {
        const status = message.payload && message.payload.status && message.payload.status[0];
        const data = (status && status.customData) || {};
        if (data.step) {
            heard.steps.push(data.step);
            heard.vias.push(data.via);
        }

        // Test mode: a press the page took for a repeat, and the request it came by.
        if (data.skipped) {
            heard.skipped.push(`${data.skipped} (${data.via})`);
        }

        if (data.shown) {
            heard.shown = data.shown;
        }
    });
    return heard;
}

const load = (url, title, artist, extra) => ({
    contentId: url,
    contentType: 'audio/mpeg',
    streamType: 'LIVE',
    metadata: {
        metadataType: 3,
        title,
        songName: title,
        artist,
        subtitle: artist,
        albumName: extra.album,
        releaseDate: extra.year,
        images: extra.images.map((imageUrl) => ({ url: imageUrl })),
    },
    customData: JSON.stringify(extra.data),
});

async function main() {
    // Windows PowerShell strips " from a JSON argv (native command quoting), so the e2e script can pass @path
    // to a UTF-8 file instead of the JSON text. A bare JSON string still works from bash / cmd.
    const [address, step, json] = process.argv.slice(2);
    const raw = json && json.startsWith('@') ? fs.readFileSync(json.slice(1), 'utf8') : json;
    const input = raw ? JSON.parse(raw) : {};
    const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : {};
    const cast = await connect(address);
    const app = () => {
        cast.send(state.transportId, NS.connection, { type: 'CONNECT' });
        return state.transportId;
    };
    let answer;
    switch (step) {
        case 'launch': {
            const status = await cast.request('receiver-0', NS.receiver, { type: 'LAUNCH', appId: APP_ID }, 40000);
            const running = (status.status.applications || []).find((a) => a.appId === APP_ID);
            if (!running) {
                throw new Error(`The device runs ${JSON.stringify(status.status.applications)} instead of ${APP_ID}`);
            }

            state.transportId = running.transportId;
            // Every audio test at volume 10 / 100.
            await cast.request('receiver-0', NS.receiver, { type: 'SET_VOLUME', volume: { level: 0.1 } });
            answer = { appId: running.appId, displayName: running.displayName };
            break;
        }
        case 'load': {
            const media = load(input.url, input.title, input.artist, input);
            const status = await cast.request(app(), NS.media, { type: 'LOAD', media, autoplay: true }, 40000);
            state.mediaSessionId = status.status && status.status[0] && status.status[0].mediaSessionId;
            // The LOAD's own answer can still be IDLE (the Pixel Tablet, 2026-11-14): the stream starts a moment
            // later. The player state is asked again until it plays, for up to 20 s.
            let playerState = status.status && status.status[0] && status.status[0].playerState;
            for (let tries = 0; tries < 20 && !['PLAYING', 'BUFFERING'].includes(playerState); tries += 1) {
                await new Promise((resolve) => setTimeout(resolve, 1000));
                const now = await cast.request(app(), NS.media, { type: 'GET_STATUS' });
                playerState = now.status && now.status[0] && now.status[0].playerState;
            }
            answer = { type: status.type, playerState };
            break;
        }
        case 'song': {
            const media = load(input.url, input.title, input.artist, input);
            const items = [{ itemId: input.itemId || 1, media }];
            cast.send(app(), NS.media, { type: 'QUEUE_UPDATE', mediaSessionId: state.mediaSessionId, items, requestId: 900 });
            answer = { sent: 'QUEUE_UPDATE' };
            break;
        }
        case 'pause':
        case 'play': {
            const status = await cast.request(app(), NS.media, { type: step.toUpperCase(), mediaSessionId: state.mediaSessionId });
            answer = { playerState: status.status && status.status[0] && status.status[0].playerState };
            break;
        }
        case 'tap':
        case 'jump': {
            // A press made while this sender listens for 4 s: a tap on a touch display's system media bar, or (a TV,
            // no touch screen) the queue jump a remote's or a sender's previous / next sends. The page broadcasts each
            // step as a media status ({"step", "stepId", "shown"}), which only a connected sender hears. Every step
            // heard is counted (one press must be one step), and the last "shown" says what the screen shows.
            const transport = app();
            const heard = listen(cast);
            if (step === 'tap') {
                const { execFileSync } = await import('node:child_process');
                execFileSync('adb', ['-s', input.device, 'shell', 'input', 'tap', String(input.x), String(input.y)]);
            } else {
                cast.send(transport, NS.media, { type: 'QUEUE_UPDATE', mediaSessionId: state.mediaSessionId, jump: input.jump, requestId: 700 + input.jump });
            }

            await new Promise((resolve) => setTimeout(resolve, 4000));
            answer = heard;
            break;
        }
        case 'avail': {
            // Whether the device can run the RoRadio receiver now (a stale cached app config answers APP_UNAVAILABLE).
            const reply = await cast.request('receiver-0', NS.receiver, { type: 'GET_APP_AVAILABILITY', appId: [APP_ID] }, 40000);
            answer = { availability: reply.availability && reply.availability[APP_ID] };
            break;
        }
        case 'status': {
            const status = await cast.request(app(), NS.media, { type: 'GET_STATUS' });
            const media = status.status && status.status[0];
            answer = { playerState: media && media.playerState, customData: media && media.customData };
            break;
        }
        case 'shown': {
            // What the RoRadio receiver shows now, from any sender's session (the app's own cast too): the running
            // app's transport from the device, then its media status, whose customData carries "shown".
            const device = await cast.request('receiver-0', NS.receiver, { type: 'GET_STATUS' });
            const running = (device.status.applications || []).find((a) => a.appId === APP_ID);
            if (!running) {
                throw new Error(`${APP_ID} is not running`);
            }

            cast.send(running.transportId, NS.connection, { type: 'CONNECT' });
            const status = await cast.request(running.transportId, NS.media, { type: 'GET_STATUS' });
            const media = status.status && status.status[0];
            answer = (media && media.customData && media.customData.shown) || null;
            break;
        }
        case 'stop': {
            const status = await cast.request('receiver-0', NS.receiver, { type: 'STOP' });
            answer = { applications: (status.status.applications || []).map((a) => a.appId) };
            break;
        }
        default:
            throw new Error(`Unknown step ${step}`);
    }

    fs.writeFileSync(stateFile, JSON.stringify(state));
    process.stdout.write(`${JSON.stringify(answer)}\n`);
    // The device sees a QUEUE_UPDATE before the socket closes.
    setTimeout(() => cast.socket.end(), 500);
}

main().catch((e) => {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
});
