# Privacy policy on Pages, 2026-09-30

`privacy.html` joins the station list on
[GitHub Pages](https://ventura8.github.io/RoRadioResources/privacy.html). It is the policy RoRadio needs for the
Microsoft Store: Store Policy 10.5.1 requires a privacy policy at the URL given in Partner Center for any product
that collects personal information, and RoRadio's random per-installation diagnostics id counts as personal data
(it singles out a device, so it is pseudonymous rather than anonymous).

This repository hosts it because it is the one public, already-served place both release lines can point at: the
apps read the station list from Pages, so a policy next to it needs no app update to correct.

What the page states, matching what the code does:

- the random installation id, app/OS/device technical data, error details, playback quality and feature-use counts
  that go to Sentry, and the legitimate-interest basis for them;
- that search text, names, e-mail, account details, machine name and location are never sent;
- that **stations a listener adds stay on the device** unless they turn on "Include my stations' details";
- that song titles reach Qwant, Google Programmable Search and the Atlas cover cache while a station plays, under
  those services' own policies and without the installation id;
- that cloud sync stores favourites, added stations and settings in Atlas keyed by a one-way hash of the Microsoft
  account id, and only after sign-in;
- the two Settings controls (`Send anonymous diagnostics`, `Include my stations' details`), which are how a listener
  objects to the processing.

The page promises nothing the apps do not ship: it describes those two settings and no other control.

## Owner actions

1. Done 2026-10-02: the contact is alexandrescu.sergiu@gmail.com, the owner's choice.
2. Paste `https://ventura8.github.io/RoRadioResources/privacy.html` into Partner Center > Properties > Privacy
   policy URL for the RoRadio product.
