// Copyright 2026 Sergiu Alexandrescu
// The receiver's test mode (a test sender's {"rects": true}): where each thing is drawn, for an on-device E2E that
// checks overlaps and contrast on the device's own screenshot (scripts/e2e/Test-ReceiverOnTablet.ps1). Loaded by
// receiver/index.html before receiver.js, which adds it to the "shown" status in test mode only.
(function layoutReport() {
'use strict';

/** The leaves an on-device test measures on the device's own screenshot. */
const LEAVES = ['cover', 'stationName', 'title', 'artist', 'release', 'yearLine', 'captionText'];

/**
 * Each visible leaf's box (CSS px, [left, top, right, bottom]), its text colour and its words, the device pixel ratio
 * and the viewport. A leaf hidden by visibility or a zero opacity keeps its box but is not drawn: it is left out, so
 * an E2E comparing two screens sees it gone (CodeRabbit, #49).
 */
function layoutNow() {
    const byId = (id) => document.getElementById(id);
    const rects = {};
    for (const id of [...LEAVES, 'station']) {
        const element = id === 'station' ? byId(id).querySelector('img') : byId(id);
        const box = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        if (box.width > 0 && box.height > 0 && style.visibility !== 'hidden' && style.opacity !== '0') {
            rects[id] = {
                box: [box.left, box.top, box.right, box.bottom],
                color: getComputedStyle(byId(id)).color,
                text: id === 'station' || id === 'cover' ? '' : byId(id).textContent,
            };
        }
    }

    return { rects, scale: window.devicePixelRatio, viewport: [window.innerWidth, window.innerHeight] };
}

window.layoutReport = { layoutNow };
}());
