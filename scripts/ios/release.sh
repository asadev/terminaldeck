#!/usr/bin/env bash
#
# One command from a clean checkout to a build sitting in TestFlight.
#
#   export ASC_ISSUER_ID=<uuid from App Store Connect>
#   scripts/ios/release.sh
#
#   --no-upload      archive, export and validate, then stop with an .ipa on disk
#   --no-validate    skip the validation call (it is cheap; you probably want it)
#   --skip-preflight don't re-run the cheap checks first
#
# ## The four steps, and why they are four
#
#   1. archive   compile and sign the app for a real device
#   2. export    re-sign it for distribution and wrap it as an .ipa
#   3. validate  ask App Store Connect whether it would accept this .ipa
#   4. upload    send it
#
# Xcode can be told to do 1–4 in one gesture, and every CI system in the world
# has a wrapper that does. They are separate here because each one fails
# differently and only the first two leave anything behind to look at. A build
# that dies during upload after a combined command has produced nothing you can
# re-send; a build that dies at step 4 here has an .ipa on disk that step 3 has
# already blessed, and re-running is a five-second retry rather than a rebuild.
#
# ## Credentials
#
# Everything comes from the environment. Nothing secret is written down here,
# no issuer id is hardcoded, and the private key is passed by path to the two
# Apple tools that need it and read by nothing else.
#
#   ASC_ISSUER_ID              required. The UUID. See the error if it is unset.
#   ASC_ISSUER_ID_FILE         alternative: a file containing that UUID.
#   ASC_KEY_ID                 default 999LNRXQS2
#   ASC_KEY_PATH               default ~/private_keys/AuthKey_$ASC_KEY_ID.p8
#   TD_IOS_MARKETING_VERSION   default: the version in package.json
#   TD_IOS_BUILD               default: yymmddHHMM, UTC, at the moment of the run
#   TD_IOS_SIGN_STYLE          automatic (default) | manual
#   TD_IOS_PROFILE             profile name; required when signing manually

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

UPLOAD=1
VALIDATE=1
RUN_PREFLIGHT=1
for arg in "$@"; do
    case "$arg" in
        --no-upload)      UPLOAD=0 ;;
        --no-validate)    VALIDATE=0 ;;
        --skip-preflight) RUN_PREFLIGHT=0 ;;
        -h|--help)        sed -n '2,42p' "$0" | sed 's/^#//'; exit 0 ;;
        *) die "unknown argument: $arg" "usage: release.sh [--no-upload] [--no-validate] [--skip-preflight]" ;;
    esac
done

require_macos

# The single most likely way either altool call fails, and the one with the
# least helpful message: the app record has to exist in App Store Connect
# before a build can be attached to it, and no API key and no amount of
# retrying creates it. Defined once because validation hits it too.
explain_altool_failure() {
    local log="$1"
    grep -qi "no suitable application record\|app record\|cannot be found" "$log" || return 0
    cat >&2 <<EOF

There is no app record for $BUNDLE_ID in App Store Connect yet.
A build cannot be uploaded to an app that does not exist. Create it:

  https://appstoreconnect.apple.com/apps  >  +  >  New App
    Platform   iOS
    Name       $APP_NAME
    Bundle ID  $BUNDLE_ID   (appears in the list once an archive has registered it)
    SKU        terminaldeck-ios   (private to you; any stable string)

Then re-run this script.
EOF
}

# ------------------------------------------------------------- credentials

# First, before anything is compiled. A release that discovers at minute
# twenty that it has no issuer id has wasted twenty minutes and a build number.
ISSUER="$(require_issuer_id)"
KEY_ID="$(asc_key_id)"
KEY_PATH="$(asc_key_path)"

[[ -f "$KEY_PATH" ]] || die \
    "no App Store Connect private key at $KEY_PATH" \
    "Set ASC_KEY_PATH, or put AuthKey_$KEY_ID.p8 in ~/private_keys/."

