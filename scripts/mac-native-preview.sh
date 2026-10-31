#!/usr/bin/env bash
#
# Build, sign and zip "Terminal Deck Native (Preview)" — the native macOS window
# that runs on top of an installed Terminal Deck — for a release:
#
#     scripts/mac-native-preview.sh
#         → release/terminaldeck-native-preview-<version>-arm64.zip
#         → a paragraph for release/mac-install-note.md (also release/native-preview-note.md)
#
# Signing: Developer ID when the identity is in a keychain codesign can see, else
# ad-hoc with a loud notice (this Mac has no Developer ID). A release passes
# --require-developer-id so it can never quietly ship ad-hoc. Called by
# scripts/mac-release-signed.sh inside its signed session (TD_NATIVE_PREVIEW=0 skips it).
#
#   --identity "<common name>"   default: $TD_MAC_IDENTITY or "Asad Iqbal (6U4VNX5W87)"
#   --keychain <path>            the keychain holding it (mac-release-signed.sh's)
#   --require-developer-id       fail instead of falling back to ad-hoc
#   --notarize                   also notarize + staple (needs ASC_KEY_PATH, ASC_KEY_ID,
#                                ASC_ISSUER; NOTARIZE_TIMEOUT, default 2h). Off while the
#                                account cannot notarize (statusCode 7000).
#
# CI-proof: picks an Xcode whose macOS SDK is new enough (newest first), fetches
# the Metal toolchain if SwiftTerm needs it and it is missing, and stops with the
# reason when the runner cannot build this.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IDENTITY="${TD_MAC_IDENTITY:-Asad Iqbal (6U4VNX5W87)}"
KEYCHAIN=""
REQUIRE_DEVID=0
NOTARIZE=0
NOTARIZE_TIMEOUT="${NOTARIZE_TIMEOUT:-2h}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="${2:?--identity needs a value}"; shift ;;
        --keychain) KEYCHAIN="${2:?--keychain needs a value}"; shift ;;
        --require-developer-id) REQUIRE_DEVID=1 ;;
        --notarize) NOTARIZE=1 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
IDENTITY="${IDENTITY#Developer ID Application: }" # accept it with or without the prefix

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "build on Apple silicon: the zip is named -arm64 and the app is built for this machine's architecture."

PKG="$REPO/macos/TerminalDeckNative"
VERSION="$(node -p "require('$REPO/package.json').version")"
APP_NAME="$(plutil -extract CFBundleName raw "$REPO/macos/Info.plist")"
APP="$REPO/macos/build/$APP_NAME.app"
ZIP="$REPO/release/terminaldeck-native-preview-$VERSION-arm64.zip"
# The one place the minimum lives is the app's own source; read it, never retype it.
MIN_TD="$(grep -oE 'minimumVersion = AppVersion\("[^"]+"\)' "$PKG/Sources/TerminalDeckNativeCore/EngineConfiguration.swift" | grep -oE '[0-9][0-9.]*[0-9]')"
[[ -n "$MIN_TD" ]] || die "could not read the minimum Terminal Deck version from EngineConfiguration.swift"

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
    die "no Xcode here has the macOS $NEED_SDK_MAJOR SDK or newer — Terminal Deck Native needs it (Liquid Glass toolbar APIs)." \
        "Found:" ${SEEN[@]+"${SEEN[@]}"} "(that is every Xcode with a macOS SDK on this machine)" \
        "" "On GitHub Actions, pick a runner image with Xcode $NEED_SDK_MAJOR or newer, or skip the preview: TD_NATIVE_PREVIEW=0."
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

# --------------------------------------------------------------- signing mode

step "Signing identity"
if [[ -n "${TD_SIGNING_KEYCHAIN:-}${TD_SIGNING_SHA1:-}" ]]; then
    source "$REPO/scripts/mac-signing-scope.sh"
    td_mac_signing_scope || die "Scoped local Developer ID selection failed"
    KEYCHAIN="$TD_KEYCHAIN"
    MODE=developer-id
    printf '  %s (%s)\n' "$TD_MAC_SIGNING_NAME" "$TD_MAC_SIGNING_SHA1"
elif [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]; then
step "Signing identity"
FULL_ID="Developer ID Application: $IDENTITY"
KC_ARGS=(); [[ -n "$KEYCHAIN" ]] && KC_ARGS=("$KEYCHAIN")
# (The `+` form: bash 3.2, macOS's own, calls an empty array unbound under `set -u`.)
IDENTITIES="$(security find-identity -v -p codesigning ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null || true)"
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
    printf '  \033[33mno "%s" on this Mac — signing AD-HOC.\033[0m\n' "$FULL_ID"
    printf '  Fine for testing here; NOT for strangers (macOS calls an ad-hoc download "damaged").\n'
fi
else
    [[ "$REQUIRE_DEVID" == 0 && "$NOTARIZE" == 0 ]] ||
        die "Local Mac signing requires explicit TD_SIGNING_KEYCHAIN and TD_SIGNING_SHA1"
    MODE=adhoc
    export TD_SIGN_IDENTITY="-"
fi
[[ "$NOTARIZE" -eq 1 && "$MODE" != developer-id ]] && die "--notarize needs a Developer ID signature."

# ------------------------------------------------------------------- build

