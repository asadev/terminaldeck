#!/usr/bin/env bash
# Builds the macOS speech helper. Mac-only by design: this wraps Apple's
# on-device Speech framework, and the other platforms get their own ear.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(uname -s)" = "Darwin" ] || { echo "deck-speech is macOS-only; skipping."; exit 0; }
mkdir -p "$here/bin"
xcrun swiftc -O -parse-as-library \
  -target arm64-apple-macos26.0 \
  "$here/deck-speech.swift" -o "$here/bin/deck-speech"
echo "built $here/bin/deck-speech"
