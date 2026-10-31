# Native app release helpers

The Mac app is Node-free: `macos/build-standalone.sh` builds the Swift app and
stages only prebuilt web assets (`out/renderer`, `out/native-web`, `pwa/dist`)
and the Linux server package (`out/headless-package`). Nothing here stages a
Node runtime or a JavaScript engine into the bundle.

- `make-native-feed.mjs` turns a signed app into the update ZIP and its feed
  (`latest-native-mac.yml`). It writes local files only and never publishes.
- `install-update.sh` is copied into the app (`Contents/Resources/native-updates`).
  The updater runs it from private staging: it waits for the app to quit
  normally, checks the archive's size, hash, version, bundle id and signing
  team, swaps the bundle and relaunches it.
