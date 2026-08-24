#!/usr/bin/env bash
#
# **The install-on-a-server flow, against a real server.**
#
#     ios/Harness/live-server.sh --case <name> --host <addr> --user <account> \
#         --key ~/.ssh/id_ed25519 [--port 22] [options]
#
# ## Why this exists
#
# `ServerLoginUITests` takes a real server out of its environment and skips when
# it has none, which is this target's standing rule — and every one of those
# variables has to arrive by a route that is easy to get wrong. They go in the
# environment of `xcodebuild`, each prefixed `TEST_RUNNER_`, which is how the
# UI-test *runner* is given anything at all. Put them after `xcodebuild` and they
# are parsed as build settings, never reach the runner, and every case skips
# itself while the run reports "** TEST SUCCEEDED **" — measured on Xcode 26.6,
# and the reason this file is one command rather than a paragraph in a document.
#
# ## What it changes, and what it refuses to
#
# Nothing, unless asked. `--may-install` puts the headless host into that
# account's home folder on the far end; `--may-connect` pairs this simulator with
# it and unpairs again. Without those flags the walk logs in, looks and
# photographs, because the machine on the other end is somebody's.
#
# ## The wrong key
#
# `--wrong-key` generates a throwaway Ed25519 key in the run's own folder and
# hands it to the refusal case. It is a *valid* key that this account has never
# heard of, which is the failure worth checking: a malformed one is refused by
# the phone before a packet is sent, and proves nothing about the server.
#
# The frames land in `--out` (default `/tmp/td-server-proof/<case>`), taken from
# the result bundle rather than from inside the simulator's sandbox.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

