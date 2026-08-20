#!/usr/bin/env bash
#
# Build a macOS release that a stranger can open: Developer ID signed,
# notarized by Apple, and stapled so it opens with no network.
#
#     scripts/mac-release-signed.sh
#
# Runs in two places and does the same thing in both:
#
#   * **On this Mac**, reading the Developer ID identity out of the dedicated
#     `terminaldeck-signing.keychain-db` and the App Store Connect key out of
#     `~/private_keys`.
#   * **On a GitHub Actions macOS runner**, reading both out of repository
#     secrets. `.github/workflows/release.yml` calls this script instead of
#     `npm run dist:mac`, so a tag push produces a signed build without anyone
#     remembering to do anything.
#
# The second mode is why this file exists in its current shape. v0.1.9 shipped
# an unsigned dmg — every download told the user the app "is damaged and can't
# be opened" — and it shipped that way even though the certificate existed and
# even though SIGNING-HANDOFF.md documented this exact script as the thing to
# run. A release step that a human has to remember is a release step that gets
# skipped, and it got skipped the very first time it mattered. So the signing
# moved to the machine that builds the artifact.
#
# ## Why the committed electron-builder.yml still says `identity: null`
#
# The obvious move is to put `identity:` and `notarize: true` in the config and
# be done. It is the wrong move here, for two reasons that both cost a build:
#
#  1. **Not every build has a certificate.** A fork, or a `workflow_dispatch`
#     run from a checkout with no secrets, has an empty keychain. A hardcoded
#     identity turns those into a hard failure with a confusing message.
#  2. **Auto-discovery picks the wrong certificate.** Remove `identity: null`
#     and electron-builder searches the keychain, finds
#     `Apple Distribution: Asad Iqbal`, and signs with it. That produces a
#     bundle that looks signed, passes `codesign --verify`, and is rejected by
#     notarization — because Apple Distribution is the App Store certificate and
#     Developer ID is the download-from-a-website certificate. They are not
#     interchangeable and the failure arrives twenty minutes later.
#
# So the committed config stays unsigned and honest, and signing is an explicit
# act. Everything below is passed as `-c.` overrides, which electron-builder
# treats exactly as if it had been in the file.
#
# ## The ordering that matters
#
# Notarization must happen to the **.app**, before the dmg and zip are built
# from it. electron-builder does this in the right order and `@electron/notarize`
# staples the app afterwards, so both artifacts contain a stapled bundle.
#
# The disk image then needs its own ticket — a stapled app inside an unstapled
# dmg still makes Gatekeeper phone home on first open, and fails
# `stapler validate` on the dmg itself. So the dmg is submitted separately at
# the end. That submission is quick: Apple has already seen the app inside it.
#
# Stapling rewrites the dmg. That invalidates two things electron-builder had
# already written about it, and only one of them used to be repaired here:
#
#   * the `sha512` and `size` in `latest-mac.yml`, and
#   * `terminaldeck-<version>-arm64.dmg.blockmap`, which is a content-defined
#     block map of the exact bytes and describes a file that no longer exists.
#
# macOS auto-update reads the **zip** entry rather than the dmg, so neither has
# ever broken an update — but a published manifest that disagrees with the
# published bytes is the kind of thing that is discovered at the worst possible
# moment, and "it happens not to be read" is not a reason to publish a wrong
# number. Both are rebuilt below, using electron-builder's own blockmap code so
# the replacement is byte-for-byte the file it would have written itself.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The common name WITHOUT the `Developer ID Application:` prefix.
#
# electron-builder refuses the full string outright — "Please remove prefix
# ... appropriate certificate will be chosen automatically" — because it
# prepends the type itself when it searches the keychain. Passing the name it
# is printed with in `security find-identity` therefore fails, which reads like
# the certificate is missing when it is sitting right there. The team id stays,
# and it is what makes this unambiguous against the `Apple Distribution: Asad
# Iqbal` that shares this Mac.
IDENTITY="${TD_MAC_IDENTITY:-Asad Iqbal (6U4VNX5W87)}"

