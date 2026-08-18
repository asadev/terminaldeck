#!/usr/bin/env bash
#
# The localhost proof, against a real desktop, from one command.
#
#     ios/Harness/live-localhost.sh [--device "iPhone 17"] [--appearance light|dark]
#                                   [--shots <dir>] [--keep]
#
# It stands up the product's own headless host on the live relay, serves this
# repository's dev site on 3210, erases and boots a Simulator, pairs it, drives
# `LocalhostUITests`, and then exports every screenshot the run took.
#
# ## Which host, and why not `scripts/remote-host.sh`
#
# `remote-host.sh` is the obvious answer and it does not work, for a reason worth
# writing down because it looks like a crypto failure and is not one. **Six
# digits do not carry an address.** `Rendezvous.swift` derives a relay slot from
# the code and expects the machine showing it to be sitting in that slot; the
# thing that puts a machine there is `startBeacon` in
# `src/main/remote/machines/rendezvous.ts`, and `remote-host.ts` never calls it.
# It still prints a `terminaldeck://pair?…` link, which is the door a scanned QR
# came through and which the product removed — there is one way into the app now
# and it is six digits in a field. Measured on 2026-08-17: a code from that
# script, typed correctly, inside its sixty seconds, on the deployed relay,
# answers *"No machine is showing that code."*
#
# `ios/Harness/run.sh host` is worse for this particular suite, in the other
# direction: it is a stand-in that implements **no `ports` frame and no `tunnel`
# verb at all**, so a localhost run against it can only ever photograph an empty
# screen. An earlier localhost pass was reported as verified that way.
#
# So this uses `out/headless/host.mjs` — the same `createHostCore`,
# `registerRemoteIpc`, `scanDevPortsDetailed` and tunnel hub the window build
# links, with no window around it — and mints its codes through the same
# `machines:code` IPC the desktop's Pair button calls, beacon included. It is the
# same host `live-transfer.sh` uses and for the same two reasons: its pairing can
# be driven end to end, and it cannot disturb the copy of the app somebody is
# working in.
#
# ## Why HOME is a short path in /tmp
#
# Not a preference — a hard limit. The control socket is `$HOME/Library/
# Application Support/terminaldeck/host.sock`, and a Unix socket path is copied
# into a fixed 104-byte field. A HOME under the usual scratch directory makes
# that path 160 characters and the host refuses to start.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

DEVICE_NAME="iPhone 17"
APPEARANCE=""
KEEP=0
SHOTS_OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)     DEVICE_NAME="$2"; shift 2 ;;
        --appearance) APPEARANCE="$2"; shift 2 ;;
        --shots)      SHOTS_OUT="$2"; shift 2 ;;
        --keep)       KEEP=1; shift ;;
        *) echo "usage: live-localhost.sh [--device <name>] [--appearance light|dark]" \
                "[--shots <dir>] [--keep]" >&2; exit 2 ;;
    esac
done

TD_HOME=/private/tmp/tdlocal
STATE="$TD_HOME/Library/Application Support/terminaldeck"
PROOF="$TD_HOME/proof"
HARNESS="$repo/ios/Harness/run.sh"
# The one number, and it is the one `.harness/.devsite/server.mjs` binds and the
# one `LocalhostUITests` looks for. Every string that suite asserts on — "Served
# from the Mac", "HMR socket OPEN", "OK," — is printed by that page and by
# nothing else, so a port chosen independently of the thing that serves it is a
# suite that fails on a machine where everything works.
DEV_PORT=3210
[[ -n "$SHOTS_OUT" ]] || SHOTS_OUT="$PROOF/shots"

say() { printf '\n=== %s\n' "$*"; }

# --------------------------------------------------------------- the host ----

say "host: clearing $TD_HOME"
if [[ -S "$STATE/host.sock" ]]; then
    HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
    sleep 1
fi
rm -rf "$TD_HOME"
mkdir -p "$STATE" "$PROOF" "$SHOTS_OUT"

say "host: starting out/headless/host.mjs on the live relay"
HOME="$TD_HOME" node "$repo/out/headless/host.mjs" > "$PROOF/host.log" 2>&1 &
HOST_PID=$!
DEVSITE_PID=""
XCB_PID=""

