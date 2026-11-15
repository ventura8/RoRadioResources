# Privacy policy: the sync service, 2026-11-14

RoRadio 2.4.5 no longer talks to MongoDB Atlas from the app. Settings sync and the album-cover cache go through
RoRadio's own sync service on Cloudflare Workers, which alone holds the database credential. Merge this before
RoRadio 2.4.5 ships.

## What changed

- **Cloud sync** says the app sends the Microsoft sign-in token to the sync service, which checks it and works out the
  record key itself, and that Cloudflare sees the IP address of the request, which is used only for rate limiting.
- **Album art** names the sync service as the cache's front door.
- Nothing new is stored: the record is still keyed by a one-way hash of the account identifier.

## Checked

- The page renders, and its links are unchanged.
