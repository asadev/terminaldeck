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
#   TD_BUILD_VERSION  optional CFBundleVersion only (e.g. 0.20.2-local)
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
SESSION_HOST_EXE="TerminalDeckSessionHostHelper"

MIN_OS="26.0"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# SwiftPM records the deployment target as the "built with SDK" version (26.0).
# Stamp the real SDK instead, so AppKit/SwiftUI give the app the newest system
# behaviour (Liquid Glass toolbar etc.) for the SDK it was actually built with.
echo "==> swift build -c release (macOS $MIN_OS+, SDK $SDK_VERSION)"
SCRATCH="${TD_SCRATCH:-$PKG/.build}"   # lanes building at once: give each its own
# Isolated copies keep the existing TD_BUNDLE_ID interface. Metadata must be selected
# before linking, not patched into a signed or running helper afterwards.
if [ "${TD_NATIVE_STANDALONE:-0}" = 1 ] && [ "${TD_BUNDLE_ID:-dev.terminaldeck.app}" != dev.terminaldeck.app ] && [ -z "${TD_SESSION_HOST_INFO_PLIST:-}" ]; then
  PRIVACY_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/td-privacy-metadata.XXXXXX")"
  trap 'rm -rf "$PRIVACY_SCRATCH"' EXIT
  export TD_SESSION_HOST_INFO_PLIST="$PRIVACY_SCRATCH/SessionHost-Info.plist"
  python3 "$HERE/../scripts/mac-privacy-metadata.py" --prepare "$PKG/Support/SessionHost-Info.plist" "$TD_SESSION_HOST_INFO_PLIST" "$TD_BUNDLE_ID" "${TD_BUNDLE_NAME:-Terminal Deck}"
fi
# Swift Build named outright: it is the default only from Swift 6.4 (Xcode 27). Swift
# 6.3 (Xcode 26, the release machine's) defaults to the old native system, which writes
# no .swiftconstvalues and no Intermediates.noindex — so intents-metadata.sh has nothing to read.
# This machine's architecture only (the release is arm64-only): Swift 6.3's Swift Build
# otherwise builds x86_64 as well, doubling a release build the runner could not finish in 75 min.
BUILD=(swift build -c release --build-system swiftbuild --arch "$(uname -m)" --package-path "$PKG" --scratch-path "$SCRATCH")
if [ -n "${TD_BUILD_BIN_DIR:-}" ]; then
  BIN_DIR="$TD_BUILD_BIN_DIR"
else
  "${BUILD[@]}" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION"
  BIN_DIR="$("${BUILD[@]}" --show-bin-path)"
fi
[ -x "$BIN_DIR/$EXE" ] || { echo "error: $BIN_DIR/$EXE was not built" >&2; exit 1; }
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  [ -x "$BIN_DIR/TerminalDeckNativeHelper" ] || { echo 'error: native macOS helper was not built' >&2; exit 1; }
  [ -x "$BIN_DIR/TerminalDeckJSCorePluginHelper" ] || { echo 'error: native JavaScriptCore plugin helper was not built' >&2; exit 1; }
  [ -f "$BIN_DIR/$SESSION_HOST_EXE" ] && [ ! -L "$BIN_DIR/$SESSION_HOST_EXE" ] && [ -x "$BIN_DIR/$SESSION_HOST_EXE" ] || {
    echo 'error: native session-host helper was not built as a regular executable' >&2; exit 1;
  }
  # Inspect build bytes without running the helper or starting a host. SwiftPM
  # builds this machine's one architecture, so require a thin 64-bit executable.
  /usr/bin/python3 - "$BIN_DIR/$SESSION_HOST_EXE" <<'PY'
import os, stat, struct, sys
path = sys.argv[1]
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    info = os.fstat(descriptor)
    header = os.read(descriptor, 32)
finally:
    os.close(descriptor)
order = {b'\xcf\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xcf': '>'}.get(header[:4])
if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111 or len(header) != 32 or order is None or struct.unpack_from(order + 'I', header, 12)[0] != 2:
    raise SystemExit('error: session-host helper must be a 64-bit Mach-O executable')
