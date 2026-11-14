// Copyright 2026 Sergiu Alexandrescu
// The receiver's test mode (a test sender's {"rects": true}): where each thing is drawn, for an on-device E2E that
// checks overlaps and contrast on the device's own screenshot (scripts/e2e/Test-ReceiverOnTablet.ps1). Loaded by
// receiver/index.html before receiver.js, which adds it to the "shown" status in test mode only.
(function layoutReport() {
'use strict';

/** The leaves an on-device test measures on the device's own screenshot. */
const LEAVES = ['cover', 'stationName', 'title', 'artist', 'release', 'captionText'];

/**
 * Each visible leaf's box (CSS px, [left, top, right, bottom]), its text colour, the device pixel ratio and the
 * viewport.
 */
function layoutNow() {
    const byId = (id) => document.getElementById(id);
    const rects = {};
    for (const id of [...LEAVES, 'station']) {
        const box = (id === 'station' ? byId(id).querySelector('img') : byId(id)).getBoundingClientRect();
        if (box.width > 0 && box.height > 0) {
            rects[id] = { box: [box.left, box.top, box.right, box.bottom], color: getComputedStyle(byId(id)).color };
        }
    }

    return { rects, scale: window.devicePixelRatio, viewport: [window.innerWidth, window.innerHeight] };
}

window.layoutReport = { layoutNow };
}());
