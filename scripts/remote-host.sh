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
#                          [--name b]
#
# Two hosts, for proving a phone holds both at once:
#
#   scripts/remote-host.sh                        --relay-port 8787 &
#   scripts/remote-host.sh --name b --relay-port 8797 &
#
# `--name` is read by remote-host.ts, which uses it to pick a state directory —
# without it the two share one host identity and are not two machines. It is
# also read here, because the bundle is written before it is run and two
# concurrent builds writing one .mjs is a torn file, not a duplicate.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

name=""
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == "--name" ]]; then
        next=$((i + 1))
        [[ $next -le $# ]] && name="${!next}"
    fi
done

out="$repo/.harness/.remote-host${name:+-$name}"
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
