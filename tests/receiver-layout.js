// Copyright 2026 Sergiu Alexandrescu
// The receiver's layout and accessibility checks, run by tests/receiver.browser.test.js in headless Chrome with the
// real Cast framework, for every screen size and every state:
//   - no visible text or picture overlaps another, and none is off screen or under a touch display's system bar;
//   - no text is cut: it fits its box, or it ends in an ellipsis or a line clamp;
//   - text at least 24 px at 1080p (10-foot UI), scaled to the screen's height;
//   - contrast at least WCAG AA (4.5:1, or 3:1 for large text) against the real background: the text is hidden, the
//     screen is captured, and the text colour is measured against every pixel under the text box;
//   - axe-core (pinned in scripts/ci/package.json) finds no violation;
//   - every control (none today) is at least 48 x 48 px.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { decode } = require('./png');

const axeSource = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'ci', 'node_modules', 'axe-core', 'axe.min.js'), 'utf8');

/** The share of a touch display's height its system media bar covers, from the bottom (Pixel Tablet). */
const SYSTEM_BAR = 0.28;

/** The page's leaves: every text and picture the listener sees. */
const LEAVES = ['#appIcon', '#idle h1', '#status', '#hint', '#cover', '#station img', '#stationName', '#title', '#artist', '#release', '#captionText'];

/** Runs in the page: the visible leaves with their boxes, text sizes, colours and whether a text is cut. */
const MEASURE = `(() => {
    const leaves = ${JSON.stringify(LEAVES)};
    return leaves.flatMap((selector) => {
        const element = document.querySelector(selector);
        const r = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        const shown = element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
        const text = element.tagName !== 'IMG' && element.textContent.trim() !== '';
        if (!shown || r.width < 1 || r.height < 1 || (element.tagName === 'IMG' && !element.getAttribute('src')) || (element.tagName !== 'IMG' && !text)) {
            return [];
        }

        const clamped = style.textOverflow === 'ellipsis' || (style.webkitLineClamp && style.webkitLineClamp !== 'none');
        const cut = element.scrollWidth > element.clientWidth + 1 || element.scrollHeight > element.clientHeight + 1;
        return [{
            selector, text, left: r.left, top: r.top, right: r.right, bottom: r.bottom,
            fontSize: parseFloat(style.fontSize), fontWeight: Number(style.fontWeight), color: style.color,
            cut: text && cut && !clamped,
        }];
    });
})()`;

/** The relative luminance of an sRGB colour (WCAG 2.x). */
function luminance([r, g, b]) {
    const channel = (value) => {
        const c = value / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

/** The contrast ratio of two colours. */
function contrast(a, b) {
    const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (light + 0.05) / (dark + 0.05);
}

/** "rgb(r, g, b)" or "rgba(r, g, b, a)" as [r, g, b, a]. */
function rgba(css) {
    const [r, g, b, a = 1] = css.match(/[\d.]+/g).map(Number);
    return [r, g, b, a];
}

/** The text colour over one background pixel: the text's alpha blends it with what is under it. */
function over([r, g, b, a], background) {
    return [r, g, b].map((c, i) => c * a + background[i] * (1 - a));
}

/** Whether two boxes share more than a pixel. */
function overlap(a, b) {
    return Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1;
}

/** Every problem the screen has now, as text; none is an empty list. */
async function problems(session, { width, height, touch }) {
    const found = [];
    const leaves = await session.evaluate(MEASURE);
    const floor = height * (touch ? 1 - SYSTEM_BAR : 1);
    for (const leaf of leaves) {
        if (leaf.left < -0.5 || leaf.top < -0.5 || leaf.right > width + 0.5 || leaf.bottom > floor + 0.5) {
            found.push(`${leaf.selector} is off screen${touch ? ' or under the system bar' : ''}: ${JSON.stringify(leaf)}`);
        }

        if (leaf.cut) {
            found.push(`${leaf.selector} is cut without an ellipsis`);
        }

        if (leaf.text && leaf.fontSize < (24 * height) / 1080 - 0.5) {
            found.push(`${leaf.selector} is ${leaf.fontSize} px, under 24 px at 1080p`);
        }
    }

    for (let i = 0; i < leaves.length; i += 1) {
        for (let j = i + 1; j < leaves.length; j += 1) {
            if (overlap(leaves[i], leaves[j])) {
                found.push(`${leaves[i].selector} overlaps ${leaves[j].selector}`);
            }
        }
    }

    found.push(...(await contrastProblems(session, leaves)));
    found.push(...(await axeProblems(session)));
    const small = await session.evaluate(`[...document.querySelectorAll('button, a[href], input, select, [role=button]')]
        .filter((e) => e.checkVisibility()).map((e) => e.getBoundingClientRect())
        .filter((r) => r.width < 48 || r.height < 48).length`);
    if (small > 0) {
        found.push(`${small} control(s) smaller than 48 x 48 px`);
    }

    return found;
}

/** The text hidden, the screen captured: each text's colour against every pixel under it. */
async function contrastProblems(session, leaves) {
    const found = [];
    await session.evaluate(`(() => {
        const style = document.createElement('style');
        style.id = 'hide-text';
        style.textContent = '* { color: transparent !important; text-shadow: none !important; }';
        document.head.append(style);
    })()`);
    const shot = await session.send('Page.captureScreenshot', { format: 'png' });
    await session.evaluate('document.getElementById("hide-text").remove()');
    const image = decode(Buffer.from(shot.data, 'base64'));
    for (const leaf of leaves.filter((l) => l.text)) {
        const color = rgba(leaf.color);
        const large = leaf.fontSize >= 24 || (leaf.fontWeight >= 700 && leaf.fontSize >= 18.66);
        const needed = large ? 3 : 4.5;
        let worst = Infinity;
        for (let y = Math.max(0, Math.floor(leaf.top)); y < Math.min(image.height, Math.ceil(leaf.bottom)); y += 2) {
            for (let x = Math.max(0, Math.floor(leaf.left)); x < Math.min(image.width, Math.ceil(leaf.right)); x += 2) {
                const background = image.pixel(x, y);
                worst = Math.min(worst, contrast(over(color, background), background));
            }
        }

        if (worst < needed) {
            found.push(`${leaf.selector} contrast ${worst.toFixed(2)}:1, under ${needed}:1`);
        }
    }

    return found;
}

/** axe-core in the page (injected over DevTools, as the page's CSP allows no other script): its violations. */
async function axeProblems(session) {
    if (!(await session.evaluate('typeof window.axe'))?.startsWith('object')) {
        await session.send('Runtime.evaluate', { expression: axeSource });
    }

    const violations = await session.evaluate(`axe.run(document, { resultTypes: ['violations'] })
        .then((r) => r.violations.map((v) => v.id + ': ' + v.nodes.map((n) => n.target.join(' ')).join(', ')))`);
    return violations.map((v) => `axe ${v}`);
}

/** Sets the viewport (CSS px, 1 device px each). */
async function resize(session, width, height) {
    await session.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
}

module.exports = { problems, resize, contrast, luminance, SYSTEM_BAR };
