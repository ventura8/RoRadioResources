// Copyright 2026 Sergiu Alexandrescu
// A minimal Cast V2 sender for scripts/e2e/Test-ReceiverOnTablet.ps1: no packages, Node's own TLS. It launches the
// RoRadio receiver (F38F9694) on a device and plays one step of the receiver's user flows a call, the way the app's
// SharpcasterTransport does: LOAD with the app's customData, QUEUE_UPDATE for a song, a step press read back from the
// media status, PAUSE / PLAY, STOP.
//
//   node cast-client.mjs <address> <step> [json]
//   steps: launch | load | song | pause | play | status | stop
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
    const [address, step, json] = process.argv.slice(2);
    const input = json ? JSON.parse(json) : {};
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
            answer = { type: status.type, playerState: status.status && status.status[0] && status.status[0].playerState };
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
        case 'tap': {
            // A tap on the page's own button, made while this sender listens: the page broadcasts the step as a media
            // status ({"step", "stepId"}), which only a connected sender hears.
            app();
            const heard = new Promise((resolve) => {
                cast.listeners.push((message) => {
                    const status = message.payload && message.payload.status && message.payload.status[0];
                    if (status && status.customData && status.customData.step) {
                        resolve(status.customData.step);
                    }
                });
                setTimeout(() => resolve(null), 8000);
            });
            const { execFileSync } = await import('node:child_process');
            execFileSync('adb', ['-s', input.device, 'shell', 'input', 'tap', String(input.x), String(input.y)]);
            answer = { step: await heard };
            break;
        }
        case 'status': {
            const status = await cast.request(app(), NS.media, { type: 'GET_STATUS' });
            const media = status.status && status.status[0];
            answer = { playerState: media && media.playerState, customData: media && media.customData };
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
