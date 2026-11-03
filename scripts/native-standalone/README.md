# Native app release helpers

The Mac app is Node-free: `macos/build-standalone.sh` builds the Swift app and
stages only prebuilt web assets (`out/renderer`, `out/native-web`, `pwa/dist`)
and the Linux server package (`out/headless-package`). Nothing here stages a
Node runtime or a JavaScript engine into the bundle.

- `make-native-feed.mjs` turns a signed app into the update ZIP and its feed
  (`latest-native-mac.yml`). It writes local files only and never publishes.
- `install-update.sh` is copied into the app (`Contents/Resources/native-updates`).
  The updater runs it from private staging: it waits for the app to quit
  normally (never a signal, up to five minutes), checks the archive's size,
  SHA-512 and SHA-256, the version, bundle id, the Developer ID of team
  6U4VNX5W87 and (when asked) Apple's notarization, swaps the bundle and
  relaunches it from a clean environment. Sessions the session keeper holds
  keep running; the new app adopts that keeper and stages its own next to it.

From 0.21.0 the app reads `release-manifest.json` of the newest GitHub release
and its Ed25519 signature `release-manifest.json.sig` (key: the release
machine's; public half in `NativeReleaseManifest.publicKeys`). A manifest the
key did not sign is refused before anything downloads. `latest-native-mac.yml`
is still published for 0.20.x apps.
