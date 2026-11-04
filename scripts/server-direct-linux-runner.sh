#!/bin/sh
set -eu

# The native test talks to a disposable Linux peer over stdio; the data itself uses WebRTC.
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
socket=${SERVER_DIRECT_28_DOCKER_SOCKET:?Set the scratch Docker socket}
case "$1" in "$root"/*) relative=${1#"$root"/} ;; *) exit 2 ;; esac

# Inherit the native test's held CPU slot; keep fixture output away from the JSON pipe.
"${SERVER_DIRECT_28_BUILD_SLOT:-$HOME/Deck Dev/tools/build-slot.sh}" npm --prefix "$root" run build:server-direct-probe >&2

exec docker --host "$socket" run --rm -i --cpus=1 --memory=256m \
  --read-only --tmpfs /tmp:size=32m --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$root,dst=/work,readonly" --workdir /work node:22-bookworm-slim \
  sh -ec 'if command -v cc >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1; then exit 2; fi; exec node "$1"' \
  sh "/work/$relative"