# altool does not take a path to the key: it looks for AuthKey_<id>.p8 in a
# fixed set of directories, one of which is whatever $API_PRIVATE_KEYS_DIR
# points at. Exporting it is how an arbitrary ASC_KEY_PATH is honoured without
# copying a private key somewhere it was not put deliberately.
export API_PRIVATE_KEYS_DIR="$(dirname "$KEY_PATH")"

SIGN_STYLE="${TD_IOS_SIGN_STYLE:-automatic}"
case "$SIGN_STYLE" in
    automatic) ;;
    manual)
        [[ -n "${TD_IOS_PROFILE:-}" ]] || die \
            "TD_IOS_SIGN_STYLE=manual needs TD_IOS_PROFILE set to a provisioning profile name" \
            "Manual signing uses a profile that already exists in the developer account;" \
            "automatic signing creates one. Unless you have a reason, use automatic."
        ;;
    *) die "TD_IOS_SIGN_STYLE must be 'automatic' or 'manual', not '$SIGN_STYLE'" ;;
esac

# ------------------------------------------------------------------ preflight

if (( RUN_PREFLIGHT )); then
    heading "Preflight"
    # --fast: the archive checks are skipped because this script is about to
    # archive for real, and building the same app twice to find the same answer
    # is four minutes spent to learn nothing.
    "$SCRIPT_DIR/preflight.sh" --fast || die "preflight failed; nothing was built."
fi

# ------------------------------------------------------------------ versions

MARKETING="$(marketing_version)"
BUILD="$(build_number)"

heading "Building $APP_NAME $MARKETING ($BUILD)"
detail "bundle    $BUNDLE_ID"
detail "team      $TEAM_ID"
detail "signing   $SIGN_STYLE"
detail "key       $KEY_ID, issuer ${ISSUER:0:8}…"

# ------------------------------------------------------------------- archive

mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$RELEASE_DIR/export"
IPA="$EXPORT_DIR/$SCHEME.ipa"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

heading "1/4  Archive"

(cd "$IOS_DIR" && xcodegen generate >/dev/null) ||
    die "xcodegen generate failed"

archive_args=(
    -project "$XCODEPROJ"
    -scheme "$SCHEME"
    -configuration Release
    # Not a simulator and not a specific phone: the one archive that can be
    # thinned by the App Store for every device that will ever run it.
    -destination 'generic/platform=iOS'
    -archivePath "$ARCHIVE"
    -derivedDataPath "$DERIVED_DATA"
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
    # Lets xcodebuild register the App ID and create or renew the provisioning
    # profile against the developer account instead of failing because neither
    # exists yet. This is the flag the issuer id is for.
    -allowProvisioningUpdates
    -authenticationKeyPath "$KEY_PATH"
    -authenticationKeyID "$KEY_ID"
    -authenticationKeyIssuerID "$ISSUER"
    # The version and build number are stamped from here rather than committed
    # into project.yml, so that a release does not begin with a commit whose
    # only content is a number.
    "MARKETING_VERSION=$MARKETING"
    "CURRENT_PROJECT_VERSION=$BUILD"
)

if [[ "$SIGN_STYLE" == "manual" ]]; then
    archive_args+=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=Apple Distribution"
        "PROVISIONING_PROFILE_SPECIFIER=$TD_IOS_PROFILE"
    )
fi

ARCHIVE_LOG="$RELEASE_DIR/archive.log"
if ! (cd "$IOS_DIR" && xcodebuild archive "${archive_args[@]}" >"$ARCHIVE_LOG" 2>&1); then
    printf '\n'
    grep -E 'error:' "$ARCHIVE_LOG" | head -10 >&2 || true
    if grep -q "No profiles for" "$ARCHIVE_LOG"; then
        printf '\n' >&2
        printf 'xcodebuild could not get a provisioning profile for %s even with the\n' "$BUNDLE_ID" >&2
        printf 'API key. The usual cause is the key not having permission to manage them:\n' >&2
        printf 'an App Store Connect key needs the Admin or App Manager role to create App\n' >&2
        printf 'IDs, certificates and profiles. Check the role next to key %s at\n' "$KEY_ID" >&2
        printf 'https://appstoreconnect.apple.com/access/integrations/api and, if it is\n' >&2
        printf 'lower than that, generate a new key — a role cannot be raised in place.\n' >&2
    fi
    die "archive failed" "Full log: $ARCHIVE_LOG"
