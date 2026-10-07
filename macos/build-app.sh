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
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  APP="${TD_APP_OUTPUT:-$OUT/Terminal Deck.app}"
else
  APP="${TD_APP_OUTPUT:-$OUT/Terminal Deck Native (Preview).app}"
fi
EXE="TerminalDeckNative"

MIN_OS="26.0"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# SwiftPM records the deployment target as the "built with SDK" version (26.0).
# Stamp the real SDK instead, so AppKit/SwiftUI give the app the newest system
# behaviour (Liquid Glass toolbar etc.) for the SDK it was actually built with.
echo "==> swift build -c release (macOS $MIN_OS+, SDK $SDK_VERSION)"
SCRATCH="${TD_SCRATCH:-$PKG/.build}"   # lanes building at once: give each its own
# Swift Build named outright: it is the default only from Swift 6.4 (Xcode 27). Swift
# 6.3 (Xcode 26, the release machine's) defaults to the old native system, which writes
# no .swiftconstvalues and no Intermediates.noindex — so intents-metadata.sh has nothing to read.
BUILD=(swift build -c release --build-system swiftbuild --package-path "$PKG" --scratch-path "$SCRATCH")
"${BUILD[@]}" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION"
BIN_DIR="$("${BUILD[@]}" --show-bin-path)"
[ -x "$BIN_DIR/$EXE" ] || { echo "error: $BIN_DIR/$EXE was not built" >&2; exit 1; }
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  [ -x "$BIN_DIR/TerminalDeckNativeHelper" ] || { echo 'error: native macOS helper was not built' >&2; exit 1; }
  [ -x "$BIN_DIR/TerminalDeckJSCorePluginHelper" ] || { echo 'error: native JavaScriptCore plugin helper was not built' >&2; exit 1; }
  [ -f "$HERE/../vendor/staysfixed-0.15.0-neutral.tgz" ] || { echo 'error: the neutral Stays Fixed product archive is missing' >&2; exit 1; }
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/../build/icon.icns" "$APP/Contents/Resources/icon.icns"
plutil -insert CFBundleIconFile -string icon "$APP/Contents/Info.plist"
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  cp "$BIN_DIR/TerminalDeckNativeHelper" "$APP/Contents/MacOS/TerminalDeckNativeHelper"
  cp "$BIN_DIR/TerminalDeckJSCorePluginHelper" "$APP/Contents/MacOS/TerminalDeckJSCorePluginHelper"
  # Product bytes only. Its pinned Node runtime is provisioned on demand by
  # BackendNodelessStaysFixedRuntime; plugins use the separate native helper.
  mkdir -p "$APP/Contents/Resources/staysfixed/package"
  cp "$HERE/../vendor/staysfixed-0.15.0-neutral.tgz" "$APP/Contents/Resources/staysfixed/package/staysfixed-0.15.0-neutral.tgz"
  chmod 644 "$APP/Contents/Resources/staysfixed/package/staysfixed-0.15.0-neutral.tgz"
  mkdir -p "$APP/Contents/Resources/native-updates"
  cp "$HERE/../scripts/native-standalone/install-update.sh" "$APP/Contents/Resources/native-updates/install-update.sh"
  chmod 755 "$APP/Contents/Resources/native-updates/install-update.sh"
  # A separate test copy (TD_BUNDLE_ID/TD_BUNDLE_NAME) never shares the shipped app's identity.
  plutil -replace CFBundleIdentifier -string "${TD_BUNDLE_ID:-dev.terminaldeck.app}" "$APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "${TD_BUNDLE_NAME:-Terminal Deck}" "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "${TD_BUNDLE_NAME:-Terminal Deck}" "$APP/Contents/Info.plist"
  if [ "${TD_TEST_COPY:-0}" = "1" ]; then plutil -insert TDAgentConfigReadOnly -bool true "$APP/Contents/Info.plist"; fi
  plutil -insert TDNativeStandalone -bool true "$APP/Contents/Info.plist"
  # D14 (night plan step 4): Node-free. No Node runtime, engine, node_modules or
  # native addons are staged. The remaining web pages are plain files served by
  # the app's own native bridge; the backend runs in process.
  plutil -insert TDNativeOnly -bool true "$APP/Contents/Info.plist"
  plutil -insert TDNativeGraph -string full "$APP/Contents/Info.plist"
  WEB_SRC="$HERE/.."
  for required in out/renderer/index.html out/native-web/shim.js pwa/dist/index.html out/headless-package/terminaldeck-host.tgz out/headless-package/install.sh; do
    [ -f "$WEB_SRC/$required" ] || { echo "error: $required is missing; build the pages first (see build-standalone.sh)" >&2; exit 1; }
  done
  mkdir -p "$APP/Contents/Resources/web"
  ditto "$WEB_SRC/out/renderer" "$APP/Contents/Resources/web/renderer"
  ditto "$WEB_SRC/out/native-web" "$APP/Contents/Resources/web/native-web"
  ditto "$WEB_SRC/pwa/dist" "$APP/Contents/Resources/web/pwa"
  # About/Settings read the public package fields (name, version, licence, links).
  /usr/bin/python3 - "$WEB_SRC/package.json" "$APP/Contents/Resources/web/package.json" <<'PY' || echo "warning: web/package.json not written; About shows no repository/licence"
