# Refresh notes without bare urls (2026-10-20)

The weekly refresh writes where each new stream url was found. A directory entry's own name can hold a web address
(`Radio Folclor Muntenia - www.radiofolclormuntenia.ro`), and a status page was written as a plain address. Both
were bare urls, which the Markdown lint refuses: the 2026-10-19 note turned this repository's checks red, and every
pull request after it failed.

- `scripts/Update-StationUrls.ps1`: a status page is a link, and any other source is quoted as code.
- `docs/releases/2026-10-19-refresh.md`: the same four cells, fixed by hand.

No station changed.
