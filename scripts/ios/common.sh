#!/usr/bin/env bash
#
# Shared ground for `preflight.sh` and `release.sh`: the constants that identify
# this app to Apple, the credential lookup, the version arithmetic, and the
# reporting vocabulary both scripts speak.
#
# Sourced, never executed.
#
# ## The vocabulary, because it is the point of the whole exercise
#
# Three outcomes, not two:
#
#   pass     — checked, and it is fine.
#   fail     — checked, it is broken, and it is broken for a reason someone
#              here can fix. Exits non-zero.
#   blocked  — checked, it cannot succeed yet, and the thing it is waiting on is
#              a credential or an approval nobody in this repository can supply.
#              Does not exit non-zero, because "waiting on Apple" is not a bug
#              in the pipeline and a red build every morning teaches people to
#              ignore red builds.
#
# A `blocked` always names what it is waiting for and what will clear it. If it
# cannot, it is a `fail` pretending to be patient.

set -euo pipefail

# ---------------------------------------------------------------- identities

# The Apple Developer team this app is published under. "Asad Iqbal",
# individual account.
readonly TEAM_ID="6U4VNX5W87"

# The App ID. `dev.terminaldeck` is the reverse of terminaldeck.dev, which is
# owned; `.ios` distinguishes the phone client from the desktop app, which will
# want `dev.terminaldeck.mac` on the day it is signed.
readonly BUNDLE_ID="dev.terminaldeck.ios"

# The name on the App Store listing. Checked as available before it was chosen.
readonly APP_NAME="Terminal Deck"

readonly SCHEME="TerminalDeck"

# The App Store Connect API key. The key *identifier* is not a secret — it is
# printed in the App Store Connect UI next to the key and is half of what
# names the file. The private key it points at is the secret, and it lives
# outside this repository and is never read by anything here except `xcodebuild`
# and `altool`.
readonly DEFAULT_ASC_KEY_ID="999LNRXQS2"

# ------------------------------------------------------------------ location

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT
readonly IOS_DIR="$REPO_ROOT/ios"
readonly XCODEPROJ="$IOS_DIR/$SCHEME.xcodeproj"
readonly ICON_PNG="$IOS_DIR/TerminalDeck/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
readonly EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

# Everything the build writes goes under `ios/build`, which `ios/.gitignore`
# already excludes wholesale.
readonly BUILD_DIR="$IOS_DIR/build"
readonly RELEASE_DIR="$BUILD_DIR/release"
readonly DERIVED_DATA="$BUILD_DIR/DerivedData"
readonly SOURCE_PACKAGES="$BUILD_DIR/SourcePackages"

# --------------------------------------------------------------- vocabulary

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_RED=''; C_YELLOW=''
fi

FAILURES=0
BLOCKERS=0
declare -a BLOCKER_NOTES=()