# ## Signing without notarizing, and why that mode has to exist
#
# Notarization is Apple's service, and this account is not provisioned to use
# it. Every submission ever made from it — five between 2026-08-14 and
# 2026-08-17, plus a fresh probe on 2026-08-20 — came back `Rejected` with
# statusCode 7000, "Team is not yet configured for notarization. Please contact
# Developer Programs Support." The submissions were never hanging: the
# 2026-08-20 probe was answered in fourteen seconds. Nothing in this repository
# can clear it and no amount of waiting will — it takes a support request from
# the account holder.
#
# The question that leaves is what a release does in the meantime, and the three
# answers are not equal:
#
#   * **Unsigned**, which is what 0.1.9 did. Gatekeeper tells the user the app
#     "is damaged and can't be opened". That wording means *quarantined and
#     unsigned*, but it reads as a corrupt download, so the user deletes it and
#     never learns otherwise. This is the worst outcome and it is the one that
#     happens by default.
#   * **Signed but not notarized**, this mode. Gatekeeper says the developer
#     cannot be verified and offers no button on the dialog itself — the way
#     through is System Settings > Privacy & Security > **Open Anyway**, which
#     appears only after the app has been opened once and refused. Right-click >
#     Open has NOT been a way past this since macOS 15; it now produces the same
#     dead end as a double-click, and release notes that still say otherwise
#     send the user in a circle. Verified on macOS 27: a quarantined v0.8.1
#     bundle is `rejected / source=Unnotarized Developer ID`.
#   * **Signed, notarized, stapled**, which is what this script does whenever
#     Apple is answering, and remains the default.
#
# So this is a deliberate degradation with an explicit switch, never a silent
# fallback: `--signed-only` has to be typed. A build that *tried* to notarize
# and failed is still a hard error, because a notarization that fails for a
# reason other than an account hold is usually the certificate being wrong, and
# that must never be papered over.
SIGNED_ONLY=0

# A ceiling on the wait, because there was not one.
#
# `notarytool submit --wait` has no default timeout: when the service stopped
# answering, an electron-builder run sat waiting for twenty-three hours and had
# to be killed by hand. It was not obviously hung — it was doing exactly what it
# was told. Two hours is far longer than a healthy submission (minutes) and far
# shorter than a night.
NOTARIZE_TIMEOUT="${TD_NOTARIZE_TIMEOUT:-2h}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signed-only) SIGNED_ONLY=1 ;;
        --notarize-timeout) NOTARIZE_TIMEOUT="${2:?--notarize-timeout needs a value}"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."

# ---------------------------------------------------------------- credentials
#
# Two sources, one shape. Whichever runs, the rest of this script sees a
# keychain holding exactly one Developer ID Application identity and a readable
# `.p8` on disk, and does not care where they came from.

