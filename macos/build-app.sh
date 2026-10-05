#!/usr/bin/env bash
# Builds "Terminal Deck Native (Preview).app" and signs it.
#   macos/build-app.sh            → macos/build/Terminal Deck Native (Preview).app, ad-hoc signed
# (Bundle id dev.terminaldeck.native-proof and the data folder are unchanged, so an
# earlier "Terminal Deck Native.app" is the same app: replace it, don't keep both.)
#
# Optional, for a release (scripts/mac-native-preview.sh sets these):
#   TD_SIGN_IDENTITY  "Developer ID Application: …"  (default "-": ad-hoc)
#   TD_KEYCHAIN       the keychain holding that identity
#   TD_VERSION        stamped into Info.plist (default: the plist's own)
#   TD_SCRATCH        SwiftPM scratch folder (lanes building at once: one each)
# Either way the app is signed with the hardened runtime and
# macos/NativePreview.entitlements, so a local build behaves like the release.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/TerminalDeckNative"
OUT="$HERE/build"
APP="$OUT/Terminal Deck Native (Preview).app"
EXE="TerminalDeckNative"

MIN_OS="26.0"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# SwiftPM records the deployment target as the "built with SDK" version (26.0).
# Stamp the real SDK instead, so AppKit/SwiftUI give the app the newest system
# behaviour (Liquid Glass toolbar etc.) for the SDK it was actually built with.
echo "==> swift build -c release (macOS $MIN_OS+, SDK $SDK_VERSION)"
SCRATCH="${TD_SCRATCH:-$PKG/.build}"   # lanes building at once: give each its own
swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" \
  -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION"
BIN_DIR="$(swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" --show-bin-path)"
[ -x "$BIN_DIR/$EXE" ] || { echo "error: $BIN_DIR/$EXE was not built" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -n "${TD_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$TD_VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$TD_VERSION" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Packages' resource bundles (SwiftTerm's Metal shaders). Their generated lookup
# reads Contents/Resources and calls fatalError when the bundle is missing, so an
# app without them crashes the moment a native terminal draws.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] || continue
  rm -rf "$bundle/Contents/_CodeSignature" # signed again below, inside the app
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
  echo "    + Resources/$(basename "$bundle")"
done

# Siri / Shortcuts (lane R): App Intents metadata, which swift build never makes. Before signing.
echo "==> App Intents metadata (Siri, Shortcuts, Spotlight)"
"$HERE/intents-metadata.sh" "$SCRATCH" "$APP" "$MIN_OS"

IDENTITY="${TD_SIGN_IDENTITY:--}"
ENTITLEMENTS="$HERE/NativePreview.entitlements"
SIGN=(codesign --force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" = "-" ]; then
  echo "==> signing ad-hoc (no Developer ID), hardened runtime"
  SIGN+=(--timestamp=none)
else
  echo "==> signing as $IDENTITY, hardened runtime"
  SIGN+=(--timestamp)
  [ -n "${TD_KEYCHAIN:-}" ] && SIGN+=(--keychain "$TD_KEYCHAIN")
fi
# Inside out: nested bundles first, then the app with its entitlements. Never
# `codesign --deep` to sign — it signs in the wrong order and skips entitlements.
for bundle in "$APP/Contents/Resources"/*.bundle; do
  [ -d "$bundle" ] && "${SIGN[@]}" "$bundle"
done
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> built for: $(otool -l "$APP/Contents/MacOS/$EXE" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos|sdk/{printf "%s %s  ", $1, $2} f&&/sdk/{exit}')"
echo "==> done: $APP"
