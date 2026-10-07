#!/usr/bin/env bash
#
# Build, sign and package the Node-free Terminal Deck for a Mac release.
#
#     scripts/mac-native-release.sh [--identity "<common name>"] [--keychain <path>]
#                                   [--require-developer-id] [--notarize] [--app <built .app>] [--ad-hoc]
#                                   [--pages-built]
#         → release/terminaldeck-native-<version>-arm64.zip   the updater's archive
#         → release/latest-native-mac.yml                     the in-app updater's feed
#         → release/latest-mac.yml                            Terminal Deck 0.18.x's feed, naming the zip above
#         → release/terminaldeck-<version>-arm64.dmg          the first-install download
#         → release/native-install-note.md                    a paragraph for the release notes
#
# Never publishes. The app is macos/build-standalone.sh's: Swift only, no Node
# runtime, engine, node_modules or Electron inside (TDNativeOnly). Its web pages
# and the Linux server package are built first with npm (build machine only).
# `--app` skips the build and packages an app that is already built and signed;
# `--pages-built` skips only the npm page builds (mac-release-signed.sh ran them).
# Run inside scripts/mac-release-signed.sh's signed session (it passes --keychain),
# or alone on a Mac whose keychain holds the Developer ID identity. Without that
# identity it signs ad-hoc for a local test, unless --require-developer-id;
# --ad-hoc forces that local test mode without looking at any keychain.
# Notarization: --notarize (needs ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IDENTITY="${TD_MAC_IDENTITY:-Asad Iqbal (6U4VNX5W87)}"
KEYCHAIN=""
REQUIRE_DEVID=0
NOTARIZE=0
PREBUILT=""
FORCE_ADHOC=0
PAGES_BUILT=0
NOTARIZE_TIMEOUT="${NOTARIZE_TIMEOUT:-2h}"
BUNDLE_ID="dev.terminaldeck.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="${2:?--identity needs a value}"; shift ;;
        --keychain) KEYCHAIN="${2:?--keychain needs a value}"; shift ;;
        --require-developer-id) REQUIRE_DEVID=1 ;;
        --notarize) NOTARIZE=1 ;;
        --app) PREBUILT="${2:?--app needs a path}"; shift ;;
        --ad-hoc) FORCE_ADHOC=1 ;;
        --pages-built) PAGES_BUILT=1 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
IDENTITY="${IDENTITY#Developer ID Application: }"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "build on Apple silicon: the archive is named -arm64."

VERSION="$(plutil -extract version raw -o - package.json)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "package.json version '$VERSION' is not a release version."
mkdir -p release
ZIP="release/terminaldeck-native-$VERSION-arm64.zip"
FEED="release/latest-native-mac.yml"
DMG="release/terminaldeck-$VERSION-arm64.dmg"
NOTE="release/native-install-note.md"
for out in "$ZIP" "$FEED" "$DMG" release/latest-mac.yml; do [[ ! -e "$out" ]] || die "$out already exists; remove it or use a fresh checkout."; done

# --------------------------------------------------------------- signing mode

step "Signing identity"
FULL_ID="Developer ID Application: $IDENTITY"
KC_ARGS=(); [[ -n "$KEYCHAIN" ]] && KC_ARGS=("$KEYCHAIN")
IDENTITIES=""
[[ "$FORCE_ADHOC" -eq 1 ]] || IDENTITIES="$(security find-identity -v -p codesigning ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null || true)"
[[ "$FORCE_ADHOC" -eq 1 && "$REQUIRE_DEVID" -eq 1 ]] && die "--ad-hoc and --require-developer-id contradict each other."
if grep -qF "\"$FULL_ID\"" <<<"$IDENTITIES"; then
    MODE=developer-id
    export TD_SIGN_IDENTITY="$FULL_ID"
    [[ -n "$KEYCHAIN" ]] && export TD_KEYCHAIN="$KEYCHAIN"
    printf '  %s\n' "$FULL_ID"
else
    [[ "$REQUIRE_DEVID" -eq 1 ]] && die "\"$FULL_ID\" is not in ${KEYCHAIN:-any keychain codesign can see}." \
        "A release must be Developer ID signed; refusing to fall back to ad-hoc."
    MODE=adhoc
    export TD_SIGN_IDENTITY="-"
    printf '  \033[33mno "%s" here — ad-hoc, for a local test only.\033[0m\n' "$FULL_ID"
fi
[[ "$NOTARIZE" -eq 1 && "$MODE" != developer-id ]] && die "--notarize needs a Developer ID signature."

# ------------------------------------------------- toolchain (when building)

