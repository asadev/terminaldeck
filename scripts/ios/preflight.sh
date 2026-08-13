#!/usr/bin/env bash
#
# Everything about the iOS release that can be checked without talking to Apple.
#
#   scripts/ios/preflight.sh          full run, archives twice, ~2 minutes
#   scripts/ios/preflight.sh --fast   skips the archives, ~5 seconds
#
# ## What this is for
#
# A TestFlight upload fails in three places: on this machine, at export, and
# twenty minutes later in an email from App Store Connect. The third is the
# expensive one, and most of what causes it — a stale icon, an alpha channel, a
# build number already used, a certificate that expired last Tuesday, a bundle
# id that does not match the App ID — is knowable here, for free, before
# anything is built.
#
# So this checks all of it, and it checks the *outputs* rather than the inputs
# wherever it can: it does not read project.yml and believe it, it archives the
# app and reads the Info.plist that came out.
#
# ## The one thing it cannot do
#
# It cannot sign for distribution, because that needs a provisioning profile for
# dev.terminaldeck.ios, and creating one needs an App Store Connect issuer id
# that nobody has yet. That check therefore reports `blocked`, not `fail`, and
# the run still exits 0 — see the note on the three outcomes in common.sh. The
# distribution-signing attempt is still *made* on every run, so the day the
# issuer id arrives, this script is what tells you it worked.
#
# ## One warning: this is not read-only once the issuer id exists
#
# With $ASC_ISSUER_ID set, the distribution-signing check passes the key to
# xcodebuild along with -allowProvisioningUpdates, and xcodebuild will then
# register the App ID and create the provisioning profile in the developer
# account, because that is what signing for distribution means the first time
# anyone does it. It is idempotent from the second run on. Nothing here ever
# touches App Store Connect itself: no app record, no build, no upload.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

FAST=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST=1 ;;
        -h|--help) sed -n '2,42p' "$0" | sed 's/^#//'; exit 0 ;;
        *) die "unknown argument: $arg" "usage: preflight.sh [--fast]" ;;
    esac
done

require_macos

# ----------------------------------------------------------------- toolchain

heading "Toolchain"

if have xcodebuild; then
    pass "xcodebuild — $(xcodebuild -version | head -1)"
    detail "$(xcode-select -p)"
else
    fail "xcodebuild is not on PATH" "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
fi

if have xcodegen; then
    pass "xcodegen — $(xcodegen --version 2>&1 | tail -1)"
else
    fail "xcodegen is not installed" \
         "The .xcodeproj is generated from ios/project.yml and is not committed." \
         "  brew install xcodegen"
fi

if have node; then
    pass "node — $(node --version)"
else
    fail "node is not installed" "Needed to read the version out of package.json and to render the icon."
fi

# Xcode 26 ships without the Metal compiler, and SwiftTerm's package declares a
# Shaders.metal resource for its optional Metal renderer — so the build stops at
# `cannot execute tool 'metal'` on a machine that has never downloaded it. It is
# a ~690MB one-time asset, unrelated to whether this app draws anything in Metal.
metal_status="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null | sed -n 's/.*"status" : "\([a-z]*\)".*/\1/p')"
if [[ "$metal_status" == "installed" ]]; then
    pass "Metal toolchain — installed"
else
    fail "Metal toolchain is not installed (status: ${metal_status:-unknown})" \
         "SwiftTerm declares a .metal resource, so every build needs the compiler." \
         "  xcodebuild -downloadComponent MetalToolchain"
fi

# ---------------------------------------------------------------- signing

heading "Signing material"

identity="$(security find-identity -v -p codesigning 2>/dev/null |
            sed -n "s/.*\"\(Apple Distribution: .*($TEAM_ID)\)\".*/\1/p" | head -1)"

