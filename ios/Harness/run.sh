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
    *)
        echo "usage: run.sh {vectors|host} [args…]" >&2
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