PY
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
  cp "$BIN_DIR/$SESSION_HOST_EXE" "$APP/Contents/MacOS/$SESSION_HOST_EXE"
  cmp -s "$BIN_DIR/$SESSION_HOST_EXE" "$APP/Contents/MacOS/$SESSION_HOST_EXE" || {
    echo 'error: staged session-host helper differs from the built executable' >&2; exit 1;
  }
  chmod 755 "$APP/Contents/MacOS/$SESSION_HOST_EXE"
  plutil -insert TDHostIntegrated -bool true "$APP/Contents/Info.plist"
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
  # Old installed helpers require these paths. They contain no Node/engine code.
  mkdir -p "$APP/Contents/Resources/runtime/bin" "$APP/Contents/Resources/engine"
  cat > "$APP/Contents/Resources/runtime/bin/node" <<'TD_NODE_PLACEHOLDER'
#!/bin/sh
printf '%s\n' 'Terminal Deck no longer uses Node; this placeholder only lets older updaters accept this version'
exit 1
TD_NODE_PLACEHOLDER
  chmod 755 "$APP/Contents/Resources/runtime/bin/node"
  printf '%s\n' '{"removed":true,"reason":"native app; placeholder for older updaters"}' > "$APP/Contents/Resources/runtime/manifest.json"
  printf '%s\n' '{"removed":true,"reason":"native app; placeholder for older updaters"}' > "$APP/Contents/Resources/engine/manifest.json"
  plutil -insert TDNativeOnly -bool true "$APP/Contents/Info.plist"
  plutil -insert TDNativeGraph -string full "$APP/Contents/Info.plist"
  WEB_SRC="$HERE/.."
  for required in out/renderer/index.html out/native-web/shim.js out/headless-package/terminaldeck-host.tgz out/headless-package/install.sh; do
    [ -f "$WEB_SRC/$required" ] || { echo "error: $required is missing; build the pages first (see build-standalone.sh)" >&2; exit 1; }
  done
  mkdir -p "$APP/Contents/Resources/web"
  ditto "$WEB_SRC/out/renderer" "$APP/Contents/Resources/web/renderer"
  ditto "$WEB_SRC/out/native-web" "$APP/Contents/Resources/web/native-web"
  # The private web app is delivered as a bundle; public builds retain their existing fallback.
  # Web v1 (2 Nov): the app serves the td-web client, never the retired pwa/dist. Default to its build; fail loudly.
  # A public (open-source) build has no private td-web; only it may keep the old pwa, and only when it says so.
  if [ "${TD_WEB_FALLBACK_PWA:-0}" = 1 ] && [ -z "${TD_WEB_BUNDLE:-}" ]; then
    [ -f "$WEB_SRC/pwa/dist/index.html" ] || { echo "error: TD_WEB_FALLBACK_PWA=1 but pwa/dist is not built" >&2; exit 1; }
    rm -rf "$APP/Contents/Resources/web/pwa"; ditto "$WEB_SRC/pwa/dist" "$APP/Contents/Resources/web/pwa"
  else
    WEB_CLIENT_BUNDLE="${TD_WEB_BUNDLE:-$HOME/Deck Dev/code/td-web/dist}"
    [ -f "$WEB_CLIENT_BUNDLE/index.html" ] && [ -f "$WEB_CLIENT_BUNDLE/build.json" ] || { echo "error: no built web client at $WEB_CLIENT_BUNDLE (build td-web, or set TD_WEB_BUNDLE)" >&2; exit 1; }
    /usr/bin/grep -q '"client": *"terminaldeck-web"' "$WEB_CLIENT_BUNDLE/build.json" || { echo "error: $WEB_CLIENT_BUNDLE is not the td-web client (build.json)" >&2; exit 1; }
    rm -rf "$APP/Contents/Resources/web/pwa"; ditto "$WEB_CLIENT_BUNDLE" "$APP/Contents/Resources/web/pwa"
    /usr/bin/grep -q '"client": *"terminaldeck-web"' "$APP/Contents/Resources/web/pwa/build.json" || { echo "error: the app's web/pwa is not the td-web client after copying" >&2; exit 1; }
    echo "web client: $(/usr/bin/tr -d '\n' < "$APP/Contents/Resources/web/pwa/build.json" | /usr/bin/cut -c1-160)"
  fi
  # About/Settings read the public package fields (name, version, licence, links).
  /usr/bin/python3 - "$WEB_SRC/package.json" "$APP/Contents/Resources/web/package.json" <<'PY' || echo "warning: web/package.json not written; About shows no repository/licence"
