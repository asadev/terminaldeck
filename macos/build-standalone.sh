#!/usr/bin/env bash
# The Node-free standalone app (night plan step 4, decision D14).
#   macos/build-standalone.sh   → macos/build/Terminal Deck.app (TD_APP_OUTPUT overrides)
# No Node runtime, engine bundle, node_modules or native addon is packaged, and
# Node is not needed to run this script. The web pages are build-time artefacts
# (a Node toolchain on the build machine only); build them first when missing:
#   npm run build && npm run build:native-web && npm run build:pwa && npm run dist:headless
# The generated Swift crypto/protocol sources are checked in; regenerate them with
# `node scripts/assemble-swift-backend.mjs` only when the iOS sources change.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
export TD_NATIVE_STANDALONE=1
export TD_VERSION="${TD_VERSION:-$(plutil -extract version raw -o - package.json)}"
for required in out/renderer/index.html out/native-web/shim.js pwa/dist/index.html out/headless-package/terminaldeck-host.tgz out/headless-package/install.sh; do
  [ -f "$required" ] || { echo "error: $required is missing; build the pages first (see the header of this script)" >&2; exit 1; }
done
exec bash "$HERE/build-app.sh"