if [[ -n "$identity" ]]; then
    pass "distribution certificate — $identity"

    cert_pem="$(security find-certificate -c "$identity" -p 2>/dev/null || true)"
    if [[ -z "$cert_pem" ]]; then
        fail "certificate is in the identity list but its PEM could not be read"
    elif ! printf '%s' "$cert_pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
        fail "the distribution certificate has EXPIRED" \
             "$(printf '%s' "$cert_pem" | openssl x509 -noout -enddate)" \
             "Revoke and reissue at https://developer.apple.com/account/resources/certificates"
    else
        expiry="$(printf '%s' "$cert_pem" | openssl x509 -noout -enddate | cut -d= -f2)"
        # 30 days. Long enough to notice, short enough not to cry wolf.
        if printf '%s' "$cert_pem" | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
            pass "certificate is valid — expires $expiry"
        else
            fail "the distribution certificate expires within 30 days ($expiry)" \
                 "Reissue before it lapses; a build cannot be signed after it does."
        fi
    fi
else
    fail "no 'Apple Distribution: … ($TEAM_ID)' identity in the keychain" \
         "Certificates > Apple Distribution at https://developer.apple.com/account/resources/certificates" \
         "Download the .cer and open it, so the private key in the login keychain finds its certificate."
fi

key_path="$(asc_key_path)"
if [[ -f "$key_path" ]]; then
    pass "App Store Connect key — $(asc_key_id)"
    detail "$key_path"
    mode="$(stat -f '%OLp' "$key_path")"
    if [[ "$mode" != "600" && "$mode" != "400" ]]; then
        fail "the private key is mode $mode" \
             "It is a credential that can upload builds and mint profiles." \
             "  chmod 600 $key_path"
    fi
    # altool finds the key by *filename*, not by path, so a mismatch between the
    # key id and the name of the file is a failure at upload time and nowhere else.
    expected="AuthKey_$(asc_key_id).p8"
    if [[ "$(basename "$key_path")" != "$expected" ]]; then
        fail "the key file is not named $expected" \
             "altool locates keys by filename; anything else is invisible to it."
    fi
else
    fail "no App Store Connect private key at $key_path" \
         "Set ASC_KEY_PATH, or put AuthKey_$(asc_key_id).p8 in ~/private_keys/." \
         "The key is downloadable exactly once, at creation; if it is lost, make a new one."
fi

issuer="$(asc_issuer_id)"
if [[ -z "$issuer" ]]; then
    blocked "App Store Connect issuer id — not set" \
        "Everything else here can be checked without it; nothing can be uploaded with it missing." \
        "Read it off App Store Connect > Users and Access > Integrations >" \
        "App Store Connect API — the UUID above the table of keys — then:" \
        "  export ASC_ISSUER_ID=<uuid>   (or write it to $(dirname "$key_path")/issuer_id.txt)"
elif [[ ! "$issuer" =~ $ISSUER_UUID_RE ]]; then
    fail "the issuer id that is set is not a UUID: $issuer" \
         "A ten-character value is the Key ID, which is a different identifier."
else
    pass "App Store Connect issuer id — set (${issuer:0:8}…)"
fi

# ------------------------------------------------------------------- project

heading "Project"

if have xcodegen; then
    if (cd "$IOS_DIR" && xcodegen generate >/dev/null 2>&1); then
        pass "xcodegen generate — $SCHEME.xcodeproj written from project.yml"
    else
        fail "xcodegen generate failed" "Run it in ios/ to see why."
    fi
fi

if [[ -d "$XCODEPROJ" ]]; then
    settings="$(cd "$IOS_DIR" && xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
        -configuration Release -showBuildSettings 2>/dev/null || true)"

    setting() { printf '%s' "$settings" | sed -n "s/^ *$1 = \(.*\)$/\1/p" | head -1; }

    expect() {
        local key="$1" want="$2" got
        got="$(setting "$key")"
        if [[ "$got" == "$want" ]]; then
            pass "$key = $got"
        else
            fail "$key = ${got:-<unset>}, expected $want" "Fix it in ios/project.yml, not in Xcode."
        fi
    }

    expect PRODUCT_BUNDLE_IDENTIFIER "$BUNDLE_ID"
    expect DEVELOPMENT_TEAM "$TEAM_ID"
    expect ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    # 1 = iPhone. Deliberate, and hard to undo once shipped — see project.yml.
    expect TARGETED_DEVICE_FAMILY "1"

    project_version="$(setting MARKETING_VERSION)"
    pkg_version="$(package_version)"
    if [[ "$project_version" == "$pkg_version" ]]; then
        pass "MARKETING_VERSION = $project_version, matching package.json"
    else
        fail "MARKETING_VERSION is $project_version but package.json says $pkg_version" \
             "One product, one version number. release.sh stamps package.json's, so the" \
             "archive would not match what this project file claims."
    fi