heading() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
pass()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
detail()  { printf '      %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

fail() {
    printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"
    shift
    for line in "$@"; do detail "$line"; done
    FAILURES=$((FAILURES + 1))
}

blocked() {
    printf '  %s—%s %s %s(blocked)%s\n' "$C_YELLOW" "$C_RESET" "$1" "$C_YELLOW" "$C_RESET"
    local summary="$1"
    shift
    for line in "$@"; do detail "$line"; done
    BLOCKERS=$((BLOCKERS + 1))
    BLOCKER_NOTES+=("$summary")
}

# Not a check result — the script itself cannot continue.
die() {
    printf '\n%s%serror:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    shift
    for line in "$@"; do printf '  %s\n' "$line" >&2; done
    exit 1
}

# ------------------------------------------------------------- prerequisites

have() { command -v "$1" >/dev/null 2>&1; }

require_macos() {
    [[ "$(uname -s)" == "Darwin" ]] ||
        die "iOS releases can only be built on macOS." "This is $(uname -s)."
}

# ---------------------------------------------------------------- credential

# Where the private key is. Overridable so a CI runner can put it somewhere
# else; defaulted to the directory `altool` searches anyway.
asc_key_id() { printf '%s' "${ASC_KEY_ID:-$DEFAULT_ASC_KEY_ID}"; }
asc_key_path() { printf '%s' "${ASC_KEY_PATH:-$HOME/private_keys/AuthKey_$(asc_key_id).p8}"; }

# The one piece of the puzzle that cannot be derived, guessed, or found on this
# machine: the issuer id. It is per-account, it is a UUID, it is printed in
# exactly one place on the web, and inventing one produces a 401 twenty minutes
# into a release rather than an error here.
#
# Read from $ASC_ISSUER_ID, or from a file named by $ASC_ISSUER_ID_FILE, or from
# `issuer_id.txt` sitting next to the private key — which is a sensible home for
# it because that directory is already outside the repository and already holds
# the other half of the same credential.
readonly ISSUER_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

asc_issuer_id() {
    local value="${ASC_ISSUER_ID:-}"
    if [[ -z "$value" ]]; then
        local file="${ASC_ISSUER_ID_FILE:-$(dirname "$(asc_key_path)")/issuer_id.txt}"
        if [[ -r "$file" ]]; then
            value="$(tr -d '[:space:]' < "$file")"
        fi
    fi
    printf '%s' "$value"
}

issuer_id_help() {
    cat <<'HELP'
Where to get it — it is not a secret you can regenerate, it is an identifier you
read off the page, and it is the same one forever:

  1. https://appstoreconnect.apple.com/access/integrations/api
     (App Store Connect > Users and Access > Integrations tab >
      App Store Connect API, in the left sidebar)
  2. Above the table of keys there is a line reading "Issuer ID" followed by a
     UUID like 69a6de70-1234-47e3-e053-5b8c7c11a4d1. That is it. Copy it.
  3. It is NOT the Key ID. The Key ID is the ten-character code in the table
     itself (this project's is in scripts/ios/common.sh) and is already known.

Then either:

    export ASC_ISSUER_ID=<the-uuid>

or, so it survives the next terminal:

    echo '<the-uuid>' > ~/private_keys/issuer_id.txt && chmod 600 ~/private_keys/issuer_id.txt
HELP
}

# Fatal version, for release.sh: no issuer id, no release, and the message has
# to be the one that ends the search rather than starts it.
require_issuer_id() {
    local issuer
    issuer="$(asc_issuer_id)"

    if [[ -z "$issuer" ]]; then
        printf '\n%s%serror: ASC_ISSUER_ID is not set, and nothing can be uploaded without it.%s\n\n' \
            "$C_BOLD" "$C_RED" "$C_RESET" >&2
        issuer_id_help >&2
        printf '\n' >&2
        exit 1
    fi

    if [[ ! "$issuer" =~ $ISSUER_UUID_RE ]]; then
        printf '\n%s%serror: ASC_ISSUER_ID is set but is not a UUID.%s\n' \
            "$C_BOLD" "$C_RED" "$C_RESET" >&2
        printf '  got: %s\n' "$issuer" >&2
        printf '  expected 8-4-4-4-12 hex, e.g. 69a6de70-1234-47e3-e053-5b8c7c11a4d1\n\n' >&2
        printf '  A ten-character value here is the Key ID, which is a different thing.\n\n' >&2
        issuer_id_help >&2
        printf '\n' >&2
        exit 1
    fi

    printf '%s' "$issuer"
}

# ------------------------------------------------------------------ versions

# The marketing version is package.json's, because the phone app and the
# desktop app are one product with one version number and two binaries.
package_version() {
    node -p "require('$REPO_ROOT/package.json').version"
}

marketing_version() {
    printf '%s' "${TD_IOS_MARKETING_VERSION:-$(package_version)}"
}

# The build number, which is a different thing from the version and has one
# job: be larger than every build number already uploaded under this marketing
# version. App Store Connect rejects a repeat outright, and it does so after
# the upload, which is the expensive place to find out.
#
# UTC minutes since the epoch would be opaque; a git commit count goes backwards
# on a rebase; a counter in a file is state that one machine has and the next
# one does not. `yymmddHHMM` is monotonic without coordination, readable as a
# date when it turns up in a crash report, and fits in the unsigned 32-bit
# integer App Store Connect stores it in until 2042.
build_number() {
    printf '%s' "${TD_IOS_BUILD:-$(date -u +%y%m%d%H%M)}"
}
