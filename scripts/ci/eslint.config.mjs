// ESLint for the Cast receiver's script and its tests (scripts/ci/Invoke-Lint.ps1). The receiver's script gets every
// core rule (eslint:all); only rules that contradict how the script must be written are off, each with its reason.
// The tests get the recommended rules plus the strict ones that catch real mistakes.
import js from '@eslint/js';
import globals from 'globals';

export default [
    {
        files: ['receiver/receiver.js'],
        ...js.configs.all,
        languageOptions: {
            ecmaVersion: 2022,
            // A classic script in the page, after Google's Cast framework (the `cast` global).
            sourceType: 'script',
            globals: { ...globals.browser, cast: 'readonly' },
        },
        rules: {
            ...js.configs.all.rules,
            // The Cast framework's media commands are a bit mask: the script adds and removes bits.
            'no-bitwise': 'off',
            // The framework's numbers and the page's sizes are named where they are used; constants would only rename.
            'no-magic-numbers': 'off',
            // Comments are sentences that may start with a code name (`customData`, `cast-media-player`).
            'capitalized-comments': 'off',
            // The app's JSON is built in the order the page reads it; the keys are not a list to sort.
            'sort-keys': 'off',
            // One declaration a line reads better beside its comment.
            'one-var': 'off',
            // Short ternaries for a label or a fallback are the clearest form.
            'no-ternary': 'off',
            // `id`, `e`: the DOM's own names.
            'id-length': 'off',
            // Named functions with JSDoc for the page's steps, arrows for the small callbacks.
            'func-style': 'off',
            // The script is a sequence of registrations in the page's order; size limits would only split it.
            'max-statements': 'off',
            'max-lines-per-function': 'off',
            'max-lines': 'off',
            // The framework's broadcastStatus takes `undefined` for "no request id".
            'no-undefined': 'off',
            // `const { x } = y` where it reads better, `y.x` where the name would change.
            'prefer-destructuring': 'off',
            // `let x = null` until it is known is the clearest state.
            'init-declarations': 'off',
            'no-inline-comments': 'off',
            'line-comment-position': 'off',
            // Functions are declared where they are read, after the helpers they use.
            'no-use-before-define': ['error', { functions: false }],
            // The ternary for a play / pause label and the empty-string fallbacks are intended.
            'no-nested-ternary': 'error',
        },
    },
    {
        files: ['tests/*.js', 'scripts/e2e/*.mjs'],
        ...js.configs.recommended,
        languageOptions: {
            ecmaVersion: 2024,
            sourceType: 'commonjs',
            globals: { ...globals.node, cast: 'readonly', window: 'readonly', document: 'readonly' },
        },
        rules: {
            ...js.configs.recommended.rules,
            eqeqeq: 'error',
            'no-var': 'error',
            'prefer-const': 'error',
            'no-shadow': 'error',
            // Stubs keep the framework's own parameter lists, so a later parameter used means the earlier ones stay.
            'no-unused-vars': ['error', { args: 'after-used' }],
            strict: ['error', 'global'],
            curly: 'error',
        },
    },
    {
        // The on-device E2E sender is an ES module.
        files: ['scripts/e2e/*.mjs'],
        languageOptions: { sourceType: 'module' },
    },
];
