// Copyright 2026 Sergiu Alexandrescu
// The song's texts fitted to the song's column on the cast screen (owner, 2026-11-14): the title, the artist and the
// album take up to two lines each and shrink in steps, down to 24 px at 1080p, before an ellipsis; the year has a line
// of its own under the album, and joins the album's line ("Deliria · 2015") only when the column has no room for it.
// Loaded by receiver/index.html before receiver.js.
(function fit() {
'use strict';

const byId = (id) => document.getElementById(id);

/** A text shrinks by this much a step, down to 24 px at 1080p (10-foot UI), before its second line is cut. */
const FIT_STEP = 0.9;
const READABLE_AT_1080P = 24;
const FULL_HD_HEIGHT = 1080;
const FITTED = ['title', 'artist', 'release'];
const TOO_TALL = 2.5;
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
 * Up to two lines for a text (the styles clamp it at two): it keeps its full size while it fits, and shrinks in
 * steps to the readable minimum while it needs more; only then does its second line end in an ellipsis.
 */
function fitText(element, minimum) {
    element.style.fontSize = '';
    // More than two lines: its full height passes two and a half lines (a line's glyphs may overhang it a little).
    const tooTall = () => element.scrollHeight > TOO_TALL * parseFloat(getComputedStyle(element).lineHeight);
    while (tooTall() && shrink(element, minimum)) {
        // Shrunk one step; measured again.
    }
}

/** Whether the song's texts need more than their column: past its bottom, or into the station's line under them. */
function crowded(texts) {
    const song = byId('song');
    const station = byId('station');
    const line = station.classList.contains('empty') ? Infinity : station.getBoundingClientRect().top;
    return song.scrollHeight > song.clientHeight + 1 || texts.some((element) => element.getBoundingClientRect().bottom > line + 1);
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

/**
 * The song's texts fitted to their two lines, the year on its own line if there is room, then all together to the
 * song's column: while they pass the station's line at its bottom, all of them shrink a step.
 */
function fitSong() {
    const minimum = (READABLE_AT_1080P * window.innerHeight) / FULL_HD_HEIGHT;
    const texts = [...FITTED, 'yearLine'].map(byId);
    // The year's line from its full size too: a size shrunk on another screen stayed under the minimum here.
    byId('yearLine').style.fontSize = '';
    placeYear(false);
    FITTED.forEach((id) => fitText(byId(id), minimum));
    if (crowded(texts)) {
        // No room for the year's own line: it joins the album's ("Deliria · 2015"), and the texts are fitted again.
        placeYear(true);
        FITTED.forEach((id) => fitText(byId(id), minimum));
    }

    while (crowded(texts) && texts.map((element) => shrink(element, minimum)).includes(true)) {
        // All of them shrunk a step; measured again.
    }
}

/** The song's year, placed on its own line (fitSong may join it to the album's once the song is drawn). */
function setYear(year) {
    songYear = year;
    placeYear(false);
}

window.songFit = { fitSong, setYear };
}());