import json, sys
source = json.load(open(sys.argv[1]))
json.dump({k: source[k] for k in ("name", "productName", "version", "license", "homepage", "repository") if k in source}, open(sys.argv[2], "w"), indent=2)
PY
  # Linux host package for SSH Servers: an opaque archive installed on servers, never run on this Mac.
  mkdir -p "$APP/Contents/Resources/headless"
  cp "$WEB_SRC/out/headless-package/terminaldeck-host.tgz" "$WEB_SRC/out/headless-package/install.sh" "$APP/Contents/Resources/headless/"
  # Devices need nothing bundled: Terminal Deck's own engine drives iOS Simulators with Apple's tools and the app's
  # helper, and Android devices with Google's adb (28 Oct 2026; the third-party device engine was removed).
  mkdir -p "$APP/Contents/Resources/licenses/staysfixed"
  cp "$WEB_SRC/LICENSE" "$APP/Contents/Resources/licenses/TerminalDeck.txt"
  if [ -f "$WEB_SRC/THIRD-PARTY-LICENSES.md" ]; then cp "$WEB_SRC/THIRD-PARTY-LICENSES.md" "$APP/Contents/Resources/licenses/THIRD-PARTY-LICENSES.md"; fi
  if [ -f "$SCRATCH/checkouts/SwiftTerm/LICENSE" ]; then cp "$SCRATCH/checkouts/SwiftTerm/LICENSE" "$APP/Contents/Resources/licenses/SwiftTerm.txt"; fi
  tar -xOf "$HERE/../vendor/staysfixed-0.15.0-neutral.tgz" package/LICENSE > "$APP/Contents/Resources/licenses/staysfixed/LICENSE"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
# stream-anywhere (2 Nov): Google's WebRTC (LiveKit's prebuilt XCFramework, pinned by checksum in Package.swift) is a
# dynamic framework the app links: it goes into Contents/Frameworks, the app finds it there, and its licence (BSD-3-Clause
# + the WebRTC patent grant) goes with the other notices. Signed below, before the app.
# Mandatory (review-install-25 M1): the app always links it (target TerminalDeckPeer), so an app without it dies in dyld at
# launch. A build that cannot find it stops here, loudly, instead of shipping that app.
WEBRTC_FRAMEWORK="$BIN_DIR/LiveKitWebRTC.framework"
if [ ! -d "$WEBRTC_FRAMEWORK" ]; then
  echo "error: LiveKitWebRTC.framework is not in $BIN_DIR; the app links it and would not launch without it (resolve the package, check SwiftPM's bin path)" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/licenses"
ditto "$WEBRTC_FRAMEWORK" "$APP/Contents/Frameworks/LiveKitWebRTC.framework"
[ -f "$APP/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" ] || { echo "error: the copied LiveKitWebRTC.framework has no binary" >&2; exit 1; }
otool -l "$APP/Contents/MacOS/$EXE" | grep -q '@executable_path/../Frameworks' || install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$EXE"
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  otool -l "$APP/Contents/MacOS/$SESSION_HOST_EXE" | grep -q '@executable_path/../Frameworks' || install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$SESSION_HOST_EXE"
fi
WEBRTC_LICENSE=$(find "$SCRATCH/artifacts" -path '*LiveKitWebRTC.xcframework/LICENSE' -print -quit 2>/dev/null)
[ -n "$WEBRTC_LICENSE" ] || { echo "error: the WebRTC licence (LiveKitWebRTC.xcframework/LICENSE) is missing from $SCRATCH/artifacts" >&2; exit 1; }
cp "$WEBRTC_LICENSE" "$APP/Contents/Resources/licenses/WebRTC.txt"
cp "$HERE/licenses/webrtc/PATENTS" "$APP/Contents/Resources/licenses/WebRTC-PATENTS.txt"
mkdir -p "$APP/Contents/Resources/licenses/server-control"
cp "$HERE/licenses/server-control/Coolify-LICENSE.txt" "$APP/Contents/Resources/licenses/server-control/Coolify.txt"
cp "$HERE/licenses/server-control/THIRD-PARTY.md" "$APP/Contents/Resources/licenses/server-control/THIRD-PARTY.md"
# Deck Memory's search by meaning: the bundled gte-small model (MIT, NOTICE.md beside it), sealed by the app's
# signature below like every other resource. Without it the app falls back to Apple's weaker model, so a release
# without it stops here; TD_ALLOW_NO_MEMORY_MODEL=1 builds one anyway (the app's log then says which model it uses).
MEMORY_MODEL="$HERE/models/deck-memory-embedding"
if [ -d "$MEMORY_MODEL/gte-small.mlmodelc" ] && [ -f "$MEMORY_MODEL/vocab.txt" ] && [ -f "$MEMORY_MODEL/NOTICE.md" ]; then
  ditto "$MEMORY_MODEL" "$APP/Contents/Resources/deck-memory-embedding"
  mkdir -p "$APP/Contents/Resources/licenses/deck-memory-embedding"
  cp "$MEMORY_MODEL/NOTICE.md" "$APP/Contents/Resources/licenses/deck-memory-embedding/NOTICE.md"
  echo "    + Resources/deck-memory-embedding ($(du -sh "$MEMORY_MODEL" | cut -f1), gte-small, MIT)"