PKG="$REPO/macos/TerminalDeckNative"
if [[ -z "$PREBUILT" ]]; then
    # What the code needs: the macOS 26 SDK (Liquid Glass toolbar APIs) and Swift
    # tools 6.2 (Package.swift). Built and tested with Xcode 27 / the macOS 27 SDK.
    NEED_SDK_MAJOR=26
    NEED_SWIFT="6.2"

    # ------------------------------------------------------------------ Xcode

    step "Xcode"
    sdk_of() { DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true; }
    major() { printf '%s' "${1%%.*}"; }

    CANDIDATES=()
    CURRENT="$(xcode-select -p 2>/dev/null || true)"
    [[ -n "${DEVELOPER_DIR:-}" ]] && CANDIDATES+=("$DEVELOPER_DIR")
    [[ -n "$CURRENT" ]] && CANDIDATES+=("$CURRENT")
    # Every Xcode in /Applications (runners keep several: Xcode_26.0.app, Xcode_27.0.app …).
    while IFS= read -r app; do CANDIDATES+=("$app/Contents/Developer"); done \
        < <(ls -d /Applications/Xcode*.app 2>/dev/null)

    BEST=""; BEST_SDK=""; SEEN=()
    for dir in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
        [[ -d "$dir" ]] || continue
        [[ "$dir" == */CommandLineTools ]] && continue # no appintentsmetadataprocessor, no Metal
        sdk="$(sdk_of "$dir")"
        [[ -n "$sdk" ]] || continue
        SEEN+=("$dir → macOS SDK $sdk")
        if [[ -z "$BEST" ]] || [[ "$(printf '%s\n%s\n' "$BEST_SDK" "$sdk" | sort -V | tail -1)" == "$sdk" && "$sdk" != "$BEST_SDK" ]]; then
            BEST="$dir"; BEST_SDK="$sdk"
        fi
    done

    if [[ -z "$BEST" || "$(major "$BEST_SDK")" -lt "$NEED_SDK_MAJOR" ]]; then
        die "no Xcode here has the macOS $NEED_SDK_MAJOR SDK or newer — Terminal Deck needs it (Liquid Glass toolbar APIs)." \
            "Found:" ${SEEN[@]+"${SEEN[@]}"} "(that is every Xcode with a macOS SDK on this machine)" \
            "" "On GitHub Actions, pick a runner image with Xcode $NEED_SDK_MAJOR or newer."
    fi
    export DEVELOPER_DIR="$BEST"
    SWIFT_VERSION="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$SWIFT_VERSION" && "$(printf '%s\n%s\n' "$NEED_SWIFT" "$SWIFT_VERSION" | sort -V | head -1)" == "$NEED_SWIFT" ]] \
        || die "Swift $SWIFT_VERSION in $BEST is older than $NEED_SWIFT (Package.swift's tools version)."
    printf '  %s\n  macOS SDK %s, Swift %s\n' "$BEST" "$BEST_SDK" "$SWIFT_VERSION"
    [[ "$(major "$BEST_SDK")" -lt 27 ]] && printf '  \033[33mnote:\033[0m built and tested with the macOS 27 SDK; this is %s.\n' "$BEST_SDK"

    # ------------------------------------------------------------ Metal toolchain

    # SwiftTerm (the native terminal) compiles a Metal shader. Since Xcode 26 the Metal
    # compiler is a separate download, and a fresh runner does not have it.
    if grep -q "SwiftTerm" "$PKG/Package.swift"; then
        step "Metal toolchain (SwiftTerm's shaders)"
        PROBE="$(mktemp -d)"
        trap 'rm -rf "$PROBE"' EXIT
        printf 'kernel void probe() {}\n' > "$PROBE/probe.metal"
        metal_ok() { xcrun -sdk macosx metal -c "$PROBE/probe.metal" -o "$PROBE/probe.air" >"$PROBE/metal.log" 2>&1; }
        if metal_ok; then
            printf '  present\n'
        else
            printf '  missing — %s\n  fetching it (xcodebuild -downloadComponent MetalToolchain, ~840 MB)\n' "$(head -1 "$PROBE/metal.log")"
            xcodebuild -downloadComponent MetalToolchain || die "could not download the Metal toolchain." "$(cat "$PROBE/metal.log")"
            metal_ok || die "the Metal toolchain is still unusable after downloading it." "$(cat "$PROBE/metal.log")"
            printf '  installed\n'
        fi
    fi

fi

# ------------------------------------------------------------------- build

if [[ -n "$PREBUILT" ]]; then
    APP="$(cd "$(dirname "$PREBUILT")" && pwd)/$(basename "$PREBUILT")"
    [[ -d "$APP" ]] || die "no app at $PREBUILT"
    step "Packaging the app already built at $APP"