# Teardown runs in reverse, the way teardown always should: the search list is
# restored before the keychain it points at is deleted, and the keychain is
# deleted before the directory holding it is removed. Forward order would
# "succeed" at every step by deleting the file first and then failing quietly to
# find it, leaving a dangling entry in the user's keychain search list — which
# on a developer's own Mac is a booby trap for the next signing run rather than
# a cosmetic mess.
CLEANUP=()
cleanup() {
    for ((i = ${#CLEANUP[@]} - 1; i >= 0; i--)); do
        eval "${CLEANUP[$i]}" || true
    done
}
trap cleanup EXIT

if [[ -n "${MACOS_CERTIFICATE_P12:-}" ]]; then
    step "Preflight (signing material from repository secrets)"

    [[ -n "${MACOS_CERTIFICATE_PASSWORD:-}" ]] || die "MACOS_CERTIFICATE_P12 is set but MACOS_CERTIFICATE_PASSWORD is not."
    [[ -n "${APPLE_API_KEY_P8:-}" ]]           || die "no APPLE_API_KEY_P8 secret — nothing to notarize with."
    [[ -n "${APPLE_API_KEY_ID:-}" ]]           || die "no APPLE_API_KEY_ID secret."
    [[ -n "${APPLE_API_ISSUER:-}" ]]           || die "no APPLE_API_ISSUER secret."

    SECRET_DIR="$(mktemp -d)"
    chmod 700 "$SECRET_DIR"
    CLEANUP+=("rm -rf '$SECRET_DIR'")

    ASC_KEY_ID="$APPLE_API_KEY_ID"
    ASC_ISSUER="$APPLE_API_ISSUER"
    ASC_KEY_PATH="$SECRET_DIR/AuthKey_$ASC_KEY_ID.p8"
    printf '%s' "$APPLE_API_KEY_P8" | base64 --decode > "$ASC_KEY_PATH"
    chmod 600 "$ASC_KEY_PATH"
    # A truncated or mis-pasted secret decodes to something, and notarytool's
    # complaint about it arrives after the twenty-minute build. Checked here,
    # where the fix is "paste the secret again".
    grep -q "BEGIN PRIVATE KEY" "$ASC_KEY_PATH" \
        || die "APPLE_API_KEY_P8 did not decode to a PEM private key." \
               "It must be the base64 of the whole AuthKey_<id>.p8 file:" \
               "  base64 -i ~/private_keys/AuthKey_<id>.p8 | gh secret set APPLE_API_KEY_P8"

    printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$SECRET_DIR/devid.p12"

    # A keychain of our own, thrown away at the end.
    #
    # It is created rather than letting electron-builder do it from CSC_LINK,
    # and that is deliberate: CSC_LINK makes electron-builder build a *second*
    # keychain of its own, and then two keychains in the search list each hold
    # an identity of the same name. `codesign` will not choose between
    # identically named identities and reports `errSecInternalComponent`, which
    # reads exactly like a locked keychain and sends you looking at passwords
    # for an hour. One keychain, made here, checked here.
    KEYCHAIN="$SECRET_DIR/terminaldeck-ci.keychain-db"
    KC_PW="$(openssl rand -hex 24)"
    security create-keychain -p "$KC_PW" "$KEYCHAIN"
    CLEANUP+=("security delete-keychain '$KEYCHAIN' >/dev/null 2>&1")
    # No timeout and no lock-on-sleep. The default is a five-minute auto-lock,
    # and notarization parks this script for considerably longer than five
    # minutes — so the keychain would be open for the app signing and locked
    # again by the time the *disk image* is signed at the very end. That failure
    # lands on the last step of a twenty-minute build.
    security set-keychain-settings "$KEYCHAIN"
    # `tr` folds the newlines to spaces, and that is not cosmetic. This value is
    # baked into a cleanup command that is later run through `eval`, and a
    # newline inside that string would be read as a command separator — so a
    # machine with two user keychains would "restore" the first one and then try
    # to execute the path of the second. A hosted runner has exactly one user
    # keychain and would never have shown it; this Mac has two.
    ORIGINAL_KEYCHAINS="$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//' | tr '\n' ' ')"
    CLEANUP+=("security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1")
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_KEYCHAINS
    security unlock-keychain -p "$KC_PW" "$KEYCHAIN"

    security import "$SECRET_DIR/devid.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign

    # Without this every `codesign` call raises a GUI prompt for permission to
    # use the key. There is no GUI on a runner and nobody to answer it, so the
    # build does not fail — it hangs until the job timeout, forty-five minutes
    # later, with no clue in the log about why.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KEYCHAIN" >/dev/null
else
    step "Preflight (signing material from this Mac)"

    KEYCHAIN="$HOME/Library/Keychains/terminaldeck-signing.keychain-db"
    PW_FILE="$HOME/ClaudeAsad/credentials/.terminaldeck-signing-pw"

    # Read from the environment or from disk, never hardcoded. This repository
    # is public, and while an API key id is useless without the .p8 beside it,
    # the id, the issuer and the team id together fingerprint a specific Apple
    # account for no benefit. Both live in
    # `~/ClaudeAsad/credentials/apple-appstore.md`.
    ASC_KEY_ID="${ASC_KEY_ID:-$(cat "$HOME/private_keys/key_id.txt" 2>/dev/null || true)}"
    ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    ASC_ISSUER="${ASC_ISSUER_ID:-$(cat "$HOME/private_keys/issuer_id.txt" 2>/dev/null || true)}"

    [[ -f "$PW_FILE" ]]      || die "keychain password missing: $PW_FILE"
    [[ -f "$ASC_KEY_PATH" ]] || die "App Store Connect key missing: $ASC_KEY_PATH"
    [[ -n "$ASC_ISSUER" ]]   || die "no issuer id." \
        "export ASC_ISSUER_ID=<uuid>, or put it in ~/private_keys/issuer_id.txt." \
        "It is readable only at App Store Connect > Users and Access > Integrations."

    security unlock-keychain -p "$(cat "$PW_FILE")" "$KEYCHAIN"

    # `imatch-ship` holds a second `Apple Distribution: Asad Iqbal` for a
    # different product. It is deliberately absent from the search list; if
    # something has put it back, signing breaks in a way that takes hours to
    # attribute.
    if security list-keychains | grep -q "imatch-ship"; then
        die "imatch-ship.keychain-db is in the search list." \
            "Remove it: security list-keychains -s $KEYCHAIN ~/Library/Keychains/login.keychain-db"
    fi
fi

DEVID_COUNT="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -c "Developer ID Application" || true)"
if [[ "$DEVID_COUNT" -eq 0 ]]; then
    die "no Developer ID Application certificate in $(basename "$KEYCHAIN")." \
        "" \
        "Apple refuses to issue one over the App Store Connect API — POST /v1/certificates" \
        "answers 403 'This operation can only be performed by the Account Holder' for both" \
        "DEVELOPER_ID_APPLICATION and DEVELOPER_ID_APPLICATION_G2, whatever the key's role." \
        "It has to be created in the signed-in developer portal. See SIGNING-HANDOFF.md."
elif [[ "$DEVID_COUNT" -gt 1 ]]; then
    die "$DEVID_COUNT Developer ID Application identities are visible." \
        "codesign cannot choose between identically named identities and calls it" \
        "errSecInternalComponent, which looks like a locked keychain and is not."
fi

security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application"

# ------------------------------------------------------------------- build

step "Build"
npm run build
npm run build:pwa

step "Package, sign and notarize"

# Read by app-builder-lib/out/mac/MacTargetHelper.js — all three or none.
export APPLE_API_KEY="$ASC_KEY_PATH"
export APPLE_API_KEY_ID="$ASC_KEY_ID"
export APPLE_API_ISSUER="$ASC_ISSUER"
export CSC_KEYCHAIN="$KEYCHAIN"

npx electron-builder --mac --publish never \
    -c.mac.identity="$IDENTITY" \
    -c.mac.notarize=$([[ "$SIGNED_ONLY" -eq 1 ]] && echo false || echo true) \
    -c.dmg.sign=true

# Both names come out of package.json rather than being typed here. The bundle
# is named after `productName` and the artifacts after `name`, and this repo
# keeps the product name in one place — a release script is no more exempt from
# that than a component is. It is also the difference between renaming the app
# and renaming the app *and remembering this file*.
VERSION="$(node -p "require('$REPO/package.json').version")"
PRODUCT="$(node -p "require('$REPO/package.json').productName")"
SLUG="$(node -p "require('$REPO/package.json').name")"
APP="release/mac-arm64/$PRODUCT.app"
DMG="release/$SLUG-$VERSION-arm64.dmg"
ZIP="release/$SLUG-$VERSION-arm64.zip"

[[ -d "$APP" ]] || die "no app bundle at $APP"
[[ -f "$DMG" ]] || die "no disk image at $DMG"

# --------------------------------------------------------------- notarize dmg

if [[ "$SIGNED_ONLY" -eq 1 ]]; then
    step "Notarization skipped (--signed-only)"
    printf '  The bundle is Developer ID signed and NOT notarized.\n'
    printf '  Gatekeeper will say the developer cannot be verified.\n'
    printf '  The way through is System Settings > Privacy & Security >\n'
    printf '  Open Anyway, after one refused launch. NOT right-click > Open,\n'
    printf '  which macOS 15 removed. The release notes must say so.\n'
else
    step "Notarize the disk image"
    # `--timeout` is notarytool's own flag, so the wait ends inside the tool with
    # a non-zero exit and a readable message, rather than being killed from
    # outside and leaving a half-described failure.
    xcrun notarytool submit "$DMG" \
        --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
        --wait --timeout "$NOTARIZE_TIMEOUT" \
        || die "notarization did not complete within $NOTARIZE_TIMEOUT." \
            "" \
            "Check what Apple actually said — a Rejected submission is not a slow one:" \
            "  xcrun notarytool history --key <p8> --key-id <id> --issuer <uuid>" \
            "  xcrun notarytool log <submission-id> --key <p8> --key-id <id> --issuer <uuid>" \
            "" \
            "statusCode 7000 'Team is not yet configured for notarization' is an account" \
            "provisioning state, not a queue. It clears only when the account holder files" \
            "a support request with Apple; retrying and waiting do nothing." \
            "" \
            "To ship signed-but-not-notarized in the meantime:" \
            "  scripts/mac-release-signed.sh --signed-only"
    xcrun stapler staple "$DMG"
fi

# The staple rewrote the file. Repair everything that described the old bytes.
step "Rebuild the disk image blockmap and its manifest entry"
node - "$DMG" <<'NODE'
// electron-builder's own blockmap builder, called the same way its dmg target
// calls it (`createBlockmap` in targets/differentialUpdateInfoBuilder.js:
// gzip, written to <file>.blockmap). Reimplementing it here would produce a
// file that looks right and does not match what electron-updater expects, so
// the real one is reused instead — and it hands back the size and sha512 of
// the file as it exists after the call, which is exactly the pair that
// stapling falsified.
const { buildBlockMap } = require('app-builder-lib/out/targets/blockmap/blockmap')
const { readFileSync, writeFileSync } = require('node:fs')
const { basename } = require('node:path')

const dmg = process.argv[2]
const manifest = 'release/latest-mac.yml'

buildBlockMap(dmg, 'gzip', `${dmg}.blockmap`).then((info) => {
  console.log(`  ${basename(dmg)}.blockmap rebuilt against the stapled bytes`)

  const name = basename(dmg)
  const lines = readFileSync(manifest, 'utf8').split('\n')
  let hit = false
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].includes(`url: ${name}`)) continue
    hit = true
    for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
      if (/^\s+sha512:/.test(lines[j])) lines[j] = lines[j].replace(/sha512:.*/, `sha512: ${info.sha512}`)
      if (/^\s+size:/.test(lines[j])) lines[j] = lines[j].replace(/size:.*/, `size: ${info.size}`)
    }
  }
  if (!hit) {
    console.log(`  ${name} is not listed in ${manifest} — nothing to correct`)
    return
  }
  writeFileSync(manifest, lines.join('\n'))
  console.log(`  ${name}: sha512 and size updated in ${manifest}`)
}).catch((e) => { console.error(e); process.exit(1) })
NODE

