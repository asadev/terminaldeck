#!/usr/bin/env bash
#
# The Node half of the iOS workstream: the crypto fixtures the Swift tests read,
# and a desktop-plus-relay to point the Simulator at.
#
# Both are TypeScript that imports the *real* modules — `src/shared/sealed.ts`
# and `relay/src/rendezvous.ts` — rather than a second copy of them, which is
# the only way the fixtures and the live test mean anything. Node cannot run
# those files directly (they use extensionless relative imports, which ESM does
# not resolve), so esbuild bundles each entry point into one .mjs first.
# esbuild is already a dependency of the desktop app; nothing new is installed.
#
#   ios/Harness/run.sh vectors     regenerate Tests/Fixtures/sealed-vectors.json
#   ios/Harness/run.sh host        run a relay + a stand-in desktop on it
#   ios/Harness/run.sh live        drive a REAL host over the LIVE relay
#
# `host` and `live` are not two flavours of the same thing and the difference is
# the point. `host` is a stand-in: a second implementation of the desktop, good
# enough to tap against and capable of sharing a bug with its client — which is
# exactly how Electron's missing ChaCha stayed hidden while 3,628 Node tests
# passed. `live` stands nothing in. It talks to the product's own headless host
# on `relay.terminaldeck.dev`, down that host's real control socket. See
# `live-desktop.ts`, and `live-transfer.sh` for the whole proof it is half of.
#
# Everything after the subcommand is passed through to the script.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$here/.build"
esbuild="$repo/node_modules/.bin/esbuild"

[[ -x "$esbuild" ]] || {
    echo "esbuild not found at $esbuild — run npm install in $repo" >&2
    exit 1
}

command="${1:-}"
shift || true

case "$command" in
    vectors) entry=sealed-vectors ;;
    host)    entry=host-standin ;;
    live)    entry=live-desktop ;;
    *)
        echo "usage: run.sh {vectors|host|live} [args…]" >&2
        exit 2
        ;;
esac

mkdir -p "$out"
# Bundled code cannot find the repository from its own path — the bundle lives
# in .build/ — so the two anchors it needs are passed in.
export TD_IOS_DIR="$(cd "$here/.." && pwd)"
export TD_REPO_DIR="$repo"

# node-pty is a native module: it cannot be bundled, and the stand-in reaches
# for it through createRequire so the bundle keeps a real require of it.
"$esbuild" "$here/$entry.ts" \
    --bundle --platform=node --format=esm --target=node22 \
    --external:node-pty \
    --log-level=warning \
    --outfile="$out/$entry.mjs"

exec node "$out/$entry.mjs" "$@"
