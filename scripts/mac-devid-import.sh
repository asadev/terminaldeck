#!/usr/bin/env bash
#
# Import a Developer ID Application certificate into the dedicated keychain.
#
# Run this ONCE, with the `.cer` Apple hands back after the CSR is uploaded:
#
#     scripts/mac-devid-import.sh ~/Downloads/developerID_application.cer
#
# ## Why a script rather than a double-click
#
# Double-clicking a `.cer` puts it in the **login** keychain, and that is the
# one thing this project must not do. `apple-appstore.md` records the trap in
# full: two identically named identities make `codesign` report
# `errSecInternalComponent`, which reads exactly like a locked keychain and is
# not one. Everything Terminal Deck signs with lives in
# `terminaldeck-signing.keychain-db` and nowhere else.
#
# ## What the certificate is, and what it is not
#
# A `.cer` from Apple is only the public half. It is useless without the
# private key the CSR was generated from — `~/private_keys/DeveloperID_TerminalDeck.key`.
# The two are married here into a PKCS#12 and imported together. Lose the key
# and the certificate has to be revoked and reissued; Apple cannot re-send it.
#
# Developer ID Application is NOT the same certificate as Apple Distribution.
# Apple Distribution signs App Store submissions. Developer ID Application
# signs software people download from a website, and it is the only kind
# Gatekeeper accepts outside the store. Both can be on the account at once and
# they do not substitute for one another.

set -euo pipefail

CER="${1:-}"
KEY="$HOME/private_keys/DeveloperID_TerminalDeck.key"
KEYCHAIN="$HOME/Library/Keychains/terminaldeck-signing.keychain-db"
PW_FILE="$HOME/ClaudeAsad/credentials/.terminaldeck-signing-pw"

die() { printf '\nerror: %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

[[ -n "$CER" ]] || die "no certificate given." "usage: $0 <developerID_application.cer>"
[[ -f "$CER" ]] || die "no such file: $CER"
[[ -f "$KEY" ]] || die "the private key is missing: $KEY" \
    "Without it the certificate cannot be used. Generate a new CSR and reissue:" \
    "  openssl genrsa -out $KEY 2048" \
    "  openssl req -new -key $KEY -out ~/private_keys/DeveloperID_TerminalDeck.csr \\" \
    "    -subj '/emailAddress=asadiqbalonline@gmail.com/CN=Asad Iqbal/C=US'"
[[ -f "$PW_FILE" ]] || die "keychain password file missing: $PW_FILE"

PW="$(cat "$PW_FILE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Apple hands back DER. openssl needs to be told which it is, and guessing
# wrong produces a PKCS#12 that imports without complaint and signs nothing.
if openssl x509 -inform DER -in "$CER" -noout >/dev/null 2>&1; then
    openssl x509 -inform DER -in "$CER" -out "$TMP/cert.pem"
elif openssl x509 -inform PEM -in "$CER" -noout >/dev/null 2>&1; then
    cp "$CER" "$TMP/cert.pem"
else
    die "$CER is neither DER nor PEM — is it really the certificate Apple issued?"
fi

SUBJECT="$(openssl x509 -in "$TMP/cert.pem" -noout -subject)"
printf 'certificate: %s\n' "$SUBJECT"
case "$SUBJECT" in
    *"Developer ID Application"*) ;;
    *) printf '\nwarning: this does not look like a Developer ID Application certificate.\n'
       printf '  Apple Distribution and Apple Development certificates cannot be notarized.\n\n' ;;
esac

# The key and the certificate must actually belong to each other. Apple will
# happily issue against a CSR from a key you no longer have, and the mismatch
# only shows up as an identity that never appears in `find-identity`.
KEY_MOD="$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | openssl md5)"
CRT_MOD="$(openssl x509 -in "$TMP/cert.pem" -noout -modulus | openssl md5)"
[[ "$KEY_MOD" == "$CRT_MOD" ]] || die \
    "the certificate does not match the private key." \
    "This certificate was issued against a different CSR. Reissue it against" \
    "~/private_keys/DeveloperID_TerminalDeck.csr, or regenerate both."

# Apple's Developer ID intermediate. Without it the chain is incomplete and
# codesign reports the identity as invalid rather than missing, which sends
# people looking in the wrong place.
if ! security find-certificate -c "Developer ID Certification Authority" "$KEYCHAIN" >/dev/null 2>&1; then
    printf 'fetching Apple’s Developer ID intermediate…\n'
    curl -fsSL -o "$TMP/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
    security import "$TMP/DeveloperIDG2CA.cer" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null 2>&1 || true
fi

P12_PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy \
    -inkey "$KEY" -in "$TMP/cert.pem" \
    -name "Developer ID Application (Terminal Deck)" \
    -out "$TMP/devid.p12" -passout "pass:$P12_PW" 2>/dev/null \
  || openssl pkcs12 -export \
        -inkey "$KEY" -in "$TMP/cert.pem" \
        -name "Developer ID Application (Terminal Deck)" \
        -out "$TMP/devid.p12" -passout "pass:$P12_PW"

security unlock-keychain -p "$PW" "$KEYCHAIN"
security import "$TMP/devid.p12" -k "$KEYCHAIN" -P "$P12_PW" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign

# Without this every `codesign` call raises a GUI prompt, which in an unattended
# release is indistinguishable from a hang.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null

printf '\nidentities now in %s:\n' "$(basename "$KEYCHAIN")"
security find-identity -v -p codesigning "$KEYCHAIN"

COUNT="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -c "Developer ID Application" || true)"
if [[ "$COUNT" -eq 1 ]]; then
    printf '\nOne Developer ID Application identity. Ready: scripts/mac-release-signed.sh\n'
elif [[ "$COUNT" -eq 0 ]]; then
    die "the import reported success but no Developer ID identity is visible." \
        "That is almost always a key/certificate mismatch — see the check above."
else
    die "$COUNT Developer ID Application identities are visible." \
        "codesign cannot choose between identically named identities and reports it" \
        "as errSecInternalComponent, which reads like a locked keychain and is not." \
        "Delete the duplicates in Keychain Access before releasing."
fi