# ------------------------------------------------------------------- verify

step "Verify"

fail=0
check() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32m✓\033[0m %s\n' "$1"; else printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; fi; }

# --deep is safe as a *verification* flag. It is never used to SIGN here: it
# walks Electron's nested frameworks in the wrong order and produces a bundle
# that will not launch. That has already happened once in this repository.
check "codesign --verify --strict (app)"   "codesign --verify --strict --verbose=2 '$APP'"
check "codesign --verify --deep (app)"     "codesign --verify --deep --strict '$APP'"

if [[ "$SIGNED_ONLY" -eq 1 ]]; then
    # spctl and stapler both fail here *correctly* — there is no notarization
    # ticket to accept or to staple — so asserting them would fail every
    # signed-only build for the one reason we already know about.
    #
    # What replaces them is the check that actually matters in this mode, and
    # that nothing else makes: that the bundle really is Developer ID signed.
    # Without it, "signed-only" degrades silently into "unsigned", which is the
    # exact failure this whole file exists to prevent — and the two are
    # indistinguishable from the outside until a stranger downloads one and is
    # told the app is damaged.
    check "Developer ID authority on the app" \
        "codesign -dv --verbose=2 '$APP' 2>&1 | grep -q 'Authority=Developer ID Application'"
    check "the signature is not ad-hoc" \
        "! codesign -dv --verbose=2 '$APP' 2>&1 | grep -q 'Signature=adhoc'"
    printf '  \033[33m—\033[0m spctl and stapler not checked: this build is not notarized\n'
else
    check "spctl accepts the app"              "spctl -a -vv -t exec '$APP'"
    check "spctl accepts the disk image"       "spctl -a -vv -t install '$DMG'"
    check "stapler validate (app)"             "xcrun stapler validate '$APP'"
    check "stapler validate (dmg)"             "xcrun stapler validate '$DMG'"
fi

# The app inside the ZIP is the one electron-updater installs, and it is a
# different copy of the bundle from the one verified above — electron-builder
# archives it separately. An unstapled app in the zip updates a user into a
# build that has to phone Apple on first launch, and cannot launch at all if
# they are offline. Cheap to check, and nothing else checks it.
step "The app inside the update zip is stapled too"
ZIP_CHECK="$(mktemp -d)"
CLEANUP+=("rm -rf '$ZIP_CHECK'")
# `ditto` first because electron-builder writes this archive with `ditto -c -k`
# and it is the only unpacker guaranteed to restore the symlinks inside an
# Electron framework; `unzip` is the fallback so that a change in how the
# archive is produced turns into a slower check rather than a failed release.
ditto -x -k "$ZIP" "$ZIP_CHECK" 2>/dev/null || unzip -qq -o "$ZIP" -d "$ZIP_CHECK" 2>/dev/null || true
ZIP_APP="$(find "$ZIP_CHECK" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -n "$ZIP_APP" ]]; then
    if [[ "$SIGNED_ONLY" -eq 1 ]]; then
        # Same substitution as above: the ticket does not exist, so check that
        # the separately-archived copy carries the same certificate as the one
        # verified above. electron-builder signs it in its own pass, and a
        # release where the dmg is signed and the update zip is not would hand
        # every self-updating user an app that cannot open.
        check "Developer ID authority on the app inside the zip" \
            "codesign -dv --verbose=2 '$ZIP_APP' 2>&1 | grep -q 'Authority=Developer ID Application'"
    else
        check "stapler validate (app inside the zip)" "xcrun stapler validate '$ZIP_APP'"
        check "spctl accepts the app inside the zip"  "spctl -a -vv -t exec '$ZIP_APP'"
    fi
else
    printf '  \033[31m✗\033[0m no .app came out of %s\n' "$ZIP"; fail=1
fi

# Every artifact present, and every hash in the manifest matching the bytes on
# disk. This is the step that would have caught a stale checksum before it was
# published rather than after.
step "Manifest agrees with the files"
npm run release:check || fail=1

printf '\n'
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^Identifier=|^Authority=|^TeamIdentifier=|flags="

printf '\nArtifacts:\n'
ls -lh "$DMG" "$ZIP" 2>/dev/null | awk '{print "  " $9 "  " $5}'

if [[ "$fail" -ne 0 ]]; then
    die "at least one verification failed — do not publish this build."
fi

if [[ "$SIGNED_ONLY" -eq 1 ]]; then
    printf '\n\033[33mSigned, NOT notarized.\033[0m\n'
    printf 'A stranger can open this, but only via System Settings > Privacy & Security\n'
    printf '> Open Anyway, after one refused launch. Say that in the release notes, or\n'
    printf 'they will think the download is broken.\n'
else
    printf '\n\033[32mSigned, notarized and stapled.\033[0m A stranger can open this.\n'
fi