cleanup() {
    if [[ "$KEEP" == "0" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        kill "$HOST_PID" 2>/dev/null || true
        kill "$DEVSITE_PID" 2>/dev/null || true
    fi
    kill "$XCB_PID" 2>/dev/null || true
    # xcodebuild outliving this script is not hypothetical: it holds the result
    # bundle open, and the next run dies on "Existing file at -resultBundlePath"
    # with a message that describes the phone and blames the wrong thing.
    pkill -f "xcodebuild test -project $repo/ios/TerminalDeck.xcodeproj" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for the relay and refuse to go on without it. A proof that quietly ran
# over loopback would be the stand-in again under another name.
for _ in $(seq 1 40); do
    if HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status 2>/dev/null \
        | grep -q "connected      wss://relay"; then
        break
    fi
    sleep 1
done
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status | sed -n '1,12p'
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status | grep -q "connected      wss://relay" || {
    echo "the host never reached the live relay; not running a proof over anything else" >&2
    exit 1
}

# ------------------------------------------------------------ the dev site ---

# Started only if nothing already holds the port. The page under test has to be
# *this* page — see DEV_PORT above — and quietly tunnelling somebody else's
# server would produce a run that fails on an assertion about missing text.
if lsof -nP -iTCP:"$DEV_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    say "dev site: something is already serving $DEV_PORT — leaving it alone"
else
    say "dev site: .harness/.devsite/server.mjs on 127.0.0.1:$DEV_PORT"
    node "$repo/.harness/.devsite/server.mjs" > "$PROOF/devsite.log" 2>&1 &
    DEVSITE_PID=$!
    sleep 1
fi
curl -fsS -o /dev/null "http://127.0.0.1:$DEV_PORT/" || {
    echo "nothing answered on 127.0.0.1:$DEV_PORT; there would be no page to tunnel" >&2
    exit 1
}

# --------------------------------------------------------- the simulator -----

say "simulator: erasing and booting $DEVICE_NAME"
# A UDID is accepted in place of a name, and on a Mac with two runtimes installed
# it is the only thing that is unambiguous: `iPhone 17` exists under both, the
# lookup below takes whichever the JSON lists first, and that is not necessarily
# the one somebody booted, installed to and is screenshotting. That cost an hour
# once — `ios/README.md` says so under the UI tests.
if [[ "$DEVICE_NAME" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    UDID="$DEVICE_NAME"
else
UDID="$(xcrun simctl list devices available -j \
    | python3 -c "import json,sys
devices = json.load(sys.stdin)['devices']
for runtime, entries in devices.items():
    for entry in entries:
        if entry['name'] == '$DEVICE_NAME' and 'iOS' in runtime:
            print(entry['udid']); raise SystemExit")"
fi
[[ -n "$UDID" ]] || { echo "no simulator called $DEVICE_NAME" >&2; exit 1; }
echo "  $UDID"

# Erased, not merely reinstalled. The pairing lives in the Simulator's keychain
# and survives an uninstall, so without this a run finds the phone still holding
# whichever host it met last — Connected, cheerful, and serving no ports.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# The appearance is set on the *simulator* rather than through the app's own
# picker, deliberately: the app's default is System, so this is the phone
# changing underneath it, which is the case somebody actually has.
if [[ -n "$APPEARANCE" ]]; then
    say "simulator: appearance $APPEARANCE"
    xcrun simctl ui "$UDID" appearance "$APPEARANCE"
fi

# ---------------------------------------------------------------- the run ----

READY="$PROOF/ready.txt"
CODE_FILE="$PROOF/pair-code.txt"
RESULT="$PROOF/result.xcresult"
rm -f "$READY" "$CODE_FILE"
rm -rf "$RESULT"

say "test: xcodebuild against $DEVICE_NAME"
# `TEST_RUNNER_…` in the **environment of xcodebuild**, never as arguments after
# it. Measured on Xcode 26.6: the argument form is parsed as a build setting,
# never reaches the runner's environment, and every case skips while the run
# reports "** TEST SUCCEEDED **" — a green run in which nothing was tested.
(
    TEST_RUNNER_TD_READY_FILE="$READY" \
    TEST_RUNNER_TD_CODE_FILE="$CODE_FILE" \
    xcodebuild test \
        -project "$repo/ios/TerminalDeck.xcodeproj" \
        -scheme TerminalDeck \
        -destination "platform=iOS Simulator,id=$UDID" \
        -only-testing:TerminalDeckUITests/LocalhostUITests \
        -derivedDataPath "$repo/ios/build/DerivedData" \
        -clonedSourcePackagesDirPath "$repo/ios/build/SourcePackages" \
        -resultBundlePath "$RESULT" \
        > "$PROOF/xcodebuild.log" 2>&1
    echo $? > "$PROOF/xcodebuild.status"
) &
XCB_PID=$!

# The phone says when it is standing at the pairing screen; the code is minted
# only then. A code is good for sixty seconds and a Simulator takes longer than
# that to build, install and launch.
say "pairing: waiting for the phone to reach the pairing screen"
for _ in $(seq 1 900); do
    [[ -f "$READY" ]] && break
    kill -0 "$XCB_PID" 2>/dev/null || {
        echo "  xcodebuild stopped early:"; tail -5 "$PROOF/xcodebuild.log"; break
    }
    sleep 1
done

if [[ -f "$READY" ]]; then
    CODE="$("$HARNESS" live pair --state "$STATE" --out "$CODE_FILE" | tail -1)"
    echo "  $CODE"
    say "pairing: approving the device the way pressing Approve does"
    # Not fatal: a run that got this far has still produced a log and a result
    # bundle, and the evidence section below is where a failure gets said out
    # loud rather than swallowed by an early exit.
    "$HARNESS" live approve --state "$STATE" --wait 180000 || true
else
    say "pairing: the phone never asked for a code (already paired, or it never started)"
fi

wait "$XCB_PID" || true
STATUS="$(cat "$PROOF/xcodebuild.status" 2>/dev/null || echo "?")"

# --------------------------------------------------------------- evidence ----

say "screenshots"
# Exported rather than written from inside the test: the cases already attach
# every frame they take, and a second mechanism writing PNGs would be one more
# thing to keep in step with the first.
if [[ -d "$RESULT" ]]; then
    rm -rf "${SHOTS_OUT:?}/"*
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS_OUT" \
        >/dev/null 2>&1 || true
    find "$SHOTS_OUT" -name '*.png' | sed 's/^/  /'
fi

say "RESULT"
echo "xcodebuild exit: $STATUS"
grep -E "Test Case .*(passed|failed|skipped)" "$PROOF/xcodebuild.log" | sed 's/^/  /' || true
echo
echo "  host log        $PROOF/host.log"
echo "  xcodebuild log  $PROOF/xcodebuild.log"
echo "  screenshots     $SHOTS_OUT"
exit "${STATUS:-1}"