else
    fail "no $XCODEPROJ" "Run: cd ios && xcodegen generate"
fi

# The build number is computed, not stored, so the only thing to check is that
# whatever it computes to is something App Store Connect will accept.
build="$(build_number)"
if [[ ! "$build" =~ ^[0-9]+$ ]]; then
    fail "build number '$build' is not a plain integer" \
         "App Store Connect compares build numbers numerically, component by component."
elif (( build > 4294967295 )); then
    fail "build number $build overflows the unsigned 32-bit field it is stored in" \
         "The yymmddHHMM scheme in common.sh runs out in 2042; set TD_IOS_BUILD explicitly."
else
    pass "build number — $build (yymmddHHMM, UTC)"
fi

# ---------------------------------------------------------------------- icon

heading "App icon"

if [[ ! -f "$ICON_PNG" ]]; then
    fail "no app icon at $ICON_PNG" "  node scripts/ios/icon.mjs"
else
    dims="$(sips -g pixelWidth -g pixelHeight "$ICON_PNG" 2>/dev/null |
            awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w"x"h}')"
    if [[ "$dims" == "1024x1024" ]]; then
        pass "icon-1024.png — $dims"
    else
        fail "the app icon is $dims, not 1024x1024" \
             "That size is the App Store marketing icon and the source actool derives the rest from."
    fi

    # ITMS-90717. An icon that carries an alpha channel is rejected even when
    # every pixel in it is opaque, which is why scripts/ios/icon.mjs writes
    # colour type 2 instead of reusing the shared RGBA encoder.
    if [[ "$(sips -g hasAlpha "$ICON_PNG" 2>/dev/null | awk '/hasAlpha/ {print $2}')" == "no" ]]; then
        pass "icon has no alpha channel"
    else
        fail "the app icon has an alpha channel" \
             "App Store Connect rejects it (ITMS-90717) after the upload, not before." \
             "  node scripts/ios/icon.mjs"
    fi

    # The icon is generated from build/art/icon.mjs and committed. Both facts
    # are load-bearing: committed so a checkout builds, generated so it cannot
    # drift from the desktop icon. This is the check that they still agree.
    if have node; then
        before="$(mktemp)"; cp "$ICON_PNG" "$before"
        if node "$SCRIPT_DIR/icon.mjs" >/dev/null 2>&1; then
            if cmp -s "$before" "$ICON_PNG"; then
                pass "icon is a current render of build/art/icon.mjs"
            else
                fail "the committed icon is stale — re-rendering it produced different bytes" \
                     "It has just been rewritten in place. Look at it, then commit it."
            fi
        else
            fail "node scripts/ios/icon.mjs failed" "Run it directly to see why."
        fi
        rm -f "$before"
    fi
fi

# --------------------------------------------------------------- Info.plist

heading "Info.plist"

plist="$IOS_DIR/Support/Info.plist"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

# Export compliance. This check is inverted from the obvious one on purpose, and
# the inversion is the whole lesson: the key must be ABSENT.
#
# `ITSAppUsesNonExemptEncryption` does not mean "does this app encrypt". It
# means "does this app use encryption that is NOT exempt". The sealed channel is
# standard primitives (X25519, ChaCha20-Poly1305, HKDF-SHA256 via CryptoKit),
# which are exempt, so the honest answer is not `true` — and `true` makes altool
# demand an `ITSEncryptionExportComplianceCode` that does not exist, failing the
# upload with 90592 after the bytes have already gone up.
#
# The questionnaire is answered per-build in App Store Connect instead, where
# the real three-step form lives, and `release.sh` sets the build's
# `usesNonExemptEncryption` over the API to match. An absent key is what lets
# that answer stand. See ios/README.md, "Export compliance".
enc="$(plist_get ITSAppUsesNonExemptEncryption)"
if [[ -z "$enc" ]]; then
    pass "ITSAppUsesNonExemptEncryption absent (answered in App Store Connect)"
