// Copyright 2026 Sergiu Alexandrescu
// The app's cover colour theme on the cast screen (2.4.5): when the user has the app's opt-in "cover colours" on,
// the app sends its own colours in the item's customData, {"theme": {"accent": "#rrggbb", "tint": "#rrggbb"}}: the
// accent taken from the cover and the tint the app tints its window with (AppColorHelper.ReadableTint, the colour
// white text reads on). The page's scrim takes the tint and its highlights the accent; without a theme the page has
// its default look. Loaded by receiver/index.html before receiver.js.
(function theme() {
'use strict';

const HEX = /^#[\da-f]{6}$/iu;

/** Whether a value is a colour as "#rrggbb" text (an array of one, ['#f0e040'], is not: it only reads as one). */
const isColour = (value) => typeof value === 'string' && HEX.test(value);

/** The app's theme from its customData: both colours as "#rrggbb", or null (none sent, or not colours). */
function themeOf(value) {
    if (!value || typeof value !== 'object' || !isColour(value.accent) || !isColour(value.tint)) {
        return null;
    }

    return { accent: value.accent.toLowerCase(), tint: value.tint.toLowerCase() };
}

/** The page in the theme's colours, or back to its default look (null). */
function applyTheme(colours) {
    const { style } = document.documentElement;
    document.body.classList.toggle('themed', Boolean(colours));
    if (colours) {
        style.setProperty('--theme-tint', colours.tint);
        style.setProperty('--accent', colours.accent);
    } else {
        style.removeProperty('--theme-tint');
        style.removeProperty('--accent');
    }
}

window.receiverTheme = { applyTheme, themeOf };
}());
