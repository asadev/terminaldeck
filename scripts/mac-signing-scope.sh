#!/usr/bin/env bash
# Source before real Mac signing. Ad-hoc signing does not use a private key.
td_mac_signing_scope() {
    [[ -n "${TD_SIGNING_KEYCHAIN:-}" && -n "${TD_SIGNING_SHA1:-}" ]] || {
        echo 'Local Mac signing requires explicit TD_SIGNING_KEYCHAIN and TD_SIGNING_SHA1' >&2; return 1;
    }
    local keychain="$TD_SIGNING_KEYCHAIN"
    local identities rows count sha1 name requested password restore_xtrace=0
    [[ "$keychain" == "$HOME/Library/Keychains/terminaldeck-signing.keychain-db" ]] || {
        echo 'Mac signing requires the explicit Terminal Deck keychain' >&2; return 1;
    }
    [[ -r "$HOME/ClaudeAsad/credentials/.terminaldeck-signing-pw" ]] || {
        echo 'Terminal Deck signing password file is missing' >&2; return 1;
    }
    case "$-" in *x*) restore_xtrace=1; set +x ;; esac
    password="$(cat "$HOME/ClaudeAsad/credentials/.terminaldeck-signing-pw")"
    if ! security unlock-keychain -p "$password" "$keychain" >/dev/null 2>&1; then
        unset password
        (( restore_xtrace == 0 )) || set -x
        echo 'Could not unlock Terminal Deck signing keychain' >&2
        return 1
    fi
    unset password
    (( restore_xtrace == 0 )) || set -x
    identities="$(security find-identity -v -p codesigning "$keychain")" || return 1
    rows="$(printf '%s\n' "$identities" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(Developer ID Application: .* (6U4VNX5W87)\)".*/\1|\2/p')"
    count="$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n+0 }')"
    [[ "$count" == 1 ]] || {
        echo 'Expected exactly one Terminal Deck Developer ID in its own keychain' >&2; return 1;
    }
    sha1="${rows%%|*}"; name="${rows#*|}"
    requested="$TD_SIGNING_SHA1"
    [[ "$requested" == "$sha1" ]] || {
        echo 'Requested Mac identity does not match the owned Developer ID SHA-1' >&2; return 1;
    }
    export TD_KEYCHAIN="$keychain" TD_SIGN_IDENTITY="$sha1" TD_MAC_SIGNING_SHA1="$sha1"
    TD_MAC_SIGNING_NAME="$name"
}
