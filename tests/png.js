// Copyright 2026 Sergiu Alexandrescu
// A small PNG reader for the receiver's layout tests (Chrome's screenshots): 8-bit RGB or RGBA, not interlaced. No
// packages: Node's zlib inflates the image data, and the five PNG row filters are undone here.
'use strict';

const zlib = require('node:zlib');

/** The Paeth predictor of the PNG spec. */
function paeth(left, up, upLeft) {
    const p = left + up - upLeft;
    const pa = Math.abs(p - left);
    const pb = Math.abs(p - up);
    const pc = Math.abs(p - upLeft);
    if (pa <= pb && pa <= pc) {
        return left;
    }

    return pb <= pc ? up : upLeft;
}

/** Decodes a PNG buffer: { width, height, pixel(x, y) -> [r, g, b] }. */
function decode(buffer) {
    let at = 8;
    let width = 0;
    let height = 0;
    let channels = 0;
    const data = [];
    while (at < buffer.length) {
        const length = buffer.readUInt32BE(at);
        const type = buffer.toString('ascii', at + 4, at + 8);
        const chunk = buffer.subarray(at + 8, at + 8 + length);
        if (type === 'IHDR') {
            width = chunk.readUInt32BE(0);
            height = chunk.readUInt32BE(4);
            if (chunk[8] !== 8 || chunk[12] !== 0 || (chunk[9] !== 2 && chunk[9] !== 6)) {
                throw new Error('only 8-bit, non-interlaced RGB or RGBA PNGs are read');
            }

            channels = chunk[9] === 6 ? 4 : 3;
        } else if (type === 'IDAT') {
            data.push(chunk);
        }

        at += 12 + length;
    }

    const raw = zlib.inflateSync(Buffer.concat(data));
    const stride = width * channels;
    const pixels = Buffer.alloc(height * stride);
    for (let y = 0; y < height; y += 1) {
        const filter = raw[y * (stride + 1)];
        for (let x = 0; x < stride; x += 1) {
            const value = raw[y * (stride + 1) + 1 + x];
            const left = x >= channels ? pixels[y * stride + x - channels] : 0;
            const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
            const upLeft = x >= channels && y > 0 ? pixels[(y - 1) * stride + x - channels] : 0;
            const predicted = [0, left, up, (left + up) >> 1, paeth(left, up, upLeft)][filter];
            pixels[y * stride + x] = (value + predicted) & 0xff;
        }
    }

    const pixel = (x, y) => {
        const i = y * stride + x * channels;
        return [pixels[i], pixels[i + 1], pixels[i + 2]];
    };
    return { width, height, pixel };
}

module.exports = { decode };
