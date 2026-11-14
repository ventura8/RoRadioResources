// Copyright 2026 Sergiu Alexandrescu
// The song's texts fitted to the song's column on the cast screen. Owner, 2026-11-14: never cut a text and never an
// ellipsis; the title, the artist and the album always show in full. Every text wraps over as many lines as it
// needs; when they do not all fit the column (above the station's line, and above a touch display's system bar), in
// this order: the live caption yields its band, the year joins the album's line ("Deliria · 2015"), the texts shrink
// in steps to 24 px at 1080p, and then, only when that is the only way, to 16 px at 1080p.
// Loaded by receiver/index.html before receiver.js.
(function fit() {
'use strict';

const byId = (id) => document.getElementById(id);

/** A text shrinks by this much a step. */
const FIT_STEP = 0.9;
/** The 10-foot size a text keeps while it fits, and the floor it may go to when nothing else fits (at 1080p). */
const READABLE_AT_1080P = 24;
const FLOOR_AT_1080P = 16;
const FULL_HD_HEIGHT = 1080;
const FITTED = ['title', 'artist', 'release', 'yearLine'];
const HALF_PIXEL = 0.5;

/** The song's release year ("2015"), or '' for none. */
let songYear = '';

/** One step smaller, never under `minimum`; whether it could shrink at all. */
function shrink(element, minimum) {
    const size = parseFloat(getComputedStyle(element).fontSize);
    // Within half a pixel of it is the minimum: the browser rounds a size it was given (35.5556 for 35.55555), and
    // an exact test shrank to the same size forever (tablet, 2026-11-14).
    if (size <= minimum + HALF_PIXEL) {
        return false;
    }

    element.style.fontSize = `${Math.max(size * FIT_STEP, minimum)}px`;
    return true;
}

/**
 * Whether the texts do not fit: the song's column overflows, a text reaches into the station's line under it, or
 * the caption band passes the bottom of the page's safe area.
 */
function crowded(texts) {
    const song = byId('song');
    const station = byId('station');
    const line = station.classList.contains('empty') ? Infinity : station.getBoundingClientRect().top;
    const main = byId('captions').parentElement;
    const captionsOut = Boolean(main) && byId('captions').getBoundingClientRect().bottom > main.getBoundingClientRect().bottom + 1;
    return song.scrollHeight > song.clientHeight + 1 || captionsOut || texts.some((element) => element.getBoundingClientRect().bottom > line + 1);
}

/**
 * The year on its own line under the album (owner, 2026-11-14), or on the album's line ("Deliria · 2015") when the
 * column has no room for one more line (`joined`); with no album it is the album's line alone.
 */
function placeYear(joined) {
    const together = joined || !byId('album').textContent;
    byId('year').textContent = together ? songYear : '';
    byId('yearLine').textContent = together ? '' : songYear;
    byId('yearLine').classList.toggle('empty', !byId('yearLine').textContent);
    byId('release').classList.toggle('empty', !byId('album').textContent && !byId('year').textContent);
}

/** The live caption's band, or none: the caption is the first to give its room to the song. */
function yieldCaption(yields) {
    const caption = Boolean(byId('captionText').textContent);
    document.body.classList.toggle('caption-yields', yields && caption);
    document.body.classList.toggle('captioned', caption && !yields);
}

/** All the texts a step smaller while they do not fit, down to `minimum`. */
function shrinkAll(texts, minimum) {
    while (crowded(texts) && texts.map((element) => shrink(element, minimum)).includes(true)) {
        // All of them shrunk a step; measured again.
    }
}

/**
 * The song's texts in full in the song's column: at their own size while they fit; else the caption yields, the
 * year joins the album's line, and the texts shrink to 24 px at 1080p, then (the only way left) to 16 px at 1080p.
 */
function fitSong() {
    const scale = window.innerHeight / FULL_HD_HEIGHT;
    const texts = FITTED.map(byId);
    texts.forEach((element) => {
        element.style.fontSize = '';
    });
    yieldCaption(false);
    placeYear(false);
    const steps = [() => yieldCaption(true), () => placeYear(true), () => shrinkAll(texts, READABLE_AT_1080P * scale), () => shrinkAll(texts, FLOOR_AT_1080P * scale)];
    for (const step of steps) {
        if (!crowded(texts)) {
            return;
        }

        step();
    }
}

/** The song's year, placed on its own line (fitSong may join it to the album's once the song is drawn). */
function setYear(year) {
    songYear = year;
    placeYear(false);
}

window.songFit = { fitSong, setYear };
}());
