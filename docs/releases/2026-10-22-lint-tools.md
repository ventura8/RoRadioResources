# Lint tools past the markdown-it and katex advisories (2026-10-22)

The Markdown lint's dependencies had two published advisories. Neither reaches the station list or the logos: they
are the tools that check this repository's text.

- `markdownlint-cli2` 0.24.0 (was 0.23.3): it brings `markdown-it` 15.0.3, past GHSA-r7fv-28h4-cvq7 (quadratic time
  on unmatched closing quotes, fixed in 15.0.2).
- `katex` 0.19.0 through an npm override: the newest `markdownlint` still takes it through `micromark-extension-math`
  at `^0.16`, inside GHSA-238p-pmpm-9mq7 (fixed in 0.18.2). The lint only parses math syntax and never renders it,
  so the newer major changes nothing it does.

`npm audit` still reports the `braces` chain under `markdownlint-cli2` (GHSA-vfj7-8cjw-p6xm): it has no fixed release,
and the only "fix" npm offers is a downgrade of the lint. No station changed.