CASES=()
HOST=""
PORT=""
USER_NAME=""
KEY=""
PASSWORD=""
OUT=""
DEVICE_NAME="TD-server-proof"
MAY_INSTALL=0
HAS_HOST=0
MAY_CONNECT=0
WRONG_KEY=0
WRONG_PORT=""
HOST_PACKAGE=""
FRESH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        # Repeatable. Several cases in one invocation share the app install,
        # which on a loaded machine is most of the wall clock; XCTest runs them
        # in alphabetical order within the class, and the names are chosen so
        # that order is a sane one — the two refusals change nothing, then the
        # host is brought up, then the connection is cycled.
        --case)         CASES+=("$2"); shift 2 ;;
        --host)         HOST="$2"; shift 2 ;;
        --port)         PORT="$2"; shift 2 ;;
        --user)         USER_NAME="$2"; shift 2 ;;
        --key)          KEY="$2"; shift 2 ;;
        --password)     PASSWORD="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        --device)       DEVICE_NAME="$2"; shift 2 ;;
        --may-install)  MAY_INSTALL=1; shift ;;
        --has-host)     HAS_HOST=1; shift ;;
        --may-connect)  MAY_CONNECT=1; shift ;;
        --wrong-key)    WRONG_KEY=1; shift ;;
        --wrong-port)   WRONG_PORT="$2"; shift 2 ;;
        # A host build being tried before it is published: anything npm takes,
        # including a path on the far end. Debug builds only.
        --host-package) HOST_PACKAGE="$2"; shift 2 ;;
        --fresh)        FRESH=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ ${#CASES[@]} -gt 0 ]] || { echo "--case is required" >&2; exit 2; }
[[ -n "$HOST" ]] || { echo "--host is required" >&2; exit 2; }
[[ -n "$USER_NAME" ]] || { echo "--user is required" >&2; exit 2; }
OUT="${OUT:-/tmp/td-server-proof/${CASES[0]}}"

say() { printf '\n=== %s\n' "$*"; }

rm -rf "$OUT"
mkdir -p "$OUT"

# ------------------------------------------------------------- the phone ----

UDID="$(xcrun simctl list devices -j | python3 -c "
import json, sys
for runtime, entries in json.load(sys.stdin)['devices'].items():
    for entry in entries:
        if entry['name'] == '$DEVICE_NAME' and entry.get('isAvailable'):
            print(entry['udid']); raise SystemExit
")"
[[ -n "$UDID" ]] || { echo "no simulator called $DEVICE_NAME — create one first" >&2; exit 1; }

say "phone: $DEVICE_NAME $UDID"
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
if [[ "$FRESH" == "1" ]]; then
    echo "  erasing — this case is about a phone with nothing on it"
    xcrun simctl erase "$UDID"
fi
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# ------------------------------------------------------- what it is given ----

env_args=(
    TEST_RUNNER_TD_SERVER_ADDRESS="$HOST"
    TEST_RUNNER_TD_SERVER_PORT="$PORT"
    TEST_RUNNER_TD_SERVER_USER="$USER_NAME"
    TEST_RUNNER_TD_SERVER_PASSWORD="$PASSWORD"
    TEST_RUNNER_TD_SHOTS="$OUT/from-app"
    TEST_RUNNER_TD_SERVER_HOST_PACKAGE="$HOST_PACKAGE"
)
if [[ -n "$KEY" ]]; then
    env_args+=( TEST_RUNNER_TD_SERVER_KEY_BASE64="$(base64 < "$KEY" | tr -d '\n')" )
fi
[[ "$MAY_INSTALL" == "1" ]] && env_args+=( TEST_RUNNER_TD_SERVER_MAY_INSTALL=1 )
[[ "$HAS_HOST"    == "1" ]] && env_args+=( TEST_RUNNER_TD_SERVER_HAS_HOST=1 )
[[ "$MAY_CONNECT" == "1" ]] && env_args+=( TEST_RUNNER_TD_SERVER_MAY_CONNECT=1 )
[[ -n "$WRONG_PORT" ]]     && env_args+=( TEST_RUNNER_TD_SERVER_WRONG_PORT="$WRONG_PORT" )
if [[ "$WRONG_KEY" == "1" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'a key this account has never heard of' \
        -f "$OUT/never-added" </dev/null
    env_args+=( TEST_RUNNER_TD_SERVER_WRONG_KEY_BASE64="$(base64 < "$OUT/never-added" | tr -d '\n')" )
fi

# ---------------------------------------------------------------- the run ----

only=()
for one in "${CASES[@]}"; do
    only+=( -only-testing:"TerminalDeckUITests/ServerLoginUITests/$one" )
done

say "test: ${CASES[*]} against $USER_NAME@$HOST${PORT:+:$PORT}"
set +e
env "${env_args[@]}" \
    xcodebuild test-without-building \
        -project "$repo/ios/TerminalDeck.xcodeproj" \
        -scheme TerminalDeck \
        -destination "platform=iOS Simulator,id=$UDID" \
        "${only[@]}" \
        -derivedDataPath "$repo/ios/build/DerivedData" \
        -clonedSourcePackagesDirPath "$repo/ios/build/SourcePackages" \
        -resultBundlePath "$OUT/result.xcresult" \
        > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
set -e

# ------------------------------------------------------------- the frames ----
#
# Out of the result bundle, not out of the simulator. `TD_SHOTS` is a path on
# *this* Mac handed to a process inside the simulator, and whether that write
# lands is a property of the sandbox rather than of the test — the attachments
# are the copy that always exists.
say "frames"
mkdir -p "$OUT/shots"
xcrun xcresulttool export attachments \
    --path "$OUT/result.xcresult" --output-path "$OUT/shots" >/dev/null 2>&1 || true
python3 - "$OUT/shots" <<'PY' || true
# The bundle carries far more than the frames this walk asked for: a screen
# recording, every synthesized tap, a UI hierarchy dump per failure. Those are
# kept — they are the good evidence when something goes wrong — but they are put
# aside, because a folder where `shoot("live-07-connected")` sits between eighty
# machine-generated files is a folder nobody looks at. Only real PNGs are
# renamed, and only to the name the test gave them: an earlier version appended
# `.png` to the hierarchy dumps and made three text files unreadable.
import json, os, shutil, sys

folder = sys.argv[1]
manifest = os.path.join(folder, "manifest.json")
if not os.path.exists(manifest):
    raise SystemExit
aside = os.path.join(folder, "machine-generated")
os.makedirs(aside, exist_ok=True)


def is_png(path):
    with open(path, "rb") as handle:
        return handle.read(8) == b"\x89PNG\r\n\x1a\n"


for test in json.load(open(manifest)):
    for item in test.get("attachments", []):
        source = os.path.join(folder, item["exportedFileName"])
        if not os.path.exists(source):
            continue
        asked = item.get("suggestedHumanReadableName") or ""
        # A name this walk chose: no extension, no timestamp, and a real PNG.
        if asked and "." not in asked and is_png(source):
            shutil.move(source, os.path.join(folder, asked + ".png"))
        else:
            shutil.move(source, os.path.join(aside, os.path.basename(source)))
PY
ls -1 "$OUT/shots"/*.png 2>/dev/null | sed 's|^|  |' || echo "  none"

say "RESULT: ${CASES[*]}"
grep -E "Test Case .* (passed|failed)|error:|XCTAssert|\*\* TEST" "$OUT/xcodebuild.log" \
    | tail -20 || true
echo "xcodebuild exit: $STATUS"
exit "$STATUS"
