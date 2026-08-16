#!/usr/bin/env bash
#
# Put this Mac's macOS signing material into GitHub repository secrets, so that
# `.github/workflows/release.yml` can sign and notarize a release without this
# Mac being involved.
#
#     scripts/mac-ci-secrets.sh                    # asadev/terminaldeck
#     scripts/mac-ci-secrets.sh myfork/terminaldeck
#
# Run it once now, and again whenever the Developer ID certificate is renewed —
# Apple issues them for five years, which is exactly long enough for everybody
# to have forgotten how this was set up. That is the reason this is a script and
# not a paragraph in a document: a paragraph decays, and the last paragraph on
# this subject (SIGNING-HANDOFF.md, "about three minutes") was followed by a
# release that shipped unsigned anyway.
#
# ## What it sets, and why each one
#
#   MACOS_CERTIFICATE_P12        base64 of a PKCS#12 holding the Developer ID
#                                Application certificate, its private key, and
#                                Apple's Developer ID G2 intermediate
#   MACOS_CERTIFICATE_PASSWORD   the passphrase for that PKCS#12 (generated here,
#                                random, used nowhere else, never written to disk
#                                outside a mode-700 temporary directory)
#   APPLE_API_KEY_P8             base64 of the App Store Connect key. This is
#                                what notarization authenticates with; the
#                                certificate alone cannot notarize anything
#   APPLE_API_KEY_ID             the key's id
#   APPLE_API_ISSUER             the issuer uuid. Readable only from App Store
#                                Connect > Users and Access > Integrations, which
#                                is why it is kept on disk here rather than
#                                looked up
#
# ## The intermediate is not optional, and it is not always G2
#
# The certificate Apple hands back is a leaf. On its own it chains to nothing a
# fresh runner is guaranteed to have, and `security find-identity -v` — which
# lists only identities with a complete chain — reports **zero** identities on a
# keychain that visibly contains the certificate. That failure reads as "the
# import silently did nothing", and it is really "the chain has a hole in it".
#
# Which intermediate is a trap. Every guide says to fetch `DeveloperIDG2CA.cer`,
# and this script did exactly that, and it was wrong: *this* certificate is
# issued by the original Developer ID CA —
#
#     issuer=CN=Developer ID Certification Authority,
#            OU=Apple Certification Authority, O=Apple Inc., C=US
#
# — while the G2 file is `OU=G2`, a different certificate entirely. Packing G2
# alongside a G1-issued leaf produces a PKCS#12 that imports without a murmur,
# contains two certificates, and carries no usable chain at all. `openssl verify`
# says it plainly: G1 walks the chain and stops at Apple's custom critical
# extension (error 34), G2 cannot find an issuer (error 20).
#
# It was invisible locally because macOS already trusts both CAs system-wide, so
# nothing on this Mac ever needed the intermediate in the bundle — precisely the
# class of bug that only appears on a clean machine. So the intermediate is now
# CHOSEN by matching the leaf's issuer rather than assumed, and the match is
# checked before anything is uploaded.
#
# ## On putting a signing key in GitHub secrets
#
# It is a real decision and worth making with open eyes. The private half of a
# Developer ID certificate is the thing that lets software claim to be from Asad
# Iqbal. Handing it to Actions means anyone who can push a workflow to this
# repository can sign anything with it.
#
# The exposure is bounded and the alternative was worse. Secrets are not exposed
# to workflows triggered by pull requests from forks, so a drive-by PR cannot
# read them; the only people who can are the people who already have push access
# to a single-maintainer repository. Against that: the release this is fixing
# went out unsigned and told every one of its users the download was damaged.
#
# If it ever does leak: revoke the certificate at
# developer.apple.com/account/resources/certificates, which invalidates
# signatures made after the revocation date but leaves already-notarized builds
# working, then re-issue and re-run this script.

set -euo pipefail

REPO_SLUG="${1:-asadev/terminaldeck}"
KEYCHAIN="$HOME/Library/Keychains/terminaldeck-signing.keychain-db"
PW_FILE="$HOME/ClaudeAsad/credentials/.terminaldeck-signing-pw"
# Every Developer ID CA Apple publishes, newest first. The one that issued this
# particular certificate is selected below by matching hashes; listing them here
# rather than hardcoding one is the whole fix.
APPLE_CAS="DeveloperIDG2CA DeveloperIDCA"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only — the certificate lives in this Mac's keychain."
command -v gh >/dev/null || die "the GitHub CLI is not installed."
[[ -f "$PW_FILE" ]] || die "keychain password missing: $PW_FILE"

