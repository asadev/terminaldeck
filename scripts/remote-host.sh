#!/usr/bin/env bash
#
# Run the desktop's remote endpoint, and a relay, as a plain Node process — so
# the phone client can be pointed at the *real* desktop code without Electron.
# See scripts/remote-host.ts for what is real and what is not.
#
# Node cannot run those modules directly: they use extensionless relative
# imports, which ESM does not resolve. esbuild is already a dependency of the
# desktop app, so nothing new is installed.
#
#   scripts/remote-host.sh [--relay-port 8787] [--approve-after 4000] [--fresh]

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$repo/.harness/.remote-host"
esbuild="$repo/node_modules/.bin/esbuild"

[[ -x "$esbuild" ]] || {
    echo "esbuild not found at $esbuild — run npm install in $repo" >&2
    exit 1
}

mkdir -p "$out"
# The bundle lives under .harness/, so it cannot find the repository from its
# own path. Passed in rather than guessed.
export TD_REPO_DIR="$repo"

# node-pty is a native module: it cannot be bundled, so the bundle keeps a real
# require of it. Sessions here are real PTYs — see remote-host.ts.
"$esbuild" "$here/remote-host.ts" \
    --bundle --platform=node --format=esm --target=node22 \
    --external:node-pty \
    --log-level=warning \
    --outfile="$out/remote-host.mjs"

exec node "$out/remote-host.mjs" "$@"
