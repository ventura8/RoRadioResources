# Security audit, 2026-11-14

A security pass over the workflows, the scripts, the Cast receiver page and the history. Nothing listeners see changes.

## What changed

- **The receiver page has a Content-Security-Policy.** `receiver/index.html` runs scripts only from the Cast framework
  on `www.gstatic.com`, the Shaka player it loads from `ajax.googleapis.com`, and its own inline script, allowed by its
  SHA-256 hash: no `eval`, no plugins, no forms, no `<base>`. Pictures and streams stay allowed from any http(s) host,
  as stations use.
- **Only http(s) pictures.** A cover or logo url from the app's metadata that is not http(s) (`javascript:`, `data:`,
  junk) is not shown, and the url is normalized before it goes into the backdrop's CSS `url("...")`, so a quote in it
  cannot end the value.
- **Metadata stays text.** The page already drew every title, artist, album, caption and station name with
  `textContent`; a test now proves it, and that the script has no HTML or code parser (`innerHTML`, `eval`, ...).
- **The weekly refresh's write token reaches only the steps that use it.** `GH_TOKEN` moved from the job to the step
  that pushes and merges and the step that keeps the schedule alive; the probing steps, which talk to the
  broadcasters' servers, run without it.
- **Dependabot waits 7 days** before proposing a new release (`cooldown`), so a compromised release published and
  withdrawn within days never reaches a pull request.
- **zizmor at its strictest.** The lint runs `zizmor --persona pedantic .github` (informational notes and
  `dependabot.yml` included); the refresh job got its name.
- **markdownlint-cli2 0.24.1**, which no longer pulls the `re2js` with a quadratic-time lookbehind (GHSA-gg6h-894w-4m9c,
  high; lint tool only, never served).

## Checked

- `tests/receiver.test.js`: a title, artist, caption and station name of `<img src=x onerror=alert(1)>` render as
  that text; `javascript:`, `data:` and junk pictures are dropped and a quote stays inside the backdrop url; the CSP
  holds the inline script's exact hash and no `unsafe-eval`.
- `tests/receiver.browser.test.js`: the page under its own CSP in headless Chrome with the real Cast framework, with
  no CSP violation.
- zizmor (pedantic), `npm audit` and `pip-audit`: no findings. gitleaks over the whole history runs in the lint job.
