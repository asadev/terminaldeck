#!/usr/bin/env bash
#
# Build a macOS release that a stranger can open: Developer ID signed,
# notarized by Apple, and stapled so it opens with no network.
#
#     scripts/mac-release-signed.sh
#
# ## Why this is a script and not a change to electron-builder.yml
#
# The obvious move is to put `identity:` and `notarize: true` in the config and
# be done. It is the wrong move here, for two reasons that both cost a build:
#
#  1. **CI has no certificate.** `.github/workflows/release.yml` builds macOS on
#     a hosted runner with an empty keychain. A hardcoded identity turns every
#     CI release into a hard failure.
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
# Stapling rewrites the dmg, which changes its hash, which makes the `sha512`
# electron-builder wrote into `latest-mac.yml` a lie. The last step recomputes
# it. macOS auto-update reads the **zip** entry rather than the dmg, so this has
# never broken an update — but a wrong checksum in a published manifest is the
# kind of thing that is discovered at the worst moment.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

KEYCHAIN="$HOME/Library/Keychains/terminaldeck-signing.keychain-db"
PW_FILE="$HOME/ClaudeAsad/credentials/.terminaldeck-signing-pw"
# The common name WITHOUT the `Developer ID Application:` prefix.
#
# electron-builder refuses the full string outright — "Please remove prefix
# ... appropriate certificate will be chosen automatically" — because it
# prepends the type itself when it searches the keychain. Passing the name it
# is printed with in `security find-identity` therefore fails, which reads like
# the certificate is missing when it is sitting right there. The team id stays,
# and it is what makes this unambiguous against the `Apple Distribution: Asad
# Iqbal` in the same keychain.
IDENTITY="${TD_MAC_IDENTITY:-Asad Iqbal (6U4VNX5W87)}"
TEAM_ID="6U4VNX5W87"

# Read from the environment or from disk, never hardcoded. This repository is
# public, and while an API key id is useless without the .p8 beside it, the id,
# the issuer and the team id together fingerprint a specific Apple account for
# no benefit. Both live in `~/ClaudeAsad/credentials/apple-appstore.md`.
ASC_KEY_ID="${ASC_KEY_ID:-$(cat "$HOME/private_keys/key_id.txt" 2>/dev/null || true)}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8}"
ASC_ISSUER="${ASC_ISSUER_ID:-$(cat "$HOME/private_keys/issuer_id.txt" 2>/dev/null || true)}"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

# ---------------------------------------------------------------- preflight

step "Preflight"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ -f "$PW_FILE" ]]      || die "keychain password missing: $PW_FILE"
[[ -f "$ASC_KEY_PATH" ]] || die "App Store Connect key missing: $ASC_KEY_PATH"
[[ -n "$ASC_ISSUER" ]]   || die "no issuer id." \
    "export ASC_ISSUER_ID=<uuid>, or put it in ~/private_keys/issuer_id.txt." \
    "It is readable only at App Store Connect > Users and Access > Integrations."

security unlock-keychain -p "$(cat "$PW_FILE")" "$KEYCHAIN"

DEVID_COUNT="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -c "Developer ID Application" || true)"
if [[ "$DEVID_COUNT" -eq 0 ]]; then
    die "no Developer ID Application certificate in $(basename "$KEYCHAIN")." \
        "" \
        "Apple refuses to issue one over the App Store Connect API — POST /v1/certificates" \
        "answers 403 'This operation can only be performed by the Account Holder' for both" \
        "DEVELOPER_ID_APPLICATION and DEVELOPER_ID_APPLICATION_G2, whatever the key's role." \
        "It has to be created in the signed-in developer portal. See SIGNING-HANDOFF.md;" \
        "the CSR is already generated at ~/private_keys/DeveloperID_TerminalDeck.csr."
elif [[ "$DEVID_COUNT" -gt 1 ]]; then
    die "$DEVID_COUNT Developer ID Application identities are visible." \
        "codesign cannot choose between identically named identities and calls it" \
        "errSecInternalComponent, which looks like a locked keychain and is not."
fi

security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application"

# `imatch-ship` holds a second `Apple Distribution: Asad Iqbal` for a different
# product. It is deliberately absent from the search list; if something has put
# it back, signing breaks in a way that takes hours to attribute.
if security list-keychains | grep -q "imatch-ship"; then
    die "imatch-ship.keychain-db is in the search list." \
        "Remove it: security list-keychains -s $KEYCHAIN ~/Library/Keychains/login.keychain-db"
fi

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
    -c.mac.notarize=true \
    -c.dmg.sign=true

VERSION="$(node -p "require('$REPO/package.json').version")"
APP="release/mac-arm64/Terminal Deck.app"
DMG="release/terminaldeck-$VERSION-arm64.dmg"
ZIP="release/terminaldeck-$VERSION-arm64.zip"

[[ -d "$APP" ]] || die "no app bundle at $APP"
[[ -f "$DMG" ]] || die "no disk image at $DMG"

# --------------------------------------------------------------- notarize dmg

step "Notarize the disk image"
xcrun notarytool submit "$DMG" \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
    --wait
xcrun stapler staple "$DMG"

# The staple rewrote the file. Fix the manifest rather than publish a hash that
# does not match the bytes.
step "Re-checksum latest-mac.yml"
node - "$DMG" <<'NODE'
const { createHash } = require('node:crypto')
const { readFileSync, writeFileSync, statSync } = require('node:fs')
const { basename } = require('node:path')
const dmg = process.argv[2]
const manifest = 'release/latest-mac.yml'
const sha512 = createHash('sha512').update(readFileSync(dmg)).digest('base64')
const size = statSync(dmg).size
const name = basename(dmg)
let text = readFileSync(manifest, 'utf8')
const lines = text.split('\n')
let hit = false
for (let i = 0; i < lines.length; i++) {
  if (lines[i].includes(`url: ${name}`)) {
    hit = true
    for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
      if (/^\s+sha512:/.test(lines[j])) lines[j] = lines[j].replace(/sha512:.*/, `sha512: ${sha512}`)
      if (/^\s+size:/.test(lines[j])) lines[j] = lines[j].replace(/size:.*/, `size: ${size}`)
    }
  }
}
if (!hit) { console.log(`  ${name} is not listed in ${manifest} — nothing to correct`); process.exit(0) }
writeFileSync(manifest, lines.join('\n'))
console.log(`  ${name}: sha512 and size updated in ${manifest}`)
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
check "spctl accepts the app"              "spctl -a -vv -t exec '$APP'"
check "spctl accepts the disk image"       "spctl -a -vv -t install '$DMG'"
check "stapler validate (app)"             "xcrun stapler validate '$APP'"
check "stapler validate (dmg)"             "xcrun stapler validate '$DMG'"

printf '\n'
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^Identifier=|^Authority=|^TeamIdentifier=|flags="

printf '\nArtifacts:\n'
ls -lh "$DMG" "$ZIP" 2>/dev/null | awk '{print "  " $9 "  " $5}'

if [[ "$fail" -ne 0 ]]; then
    die "at least one verification failed — do not publish this build."
fi

printf '\n\033[32mSigned, notarized and stapled.\033[0m A stranger can open this.\n'