step "Build $APP_NAME $VERSION (release)"
export TD_VERSION="$VERSION"
export TD_SCRATCH="${TD_SCRATCH:-$PKG/.build-release}"
"$REPO/macos/build-app.sh"
[[ -d "$APP" ]] || die "no app at $APP"

# ------------------------------------------------------------------ verify

step "Verify the app"
fail=0
# codesign's report, read once. Never `codesign … | grep -q` under pipefail: grep -q
# quits at its match, codesign (writing line by line) dies of SIGPIPE, and the
# check fails — or, negated, passes — by timing alone.
SIG="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
check() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32m✓\033[0m %s\n' "$1"; else printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; fi; }
check "codesign --verify --deep --strict"   "codesign --verify --deep --strict '$APP'"
check "hardened runtime"                    "grep -q 'flags=.*runtime' <<<\"\$SIG\""
check "microphone entitlement (and only that)" \
      "[ \"\$(codesign -d --entitlements - --xml '$APP' 2>/dev/null | plutil -convert json -o - - 2>/dev/null)\" = '{\"com.apple.security.device.audio-input\":true}' ]"
check "built for arm64"                     "[[ \" \$(lipo -archs '$APP/Contents/MacOS/TerminalDeckNative') \" == *' arm64 '* ]]"
check "version $VERSION in Info.plist"      "[ \"\$(plutil -extract CFBundleShortVersionString raw '$APP/Contents/Info.plist')\" = '$VERSION' ]"
check "bundle id unchanged"                 "[ \"\$(plutil -extract CFBundleIdentifier raw '$APP/Contents/Info.plist')\" = 'dev.terminaldeck.native-proof' ]"
if grep -q "SwiftTerm" "$PKG/Package.swift"; then
    check "SwiftTerm's resources inside (else the terminal crashes)" "[ -s '$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Contents/Resources/default.metallib' ]"
fi
if [[ "$MODE" == developer-id ]]; then
    check "Developer ID authority"          "grep -q 'Authority=Developer ID Application' <<<\"\$SIG\""
    check "secure timestamp"                "grep -q '^Timestamp=' <<<\"\$SIG\""
    check "not ad-hoc"                      "! grep -q 'Signature=adhoc' <<<\"\$SIG\""
fi
[[ "$fail" -eq 0 ]] || die "the app did not verify — do not publish it."

# ----------------------------------------------------------- notarize (opt-in)

zip_app() { mkdir -p "$REPO/release"; rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"; }

if [[ "$NOTARIZE" -eq 1 ]]; then
    step "Notarize"
    : "${ASC_KEY_PATH:?--notarize needs ASC_KEY_PATH}" "${ASC_KEY_ID:?--notarize needs ASC_KEY_ID}" "${ASC_ISSUER:?--notarize needs ASC_ISSUER}"
    zip_app
    xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
        --wait --timeout "$NOTARIZE_TIMEOUT" || die "notarization did not complete (see scripts/mac-release-signed.sh on statusCode 7000)."
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP" || die "stapling failed."
fi

# --------------------------------------------------------------------- zip

step "Zip"
zip_app
UNZIPPED="$(mktemp -d)"
ditto -x -k "$ZIP" "$UNZIPPED"
codesign --verify --deep --strict "$UNZIPPED/$APP_NAME.app" \
    || die "the app inside $ZIP does not verify — the archive damaged the signature."
rm -rf "$UNZIPPED"
printf '  %s  %s\n' "$(basename "$ZIP")" "$(du -h "$ZIP" | cut -f1)"

# -------------------------------------------------------------- install note

step "Install note"
case "$MODE-$NOTARIZE" in
    developer-id-1) OPENING="It is signed with a Developer ID certificate and notarized by Apple, so it opens on a double-click." ;;
    developer-id-0) OPENING="Like Terminal Deck, it is signed with a Developer ID certificate but not notarized, so macOS refuses the first launch. Open it, click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway**. Once, per install." ;;
    *)              OPENING="**This copy is not signed** (it was built on a machine without the Developer ID certificate), so macOS will say it is damaged. Clear the quarantine flag: \`xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\"\`." ;;
esac
NOTE="$REPO/release/native-preview-note.md"
cat > "$NOTE" <<NOTE

**$APP_NAME** — \`$(basename "$ZIP")\` — is an early native macOS version of the Terminal Deck window: a real Mac sidebar, toolbar and tabs around Terminal Deck's own screens. It is a preview and runs on top of the regular app, so **Terminal Deck $MIN_TD or newer must be installed** in Applications. Unzip it and drag **$APP_NAME** to Applications. $OPENING
NOTE
# Appended for local runs. The release workflow rewrites mac-install-note.md after
# this script runs, so it must add release/native-preview-note.md itself.
grep -qF "$(basename "$ZIP")" "$REPO/release/mac-install-note.md" 2>/dev/null \
    || cat "$NOTE" >> "$REPO/release/mac-install-note.md"   # once, however often this runs
printf '  release/native-preview-note.md (and appended to release/mac-install-note.md)\n'

printf '\n\033[32m%s %s\033[0m — %s\n' "$APP_NAME" "$VERSION" \
    "$([[ "$MODE" == developer-id ]] && echo "Developer ID signed$([[ "$NOTARIZE" -eq 1 ]] && echo ", notarized")" || echo "AD-HOC signed (local test only)")"
printf '  %s\n' "$ZIP"
