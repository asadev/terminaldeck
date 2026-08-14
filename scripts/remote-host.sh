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
relay_port="8787"
for ((i = 1; i <= $#; i++)); do
    next=$((i + 1))
    [[ $next -le $# ]] || continue
    case "${!i}" in
        --name) name="${!next}" ;;
        --relay-port) relay_port="${!next}" ;;
    esac
done

out="$repo/.harness/.remote-host${name:+-$name}"
esbuild="$repo/node_modules/.bin/esbuild"

[[ -x "$esbuild" ]] || {
    echo "esbuild not found at $esbuild — run npm install in $repo" >&2
    exit 1
}

# Refuse a port that is taken, BEFORE writing the bundle.
#
# Node would refuse it too, four lines further down — but by then the damage is
# done, because the bundle is written before it is run and a second default-named
# run writes over the .mjs a *live* host is running from. The live process is
# unaffected (it has already loaded it), so nothing looks wrong until that host
# is restarted hours later and silently comes up as someone else's build. That
# happened. Checking here costs one `lsof` and makes a collision loud.
#
# The control port rather than the relay port: `--relay-url` means a second host
# need not own a relay at all, but every host opens `relay_port + 1` for control.
control_port=$((relay_port + 1))
if lsof -nP -iTCP:"$control_port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "control port $control_port is already in use — another host is running." >&2
    echo "Use a different --relay-port, and --name to give it a state directory of its own:" >&2
    echo "    scripts/remote-host.sh --name b --relay-port $((relay_port + 10))" >&2
    exit 1
fi

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
