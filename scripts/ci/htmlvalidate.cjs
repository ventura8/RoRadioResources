// html-validate for the Cast receiver's page (receiver/index.html), scripts/ci/Invoke-Lint.ps1: the recommended and
// accessibility presets, every rule on, every finding an error.
'use strict';

module.exports = {
    extends: ['html-validate:recommended', 'html-validate:a11y'],
    elements: [
        'html5',
        {
            // The cover and the logo get their src from receiver.js once the picture has loaded (a src before that
            // would show a broken picture); every <img> still needs its alt.
            img: { attributes: { src: { required: false } } },
        },
    ],
    rules: {
        'no-inline-style': 'error',
        // Google's Cast framework is served at a fixed url that Google updates in place: it cannot carry an
        // integrity hash. Every other script is the page's own (receiver.js, same origin).
        'require-sri': ['error', { target: 'crossorigin', exclude: ['https://www.gstatic.com/cast/'] }],
    },
};