else
    fail "ITSAppUsesNonExemptEncryption is present, set to '$enc'" \
         "It must not be in Support/Info.plist at all. 'true' fails the upload with" \
         "90592 asking for a compliance code that was never issued; 'false' contradicts" \
         "the questionnaire already answered in App Store Connect. Delete the key."
fi

[[ "$(plist_get LSRequiresIPhoneOS)" == "true" ]] &&
    pass "LSRequiresIPhoneOS = true" ||
    fail "LSRequiresIPhoneOS is not true" "Xcode writes it into generated plists; this target supplies its own."

[[ -n "$(/usr/libexec/PlistBuddy -c "Print :UILaunchScreen" "$plist" 2>&1 | head -1)" ]] &&
    pass "UILaunchScreen present" ||
    fail "UILaunchScreen is missing" "Without it the app runs letterboxed and the terminal is sized against the wrong screen."

[[ "$(plist_get CFBundleDisplayName)" == "$APP_NAME" ]] &&
    pass "CFBundleDisplayName = $APP_NAME" ||
    fail "CFBundleDisplayName is '$(plist_get CFBundleDisplayName)', expected '$APP_NAME'"

[[ "$(plist_get CFBundleIconName)" == "AppIcon" ]] &&
    pass "CFBundleIconName = AppIcon" ||
    fail "CFBundleIconName is missing from Support/Info.plist" \
         "actool's copy of it is nested; the validator reads the top level (ITMS-90713)."

if [[ "$FAST" == "1" ]]; then
    heading "Archive"
    printf '  %s—%s skipped (--fast)\n' "$C_DIM" "$C_RESET"
else

# ------------------------------------------------------------------- archive

heading "Archive (unsigned)"

# Signing off, because this stage is not about signing: it is about whether the
# Release configuration compiles for a real arm64 device, whether actool
# produces an icon, and whether the Info.plist that comes out the far end says
# what the project file promised. Those are separable from whether Apple has
# issued us a profile, and keeping them separable is what lets this script pass
# today.
mkdir -p "$RELEASE_DIR"
unsigned_log="$RELEASE_DIR/preflight-unsigned.log"
if (cd "$IOS_DIR" && xcodebuild archive \
        -project "$XCODEPROJ" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$RELEASE_DIR/Preflight.xcarchive" \
        -derivedDataPath "$DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
        CODE_SIGNING_ALLOWED=NO >"$unsigned_log" 2>&1); then
    pass "Release archive built for generic/platform=iOS"

    app="$RELEASE_DIR/Preflight.xcarchive/Products/Applications/$SCHEME.app"
    built() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist" 2>/dev/null || true; }

    [[ "$(built CFBundleIdentifier)" == "$BUNDLE_ID" ]] &&
        pass "built bundle id — $(built CFBundleIdentifier)" ||
        fail "the built app's bundle id is $(built CFBundleIdentifier), expected $BUNDLE_ID"

    [[ "$(built CFBundleShortVersionString)" == "$(marketing_version)" ]] &&
        pass "built version — $(built CFBundleShortVersionString)" ||
        fail "the built app says version $(built CFBundleShortVersionString), expected $(marketing_version)"

    # Two different keys with the same value, and they prove two different
    # things. The top-level one is what the App Store validator reads, and a
    # bundle without it is rejected as ITMS-90713 after the upload; it comes
    # from Support/Info.plist, so it would still be there if the asset catalogue
    # were empty. The nested one is written by actool and is therefore the
    # evidence that an icon was actually compiled. Both, or neither means much.
    [[ "$(built CFBundleIconName)" == "AppIcon" ]] &&
        pass "CFBundleIconName = AppIcon (top level, the one the validator reads)" ||
        fail "the built app has no top-level CFBundleIconName" \
             "Rejected on upload as ITMS-90713. It is declared in ios/Support/Info.plist."

    icon_files="$(find "$app" -maxdepth 1 -name 'AppIcon*.png' | wc -l | tr -d ' ')"
    if [[ "$(built CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName)" == "AppIcon" && "$icon_files" -gt 0 ]]; then
        pass "actool compiled the icon — $icon_files rendered file(s) plus Assets.car"
    else
        fail "actool did not compile an app icon into the bundle" \
             "Check ASSETCATALOG_COMPILER_APPICON_NAME and TerminalDeck/Assets.xcassets/AppIcon.appiconset."
    fi

    families="$(/usr/libexec/PlistBuddy -c "Print :UIDeviceFamily" "$app/Info.plist" 2>/dev/null | tr -d ' \n')"
    [[ "$families" == "Array{1}" ]] &&
        pass "UIDeviceFamily = [1] — iPhone only" ||
        fail "UIDeviceFamily is $families, expected just [1]" \
             "A device family cannot be dropped after a build ships with it."

    arch="$(lipo -info "$app/$SCHEME" 2>/dev/null | sed 's/.*: //')"
    [[ "$arch" == "arm64" ]] &&
        pass "binary architecture — $arch" ||
        fail "the binary is '$arch', expected arm64"