# `gh api user` rather than `gh auth status`, because `gh auth status` reports on
# EVERY configured account and exits non-zero if any one of them has a stale
# token — including accounts this script will never use. There are three on this
# Mac and one of them (the retired `AsadIqbalOnline`) has an expired token, so
# `gh auth status` fails permanently while `gh` itself works perfectly. Asking
# the active token to do something is the only check that means anything.
GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
[[ -n "$GH_USER" ]] || die "gh has no working token." \
    "\`gh auth status\` lists the accounts; \`gh auth login\` or \`gh auth switch\` fixes it."
printf '  signed in as %s\n' "$GH_USER"

gh api "repos/$REPO_SLUG" --jq '.permissions.admin' 2>/dev/null | grep -q true \
    || die "$GH_USER is not an admin of $REPO_SLUG." \
           "Setting repository secrets needs admin. \`gh auth switch\` to the owner account."

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ identity

step "The identity to export"

security unlock-keychain -p "$(cat "$PW_FILE")" "$KEYCHAIN"

# `-v` means "valid identities only" — a certificate whose chain does not
# resolve is simply absent from this list rather than listed as broken.
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application" || true)"
COUNT="$(printf '%s' "$IDENTITIES" | grep -c . || true)"

[[ "$COUNT" -eq 1 ]] || die "expected exactly one valid Developer ID Application identity, found $COUNT." \
    "Zero usually means the chain is incomplete rather than the certificate missing." \
    "More than one is the trap that makes codesign report errSecInternalComponent."

printf '%s\n' "$IDENTITIES"
KEYCHAIN_SHA1="$(printf '%s' "$IDENTITIES" | awk '{print $2}')"

# --------------------------------------------------------------------- pack

step "Packing a PKCS#12 with the certificate, its key and Apple's intermediate"

# Exported from the keychain rather than rebuilt from the loose files in
# ~/private_keys, deliberately. There is more than one Developer ID private key
# on this Mac from more than one attempt at getting the certificate issued, and
# only one of them matches the certificate that actually signs — as it happens,
# NOT the one `mac-devid-import.sh` names in its help text. Exporting the
# identity asks the keychain for the pair it is really using and removes the
# guess entirely.
EXPORT_PW="$(openssl rand -hex 24)"
security export -t identities -f pkcs12 -k "$KEYCHAIN" -P "$EXPORT_PW" -o "$TMP/exported.p12"

# macOS writes PKCS#12 files with algorithms OpenSSL 3 considers legacy, so the
# first read fails on a stock OpenSSL 3 and succeeds with -legacy. Trying the
# modern call first keeps this working if Apple ever modernises the format.
p12_read() { openssl pkcs12 -in "$TMP/exported.p12" -passin "pass:$EXPORT_PW" "$@" 2>/dev/null \
          || openssl pkcs12 -legacy -in "$TMP/exported.p12" -passin "pass:$EXPORT_PW" "$@"; }

p12_read -nocerts -nodes  > "$TMP/key.pem"
p12_read -clcerts -nokeys > "$TMP/leaf.pem"

LEAF_SHA1="$(openssl x509 -in "$TMP/leaf.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
[[ "$LEAF_SHA1" == "$KEYCHAIN_SHA1" ]] || die \
    "the exported certificate ($LEAF_SHA1) is not the identity the keychain listed ($KEYCHAIN_SHA1)."

KEY_MOD="$(openssl pkey -in "$TMP/key.pem" -pubout -outform DER | openssl dgst -sha256)"
CRT_MOD="$(openssl x509 -in "$TMP/leaf.pem" -pubkey -noout | openssl pkey -pubin -pubout -outform DER | openssl dgst -sha256)"
[[ "$KEY_MOD" == "$CRT_MOD" ]] || die "the exported key and certificate do not belong to each other."

# Pick the intermediate that actually signed this leaf, by hash rather than by
# name: `-issuer_hash` on the leaf and `-subject_hash` on a candidate are the
# same two values a chain builder compares, and both Apple CAs share a common
# name, so comparing names would match the wrong one.
LEAF_ISSUER_HASH="$(openssl x509 -in "$TMP/leaf.pem" -noout -issuer_hash)"
INTERMEDIATE=""
for CA in $APPLE_CAS; do
    curl -fsSL -o "$TMP/$CA.cer" "https://www.apple.com/certificateauthority/$CA.cer" || continue
    openssl x509 -inform DER -in "$TMP/$CA.cer" -out "$TMP/$CA.pem" 2>/dev/null || continue
    if [[ "$(openssl x509 -in "$TMP/$CA.pem" -noout -subject_hash)" == "$LEAF_ISSUER_HASH" ]]; then
        INTERMEDIATE="$TMP/$CA.pem"
        printf '  intermediate: %s (%s)\n' "$(openssl x509 -in "$INTERMEDIATE" -noout -subject | sed 's/^subject=//')" "$CA"
        break
    fi
    printf '  not this one: %s\n' "$CA"
