// Copyright 2026 Sergiu Alexandrescu
// Whether a station logo is too dark for the cast receiver's dark screen (dark lettering on transparency), measured
// on the picture itself. Loaded by receiver/index.html before receiver.js, which gives such a logo its light glow;
// tests/test_transparent_logo.py checks the same measure, with the same constants, over every logo in RadioLogos.
(function logoTone() {
'use strict';

/** The contrast a logo's pixel needs on the receiver's background to be seen (as in transparent_logo.py). */
const VISIBLE_CONTRAST = 2;
/** A logo with more than this share of its opaque pixels too dark to see gets the light treatment. */
const DARK_SHARE = 0.5;
/** The size logos are measured at: the decision needs shapes, not detail. */
const MEASURED = 64;
/** A pixel at least this opaque is part of the logo's mark. */
const OPAQUE = 128;
/** One RGBA pixel's bytes. */
const RGBA = 4;

/** WCAG 2.x relative luminance, and the receiver's background (#08090c) by it. */
const WCAG = { background: 0.0029, blue: 0.0722, channel: 255, flare: 0.05, gamma: 2.4, green: 0.7152 };
Object.assign(WCAG, { knee: 0.03928, offset: 0.055, red: 0.2126, scale: 1.055, slope: 12.92 });

/** The linear light of one sRGB channel value, 0-255. */
function linear(value) {
    const channel = value / WCAG.channel;
    return channel <= WCAG.knee ? channel / WCAG.slope : ((channel + WCAG.offset) / WCAG.scale) ** WCAG.gamma;
}

/** Whether one RGBA pixel is part of the mark and too dark to see on the receiver's background: [mark, dark]. */
function darkPixel([red, green, blue, alpha]) {
    if (alpha < OPAQUE) {
        return [0, 0];
    }

    const luminance = WCAG.red * linear(red) + WCAG.green * linear(green) + WCAG.blue * linear(blue);
    return [1, (luminance + WCAG.flare) / (WCAG.background + WCAG.flare) < VISIBLE_CONTRAST ? 1 : 0];
}

/** The share of a picture's mark that is too dark, from its RGBA bytes; 0 when nothing is opaque. */
function darkShare(data) {
    let mark = 0;
    let dark = 0;
    for (let index = 0; index < data.length; index += RGBA) {
        const [isMark, isDarkPixel] = darkPixel(data.slice(index, index + RGBA));
        mark += isMark;
        dark += isDarkPixel;
    }

    return mark > 0 ? dark / mark : 0;
}

/**
 * Whether a loaded logo is mostly too dark to see on the receiver's dark background (dark lettering on
 * transparency). A picture from a host without CORS cannot be read: it is taken as readable.
 */
function isDark(picture) {
    const canvas = document.createElement('canvas');
    canvas.width = MEASURED;
    canvas.height = MEASURED;
    const context2d = canvas.getContext('2d');
    try {
        context2d.drawImage(picture, 0, 0, MEASURED, MEASURED);
        return darkShare(context2d.getImageData(0, 0, MEASURED, MEASURED).data) > DARK_SHARE;
    } catch {
        return false;
    }
}

window.logoTone = { isDark };
}());