else
    fail "the Release archive did not build" "Log: $unsigned_log" "$(grep -m3 'error:' "$unsigned_log" || true)"
fi

# --------------------------------------------------- archive (distribution)

heading "Archive (distribution signing)"

signed_log="$RELEASE_DIR/preflight-signed.log"
signed_args=(-project "$XCODEPROJ" -scheme "$SCHEME" -configuration Release
             -destination 'generic/platform=iOS'
             -archivePath "$RELEASE_DIR/PreflightSigned.xcarchive"
             -derivedDataPath "$DERIVED_DATA"
             -clonedSourcePackagesDirPath "$SOURCE_PACKAGES")

# With an issuer id, xcodebuild is allowed to talk to Apple and create whatever
# App ID, profile and certificate the signature needs. Without one it is offline
# and can only use what is already on the machine, which for this bundle id is
# nothing. Both paths are attempted; only the reason for failing differs.
if [[ -n "$issuer" && "$issuer" =~ $ISSUER_UUID_RE && -f "$key_path" ]]; then
    signed_args+=(-allowProvisioningUpdates
                  -authenticationKeyPath "$key_path"
                  -authenticationKeyID "$(asc_key_id)"
                  -authenticationKeyIssuerID "$issuer")
fi

if (cd "$IOS_DIR" && xcodebuild archive "${signed_args[@]}" >"$signed_log" 2>&1); then
    pass "archive signed with the distribution identity"
    codesign -dv --verbose=2 "$RELEASE_DIR/PreflightSigned.xcarchive/Products/Applications/$SCHEME.app" 2>&1 |
        sed -n 's/^Authority=/      authority: /p' | head -1
else
    reason="$(grep -m2 -oE "No profiles for '[^']*' were found|No Accounts: Add a new account" "$signed_log" | head -1 || true)"
    if [[ -n "$reason" ]]; then
        blocked "cannot sign for distribution — no provisioning profile for $BUNDLE_ID" \
            "xcodebuild: $reason" \
            "There is no profile for this bundle id on this Mac, and there is no App ID" \
            "for it in the developer account either. Creating both is one command," \
            "and that command needs the issuer id:" \
            "  xcodebuild … -allowProvisioningUpdates -authenticationKeyPath $key_path \\" \
            "               -authenticationKeyID $(asc_key_id) -authenticationKeyIssuerID \$ASC_ISSUER_ID" \
            "which is exactly what scripts/ios/release.sh runs. Nothing else is missing:" \
            "the certificate, the key and the archive itself are all in place." \
            "Log: $signed_log"
    else
        fail "distribution signing failed for a reason that is not the missing profile" \
             "$(grep -m3 'error:' "$signed_log" || echo 'no error: line in the log')" \
             "Log: $signed_log"
    fi
fi

fi  # FAST

# -------------------------------------------------------------------- report

heading "Summary"

if (( FAILURES == 0 )); then
    printf '  %s%d checks failed%s\n' "$C_GREEN" "$FAILURES" "$C_RESET"
else
    printf '  %s%d check(s) failed%s\n' "$C_RED" "$FAILURES" "$C_RESET"
fi

if (( BLOCKERS > 0 )); then
    printf '  %s%d blocked, waiting on someone with an App Store Connect login:%s\n' \
        "$C_YELLOW" "$BLOCKERS" "$C_RESET"
    for note in "${BLOCKER_NOTES[@]}"; do printf '      · %s\n' "$note"; done
    printf '\n  See "Runbook" in ios/README.md.\n'
fi

printf '\n'
(( FAILURES == 0 ))
