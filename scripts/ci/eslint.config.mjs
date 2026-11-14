// ESLint for the Cast receiver's script and its tests (scripts/ci/Invoke-Lint.ps1). The receiver's script gets every
// core rule (eslint:all). Two are off, each with its reason; a few take an option instead of their default.
// The tests get the recommended rules plus the strict ones that catch real mistakes.
import js from '@eslint/js';
import globals from 'globals';

export default [
    {
        files: ['receiver/*.js'],
        ...js.configs.all,
        languageOptions: {
            ecmaVersion: 2022,
            // A classic script in the page, after Google's Cast framework (the `cast` global).
            sourceType: 'script',
            globals: { ...globals.browser, cast: 'readonly' },
        },
        rules: {
            ...js.configs.all.rules,
            // Off: the Cast framework's supported media commands are a bit mask (Command.QUEUE_PREV | ...), which the
            // script sets with | and & as the framework defines them.
            'no-bitwise': 'off',
            // Off: a ternary is the clearest form for the page's two-way labels and fallbacks (play / pause, a year
            // or nothing); `no-nested-ternary` stays on, so none grows into a chain.
            'no-ternary': 'off',
            // Options, not off: 0, 1 and -1 (indexes, a jump of one) are not magic; every other number is a named const.
            'no-magic-numbers': ['error', { ignore: [-1, 0, 1], ignoreArrayIndexes: true, enforceConst: true }],
            // A comment's later lines continue its sentence.
            'capitalized-comments': ['error', 'always', { ignoreConsecutiveComments: true }],
            // One declaration a line, each beside its comment.
            'one-var': ['error', 'never'],
            // Named functions with JSDoc for the page's steps, arrows for the small callbacks.
            'func-style': ['error', 'declaration', { allowArrowFunctions: true }],
            // Ten statements a function; the one function around the whole script is the script itself.
            'max-statements': ['error', 10, { ignoreTopLevelFunctions: true }],
            // 300 lines of code; the comments that explain the device findings do not count against it.
            'max-lines': ['error', { max: 300, skipBlankLines: true, skipComments: true }],
            // Functions are declared where they are read, after the helpers they use (they are hoisted).
            'no-use-before-define': ['error', { functions: false }],
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