else
    if [[ "$PAGES_BUILT" -eq 0 ]]; then
        step "Pages and the server package (build machine only)"
        npm run build
        npm run build:native-web
        npm run build:pwa
        npm run dist:headless
    fi
    step "Build Terminal Deck $VERSION (Swift, Node-free)"
    APP="$REPO/macos/build/Terminal Deck.app"
    TD_VERSION="$VERSION" TD_APP_OUTPUT="$APP" TD_SCRATCH="${TD_SCRATCH:-$REPO/macos/TerminalDeckNative/.build-release}" \
        bash "$REPO/macos/build-standalone.sh"
fi

# ------------------------------------------------------------------ verify

step "Verify the app"
fail=0
SIG="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
check() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32m✓\033[0m %s\n' "$1"; else printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; fi; }
INFO="$APP/Contents/Info.plist"
check "codesign --verify --deep --strict"  "codesign --verify --deep --strict '$APP'"
check "hardened runtime"                   "grep -q 'flags=.*runtime' <<<\"\$SIG\""
check "version $VERSION"                   "[ \"\$(plutil -extract CFBundleShortVersionString raw '$INFO')\" = '$VERSION' ]"
check "bundle id $BUNDLE_ID"               "[ \"\$(plutil -extract CFBundleIdentifier raw '$INFO')\" = '$BUNDLE_ID' ]"
check "declared Node-free (TDNativeOnly)"  "[ \"\$(plutil -extract TDNativeOnly raw '$INFO')\" = 'true' ]"
check "not a test copy"                    "! plutil -extract TDAgentConfigReadOnly raw '$INFO'"
check "built for arm64"                    "[[ \" \$(lipo -archs '$APP/Contents/MacOS/TerminalDeckNative') \" == *' arm64 '* ]]"
check "both helpers"                       "[ -x '$APP/Contents/MacOS/TerminalDeckNativeHelper' ] && [ -x '$APP/Contents/MacOS/TerminalDeckJSCorePluginHelper' ]"
check "no Node runtime, engine or Electron" "[ ! -e '$APP/Contents/Resources/runtime' ] && [ ! -e '$APP/Contents/Resources/engine' ] && [ ! -e '$APP/Contents/Resources/app.asar' ] && [ ! -e '$APP/Contents/Frameworks/Electron Framework.framework' ]"
check "no node binary or .node addon"      "[ -z \"\$(find '$APP' \\( -name node -o -name '*.node' -o -name node_modules \\) -print -quit)\" ]"
check "web pages inside"                   "[ -f '$APP/Contents/Resources/web/renderer/index.html' ] && [ -f '$APP/Contents/Resources/web/native-web/shim.js' ] && [ -f '$APP/Contents/Resources/web/pwa/index.html' ]"
check "server package inside"              "[ -f '$APP/Contents/Resources/headless/terminaldeck-host.tgz' ]"
check "SwiftTerm's shaders inside"         "[ -s '$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Contents/Resources/default.metallib' ]"
check "every file owner-writable (ShipIt)"  "[ -z \"\$(find '$APP' ! -perm -u+w -print -quit)\" ]"
if [[ "$MODE" == developer-id ]]; then
    check "Developer ID authority"         "grep -q 'Authority=Developer ID Application' <<<\"\$SIG\""
    check "secure timestamp"               "grep -q '^Timestamp=' <<<\"\$SIG\""
fi
[[ "$fail" -eq 0 ]] || die "the app did not verify — do not publish it."

# --------------------------------------------------------------- notarize

if [[ "$NOTARIZE" -eq 1 ]]; then
    step "Notarize and staple the app"
    : "${ASC_KEY_PATH:?--notarize needs ASC_KEY_PATH}" "${ASC_KEY_ID:?--notarize needs ASC_KEY_ID}" "${ASC_ISSUER:?--notarize needs ASC_ISSUER}"
    SUBMIT="$(mktemp -d)/submit.zip"
    ditto -c -k --keepParent "$APP" "$SUBMIT"
    xcrun notarytool submit "$SUBMIT" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
        --wait --timeout "$NOTARIZE_TIMEOUT" || die "notarization did not complete (statusCode 7000 means the account cannot notarize yet)."
    xcrun stapler staple "$APP" || die "could not staple the app."
    rm -f "$SUBMIT"
fi

# ----------------------------------------------------- update archive + feed

step "Update archive and feed"
node scripts/native-standalone/make-native-feed.mjs --app "$APP" --output-dir release \
    --version "$VERSION" --architecture arm64 --bundle-id "$BUNDLE_ID"
[[ -f "$ZIP" && -f "$FEED" ]] || die "make-native-feed.mjs did not write $ZIP and $FEED."

step "The update zip through ShipIt's steps (unpack, quarantine on/off, signature)"
SHIPIT_ARGS=("$ZIP"); [[ "$MODE" == developer-id ]] && SHIPIT_ARGS+=(--require-developer-id)
bash "$REPO/scripts/native-standalone/check-update-zip.sh" "${SHIPIT_ARGS[@]}" \
    || die "the update zip would fail Squirrel's install (0.18.x would roll back) — do not publish."

# ---------------------------------------------------------- first-install dmg

step "Disk image"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Terminal Deck.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Terminal Deck $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
if [[ "$MODE" == developer-id ]]; then
    SIGN=(codesign --force --sign "$TD_SIGN_IDENTITY" --timestamp)
    [[ -n "$KEYCHAIN" ]] && SIGN+=(--keychain "$KEYCHAIN")
    "${SIGN[@]}" "$DMG"
    if [[ "$NOTARIZE" -eq 1 ]]; then
        xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
            --wait --timeout "$NOTARIZE_TIMEOUT" || die "the disk image was not notarized."
        xcrun stapler staple "$DMG" || die "could not staple the disk image."
    fi
fi
hdiutil verify -quiet "$DMG" || die "the disk image does not verify."

# ------------------------------------------- the Electron copies' update feed

# Terminal Deck 0.18.x (Electron) checks latest-mac.yml in the newest release and
# hands the zip to Squirrel, which swaps the bundle in place once the new app's
# signature meets the old one's designated requirement: identifier
# dev.terminaldeck.app, Developer ID, team 6U4VNX5W87 — this app's, when it is
# Developer ID signed. So that feed names this app's zip: 0.18.x updates into the
# native app from its own side panel. minimumSystemVersion is a Darwin version
# (os.release()); 25 = macOS 26, below which this app cannot run.
step "Feed for Terminal Deck 0.18.x (latest-mac.yml)"
ELECTRON_FEED="release/latest-mac.yml"
[[ ! -e "$ELECTRON_FEED" ]] || die "$ELECTRON_FEED already exists."
node - "$ZIP" "$VERSION" "$ELECTRON_FEED" <<'JS'
const { createHash } = require('node:crypto')
const { readFileSync, statSync, writeFileSync } = require('node:fs')
const { basename } = require('node:path')
const [zip, version, out] = process.argv.slice(2)
const sha512 = createHash('sha512').update(readFileSync(zip)).digest('base64')
const size = statSync(zip).size
const name = basename(zip)
writeFileSync(out, [
  `version: ${version}`, 'files:', `  - url: ${name}`, `    sha512: ${sha512}`, `    size: ${size}`,
  `path: ${name}`, `sha512: ${sha512}`, `releaseDate: '${new Date().toISOString()}'`, 'minimumSystemVersion: 25.0.0', '',
].join('\n'), { flag: 'wx' })
JS
[[ -s "$ELECTRON_FEED" ]] || die "$ELECTRON_FEED was not written."
if [[ "$MODE" == developer-id ]]; then
    # Squirrel's own test: the new bundle must satisfy the installed 0.18.x app's
    # designated requirement (read from /Applications/Terminal Deck.app 0.18.8).
    DR='identifier "dev.terminaldeck.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "6U4VNX5W87"'
    codesign --verify --deep --strict -R="$DR" "$APP" || die "the app does not satisfy Terminal Deck 0.18.x's designated requirement; Squirrel would refuse it."
fi

# --------------------------------------------------------------- the note

case "$MODE-$NOTARIZE" in
    developer-id-1) OPENING="It is signed with a Developer ID certificate and notarized by Apple, so it opens on a double-click." ;;
    developer-id-0) OPENING="It is signed with a Developer ID certificate but not notarized, so macOS refuses the first launch. Open it, click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway**. Once, per install." ;;
    *)              OPENING="**This build is signed ad-hoc and is for testing only.**" ;;
esac
cat > "$NOTE" <<NOTE
macOS 26 or later, Apple silicon: open \`$(basename "$DMG")\` and drag **Terminal Deck** to Applications. $OPENING Terminal Deck is now a native Swift app with no Node.js or Electron inside; it keeps your projects, sessions and settings. Terminal Deck 0.18.8 offers this update in its side panel and installs it in place. Stays Fixed downloads its own pinned runtime the first time you use it. The app updates itself from \`$(basename "$FEED")\`.
NOTE

step "Done"
ls -lh "$ZIP" "$FEED" "$DMG" "$ELECTRON_FEED" | awk '{print "  " $9 "  " $5}'
printf '  %s\n' "$NOTE"
printf '  %s\n' "$([[ "$MODE" == developer-id ]] && echo "Developer ID signed$([[ "$NOTARIZE" -eq 1 ]] && echo ", notarized")" || echo "AD-HOC signed (local test only)")"
