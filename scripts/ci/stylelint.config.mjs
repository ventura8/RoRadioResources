// stylelint for the Cast receiver's styles (the <style> of receiver/index.html), scripts/ci/Invoke-Lint.ps1:
// stylelint's standard config, read out of the HTML by postcss-html, with every finding an error.
export default {
    extends: ['stylelint-config-standard'],
    customSyntax: 'postcss-html',
    defaultSeverity: 'error',
    reportDescriptionlessDisables: true,
    reportInvalidScopeDisables: true,
    reportNeedlessDisables: true,
    rules: {
        // The page's ids are the script's names (byId('stationName')): camelCase, as in receiver.js.
        'selector-id-pattern': ['^[a-z][a-zA-Z0-9]*$', { message: 'Expected id selector to be camelCase' }],
    },
};