elif [ "${TD_ALLOW_NO_MEMORY_MODEL:-0}" != "1" ]; then
  echo "error: the memory search model is missing ($MEMORY_MODEL); set TD_ALLOW_NO_MEMORY_MODEL=1 to build without it" >&2
  exit 1
fi
# Terminal Deck's starter skills (recover, save-session, deep-research, options-gallery, overnight-run,
# review-recording): every project sees them as "Terminal Deck · built in". Sealed by the signature below.
BUILT_IN_SKILLS="$HERE/built-in-skills"
if [ -d "$BUILT_IN_SKILLS" ]; then
  rm -rf "$APP/Contents/Resources/built-in-skills"
  ditto "$BUILT_IN_SKILLS" "$APP/Contents/Resources/built-in-skills"
  find "$APP/Contents/Resources/built-in-skills" -type f -exec chmod 644 {} + -o -type d -exec chmod 755 {} +
  echo "    + Resources/built-in-skills ($(ls "$BUILT_IN_SKILLS" | wc -l | tr -d ' ') skills)"
fi
if [ -n "${TD_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$TD_VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${TD_BUILD_VERSION:-$TD_VERSION}" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Packages' resource bundles (SwiftTerm's Metal shaders). Their generated lookup
# reads Contents/Resources and calls fatalError when the bundle is missing, so an
# app without them crashes the moment a native terminal draws.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] || continue
  rm -rf "$bundle/Contents/_CodeSignature" # signed again below, inside the app
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
  if [ "${TD_APPLY_COMPILE_ONLY:-0}" = 1 ] && [ ! -f "$bundle/Contents/Info.plist" ]; then
    # Native SwiftPM resource folders need macOS bundle metadata for signing.
    staged="$APP/Contents/Resources/$(basename "$bundle")"
    mkdir -p "$staged/Contents/Resources"
    for resource in "$staged"/*; do
      [ "$(basename "$resource")" = Contents ] || mv "$resource" "$staged/Contents/Resources/"
    done
    cat > "$staged/Contents/Info.plist" <<'TD_RESOURCE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.terminaldeck.resources.SwiftTerm</string>
<key>CFBundleName</key><string>SwiftTerm</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
TD_RESOURCE_PLIST
  fi
  echo "    + Resources/$(basename "$bundle")"
done

# The optional boot helper is bundled, never registered by packaging. Its capture/input process is the same keeper
# executable and retains the stable .session-host privacy requirement below.
if [ "${TD_NATIVE_STANDALONE:-0}" = "1" ]; then
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp "$PKG/Support/MacReach/dev.terminaldeck.app.mac-reach.plist" "$APP/Contents/Library/LaunchDaemons/"
  # One app to macOS (9 Nov): the session keepers are Terminal Deck's own background items (SMAppService). launchd starts
  # the app's own program, which hands over to the copied-out keeper, so Login Items and privacy name only Terminal Deck.
  # Only the installed release app registers them; a test copy's items name its own bundle and are never registered.
  source "$HERE/../scripts/mac-keeper-items.sh"
  td_install_keeper_items "$PKG/Support/SessionHostAgents" "$APP" "${TD_BUNDLE_ID:-dev.terminaldeck.app}"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" = "$EXE" ] || { echo 'error: the keeper items start Contents/MacOS/TerminalDeckNative; the app program name changed' >&2; exit 1; }
fi

# Siri / Shortcuts (lane R): App Intents metadata, which swift build never makes. Before signing.
echo "==> App Intents metadata (Siri, Shortcuts, Spotlight)"
"$HERE/intents-metadata.sh" "$SCRATCH" "$APP" "$MIN_OS"

# WidgetKit extension is a real nested app extension; build it before the outer app is sealed.
if [ "${TD_WITH_WIDGETS:-1}" = "1" ]; then
  "$HERE/Widgets/build-extension.sh" "$APP"
fi

# Warm SwiftPM products name their shared PackageFrameworks folder even for helpers
# that link no package framework. Normalize every copied executable before signing:
# the keeper's new stable requirement must be sealed around its final portable bytes.
/usr/bin/python3 - "$APP" <<'TD_PORTABLE_LOAD_PATHS'
from pathlib import Path
import re, subprocess, sys
app = Path(sys.argv[1]).resolve()
for executable in (app / 'Contents/MacOS').iterdir():
    if not executable.is_file() or executable.is_symlink():
        continue
    relative = str(executable.relative_to(app))
    loads = subprocess.check_output(['otool', '-l', relative], cwd=app, text=True)
    for rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', loads):
        if rpath.startswith('/'):
            subprocess.run(['install_name_tool', '-delete_rpath', rpath, str(executable)], check=True)
    loads = subprocess.check_output(['otool', '-l', relative], cwd=app, text=True)
    linked = subprocess.check_output(['otool', '-L', relative], cwd=app, text=True)
    if '/Users/' in loads + linked:
        raise SystemExit(f'error: copied executable retains a build-machine load path: {relative}')
    names = re.findall(r'\n\s*(?:name|path) (.*?) \(offset', loads)
    if any(name.startswith('/') and not name.startswith(('/System/', '/usr/lib/')) for name in names):
        raise SystemExit(f'error: copied executable retains a non-system absolute load path: {relative}')
TD_PORTABLE_LOAD_PATHS

# Every file owner-writable before signing. Copies from SwiftPM checkouts (SwiftTerm's
# LICENSE) arrive read-only (0444); a read-only file in the bundle makes Squirrel's
# ShipIt fail the in-place update ("Couldn't remove quarantine attribute", 0.19.0).
chmod -R u+w "$APP"
IDENTITY="${TD_SIGN_IDENTITY:--}"
ENTITLEMENTS="$HERE/NativePreview.entitlements"
if [ -n "${TD_SIGNING_KEYCHAIN:-}${TD_SIGNING_SHA1:-}" ]; then
  source "$HERE/../scripts/mac-signing-scope.sh"
  td_mac_signing_scope || exit 1
  IDENTITY="$TD_SIGN_IDENTITY"
elif [ "$IDENTITY" != "-" ]; then
  if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
    echo 'Local Mac signing requires explicit TD_SIGNING_KEYCHAIN and TD_SIGNING_SHA1' >&2
    exit 1
  fi
fi
source "$HERE/../scripts/mac-privacy-signing.sh"
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
  # Nested native executables first (D14: there is no Node runtime or addon to sign). Every executable in the
  # bundle is ours and signed here with the hardened runtime.
  "${SIGN[@]}" --entitlements "$HERE/JSCoreHelper.entitlements" "$APP/Contents/MacOS/TerminalDeckJSCorePluginHelper"
  "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/TerminalDeckNativeHelper"
  # Pin the keeper to the containing app's identity namespace, never its filename or version.
  PRIVACY_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  # A scratch bundle must compile with TD_SESSION_HOST_INFO_PLIST naming its own identity.
  python3 "$HERE/../scripts/mac-privacy-metadata.py" "$APP/Contents/MacOS/$SESSION_HOST_EXE" "$PRIVACY_APP_ID.session-host"
  td_sign_privacy_helper "$APP/Contents/MacOS/$SESSION_HOST_EXE" "$PRIVACY_APP_ID.session-host" "$ENTITLEMENTS"
  if [ "${TD_APPLY_COMPILE_ONLY:-0}" != "1" ]; then codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/$SESSION_HOST_EXE"; fi
fi
for bundle in "$APP/Contents/Resources"/*.bundle; do
  [ -d "$bundle" ] && "${SIGN[@]}" "$bundle"
done
for framework in "$APP/Contents/Frameworks"/*.framework; do
  [ -d "$framework" ] && "${SIGN[@]}" "$framework"
done
if [ "${TD_WITH_WIDGETS:-1}" = "1" ]; then
  WIDGET_DERIVED="${TD_WIDGET_DERIVED_DATA:-$HERE/Widgets/.build}"
  "${SIGN[@]}" --entitlements "$WIDGET_DERIVED/widget.entitlements" "$APP/Contents/PlugIns/DeckWidgets.appex"
  ENTITLEMENTS="$WIDGET_DERIVED/app.entitlements"
fi
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
if [ "${TD_APPLY_COMPILE_ONLY:-0}" != "1" ]; then codesign --verify --deep --strict --verbose=2 "$APP"; fi

echo "==> built for: $(otool -l "$APP/Contents/MacOS/$EXE" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos|sdk/{printf "%s %s  ", $1, $2} f&&/sdk/{exit}')"
echo "==> done: $APP"
