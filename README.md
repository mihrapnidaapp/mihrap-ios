# Mihrap for iPhone and iPad

The Mihrap web app (https://mihrap.uk) wrapped as an iOS app:

- The web files are bundled (`Mihrap/web`, copied by `sync_web.py` from the `mihrap-web` site).
- Photos and adhan recordings are downloaded once from the published web version and kept offline.
- The adhan plays in full while the app is open; the screen stays on.
- When the app is closed, a silent notification appears at each prayer time.

## Build

GitHub Actions (`.github/workflows/build.yml`) builds an unsigned `Mihrap.ipa` on macOS for every push.
Download it from the workflow run's artifacts and install with Sideloadly (it signs the app with your Apple ID).
With a free Apple ID the app must be re-signed every 7 days.

To update the web part: rebuild the web site, then run `py -X utf8 sync_web.py` and push.