import json, sys
source = json.load(open(sys.argv[1]))
json.dump({k: source[k] for k in ("name", "productName", "version", "license", "homepage", "repository") if k in source}, open(sys.argv[2], "w"), indent=2)
PY
  # Linux host package for SSH Servers: an opaque archive installed on servers, never run on this Mac.
  mkdir -p "$APP/Contents/Resources/headless"
  cp "$WEB_SRC/out/headless-package/terminaldeck-host.tgz" "$WEB_SRC/out/headless-package/install.sh" "$APP/Contents/Resources/headless/"
  # Device Hub's native SimView core, without its separately-run CLI (bin/simview).
  SIMVIEW_BIN="${TD_SIMVIEW_BIN:-$WEB_SRC/node_modules/@toolingtools/simview/bin}"
  if [ -x "$SIMVIEW_BIN/simview-core" ]; then
    mkdir -p "$APP/Contents/Resources/simview/bin" "$APP/Contents/Resources/licenses/simview"
    for item in simview-core libSimViewProbe.dylib simview-android-agent.jar xctest-provider; do
      if [ -e "$SIMVIEW_BIN/$item" ]; then ditto "$SIMVIEW_BIN/$item" "$APP/Contents/Resources/simview/bin/$item"; fi
    done
    for notice in LICENSE THIRD_PARTY_NOTICES.md; do
      if [ -f "$SIMVIEW_BIN/../$notice" ]; then cp "$SIMVIEW_BIN/../$notice" "$APP/Contents/Resources/licenses/simview/$notice"; fi
    done
  else
    echo "warning: SimView's native core not found at $SIMVIEW_BIN; Device Hub will say its engine is missing" >&2
  fi
  mkdir -p "$APP/Contents/Resources/licenses/staysfixed"
  cp "$WEB_SRC/LICENSE" "$APP/Contents/Resources/licenses/TerminalDeck.txt"
  if [ -f "$WEB_SRC/THIRD-PARTY-LICENSES.md" ]; then cp "$WEB_SRC/THIRD-PARTY-LICENSES.md" "$APP/Contents/Resources/licenses/THIRD-PARTY-LICENSES.md"; fi
  if [ -f "$SCRATCH/checkouts/SwiftTerm/LICENSE" ]; then cp "$SCRATCH/checkouts/SwiftTerm/LICENSE" "$APP/Contents/Resources/licenses/SwiftTerm.txt"; fi
  tar -xOf "$HERE/../vendor/staysfixed-0.15.0-neutral.tgz" package/LICENSE > "$APP/Contents/Resources/licenses/staysfixed/LICENSE"
fi
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
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  # Nested native executables first (D14: there is no Node runtime or addon to sign).
  # SimView's vendor binaries keep their own signatures.
  "${SIGN[@]}" --entitlements "$HERE/JSCoreHelper.entitlements" "$APP/Contents/MacOS/TerminalDeckJSCorePluginHelper"
  "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/TerminalDeckNativeHelper"
fi
for bundle in "$APP/Contents/Resources"/*.bundle; do
  [ -d "$bundle" ] && "${SIGN[@]}" "$bundle"
done
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> built for: $(otool -l "$APP/Contents/MacOS/$EXE" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos|sdk/{printf "%s %s  ", $1, $2} f&&/sdk/{exit}')"
echo "==> done: $APP"