fi

APP="$ARCHIVE/Products/Applications/$SCHEME.app"
pass "archived — $ARCHIVE"
detail "$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=/signed by /p' | head -1)"
detail "version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"))"

# -------------------------------------------------------------------- export

heading "2/4  Export"

# The committed ExportOptions.plist is the source of truth; manual signing needs
# two keys added to it, so the copy is what gets patched and thrown away.
OPTIONS="$RELEASE_DIR/ExportOptions.resolved.plist"
cp "$EXPORT_OPTIONS" "$OPTIONS"
if [[ "$SIGN_STYLE" == "manual" ]]; then
    /usr/libexec/PlistBuddy -c "Set :signingStyle manual" "$OPTIONS"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$OPTIONS"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$BUNDLE_ID string '$TD_IOS_PROFILE'" "$OPTIONS"
fi

EXPORT_LOG="$RELEASE_DIR/export.log"
if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$OPTIONS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$KEY_ID" \
        -authenticationKeyIssuerID "$ISSUER" >"$EXPORT_LOG" 2>&1; then
    printf '\n'
    grep -E 'error:|Error Domain' "$EXPORT_LOG" | head -10 >&2 || true
    die "export failed" "Full log: $EXPORT_LOG"
fi

[[ -f "$IPA" ]] || die "export reported success but there is no .ipa at $IPA" "Log: $EXPORT_LOG"
pass "exported — $IPA ($(du -h "$IPA" | cut -f1))"

# ------------------------------------------------------------------ validate

if (( VALIDATE )); then
    heading "3/4  Validate"
    # The same checks the upload runs, without spending the upload. Anything
    # caught here is caught in seconds instead of in an email.
    if ! xcrun altool --validate-app -f "$IPA" -t ios \
            --api-key "$KEY_ID" --api-issuer "$ISSUER" 2>&1 | tee "$RELEASE_DIR/validate.log"; then
        explain_altool_failure "$RELEASE_DIR/validate.log"
        die "validation failed" "Log: $RELEASE_DIR/validate.log"
    fi
    pass "App Store Connect accepted the package for validation"
fi

# -------------------------------------------------------------------- upload

if (( ! UPLOAD )); then
    heading "Stopping before upload"
    printf '  The .ipa is at %s\n' "$IPA"
    printf '  Send it with:\n'
    printf '    xcrun altool --upload-app -f %s -t ios --api-key %s --api-issuer "$ASC_ISSUER_ID"\n\n' "$IPA" "$KEY_ID"
    exit 0
fi

heading "4/4  Upload"

UPLOAD_LOG="$RELEASE_DIR/upload.log"
if ! xcrun altool --upload-app -f "$IPA" -t ios \
        --api-key "$KEY_ID" --api-issuer "$ISSUER" 2>&1 | tee "$UPLOAD_LOG"; then
    explain_altool_failure "$UPLOAD_LOG"
    die "upload failed" "Log: $UPLOAD_LOG"
fi

heading "Uploaded"
cat <<EOF
  $APP_NAME $MARKETING ($BUILD) is on its way to App Store Connect.

  Uploaded is not the same as testable. Processing takes 5–15 minutes and can
  still end in INVALID; then the build needs its export-compliance answer and a
  tester group before it reaches a phone. All three are one command:

    node scripts/ios/testflight.mjs $BUILD

  It waits for a terminal processing state, exits non-zero on INVALID, answers
  compliance over the API (the Info.plist deliberately does not — see
  preflight.sh) and attaches the build to the internal group.

  Build number $BUILD is now used forever. The next run stamps a later one.
EOF