done
[[ -n "$INTERMEDIATE" ]] || die \
    "none of Apple's published Developer ID CAs issued this certificate." \
    "The leaf says its issuer is:" \
    "  $(openssl x509 -in "$TMP/leaf.pem" -noout -issuer | sed 's/^issuer=//')" \
    "Tried: $APPLE_CAS"

cp "$INTERMEDIATE" "$TMP/intermediate.pem"

P12_PW="$(openssl rand -hex 24)"
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/leaf.pem" -certfile "$TMP/intermediate.pem" \
    -name "Developer ID Application" -out "$TMP/ci.p12" -passout "pass:$P12_PW" 2>/dev/null \
  || openssl pkcs12 -export \
        -inkey "$TMP/key.pem" -in "$TMP/leaf.pem" -certfile "$TMP/intermediate.pem" \
        -name "Developer ID Application" -out "$TMP/ci.p12" -passout "pass:$P12_PW"

CERTS="$(openssl pkcs12 -legacy -in "$TMP/ci.p12" -passin "pass:$P12_PW" -nokeys 2>/dev/null | grep -c "BEGIN CERTIFICATE" || true)"
[[ "$CERTS" -eq 2 ]] || die "the packed PKCS#12 holds $CERTS certificates; it must hold the leaf and the intermediate."

# Counting the certificates is not the same as the chain being usable — the
# version of this script that shipped the wrong intermediate counted two and was
# broken. So the link is checked cryptographically. `openssl verify` cannot
# fully validate an Apple leaf (it stops at error 34, an Apple-specific critical
# extension it does not implement) but it reaches that point only after finding
# and verifying the issuer; error 20, "unable to get local issuer certificate",
# is the failure that matters here and the one the G2 mix-up produced.
VERIFY="$(openssl verify -partial_chain -trusted "$TMP/intermediate.pem" "$TMP/leaf.pem" 2>&1 || true)"
case "$VERIFY" in
    *"unable to get local issuer"*)
        die "the packed intermediate does not chain to the certificate." "$VERIFY" ;;
esac
printf '  packed: leaf + intermediate + private key, chain verified\n'

# ---------------------------------------------------------- notarization key

step "The notarization key"

ASC_KEY_ID="${ASC_KEY_ID:-$(cat "$HOME/private_keys/key_id.txt" 2>/dev/null || true)}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8}"
ASC_ISSUER="${ASC_ISSUER_ID:-$(cat "$HOME/private_keys/issuer_id.txt" 2>/dev/null || true)}"

[[ -n "$ASC_KEY_ID" ]]   || die "no App Store Connect key id (~/private_keys/key_id.txt)."
[[ -f "$ASC_KEY_PATH" ]] || die "App Store Connect key missing: $ASC_KEY_PATH"
[[ -n "$ASC_ISSUER" ]]   || die "no issuer id (~/private_keys/issuer_id.txt)."

# Proving the key works here is worth the twenty seconds. The alternative is
# discovering it does not from a release build, after the twenty-minute part.
xcrun notarytool history --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" >/dev/null \
    || die "notarytool would not authenticate with the key on this Mac." \
           "Uploading it to CI would only move the failure somewhere harder to see."
printf '  key %s authenticates against the notary service\n' "$ASC_KEY_ID"

# ------------------------------------------------------------------ upload

step "Setting the secrets on $REPO_SLUG"

set_secret() { gh secret set "$1" -R "$REPO_SLUG" --body "$2" >/dev/null && printf '  set %s\n' "$1"; }

set_secret MACOS_CERTIFICATE_P12      "$(base64 < "$TMP/ci.p12" | tr -d '\n')"
set_secret MACOS_CERTIFICATE_PASSWORD "$P12_PW"
set_secret APPLE_API_KEY_P8           "$(base64 < "$ASC_KEY_PATH" | tr -d '\n')"
set_secret APPLE_API_KEY_ID           "$ASC_KEY_ID"
set_secret APPLE_API_ISSUER           "$ASC_ISSUER"

printf '\n\033[32mDone.\033[0m Every tagged release now signs and notarizes on the runner.\n'
printf 'Prove it without publishing anything:\n'
printf '  gh workflow run Release -R %s -f platforms=macos\n' "$REPO_SLUG"
