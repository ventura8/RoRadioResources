// html-validate for the Cast receiver's page (receiver/index.html), scripts/ci/Invoke-Lint.ps1: the recommended and
// accessibility presets, every finding an error.
'use strict';

module.exports = {
    extends: ['html-validate:recommended', 'html-validate:a11y'],
    rules: {
        'no-inline-style': 'error',
        // The page loads Google's Cast framework, which Google updates in place at a fixed url: no hash can be pinned.
        'require-sri': 'off',
        // The song's title and artist headings, and the cover and logo pictures, are empty until receiver.js fills
        // them from the station: a src before the picture loaded would show a broken image.
        'empty-heading': 'off',
        'element-required-attributes': 'off',
    },
};
