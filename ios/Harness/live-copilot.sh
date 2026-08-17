#!/usr/bin/env bash
#
# The copilot screens, walked on a Simulator against the product's own desktop.
#
#     ios/Harness/live-copilot.sh [--device "iPhone 17"] [--keep]
#
# ## Why this is not `run.sh host`
#
# The stand-in next door sends the desktop's whole `CAPABILITIES` list verbatim
# and implements a handful of it, so it advertises `copilot` and answers no
# `copilot.*` frame. Driving the copilot screens against it would photograph an
# empty screen and call the feature verified — which is what happened to an
# earlier localhost pass, and is why `ReleaseShotsUITests` carries the same
# warning. So this stands up `out/headless/host.mjs`: the same
# `registerRemoteIpc`, `PtyManager`, folder grants and sealed channel the window
# build links, on the deployed relay.
#
# ## What it can prove today, and what it cannot
#
# `CopilotRuns` is not injected into the remote server by `createHostCore` yet —
# that is the desktop half of this feature and it is being built alongside. So a
# real desktop advertises no copilot, and what this run proves is the *honest
# degradation*: a phone carrying the copilot build shows nothing about one, keeps
# its three tabs, and does not offer to send anybody looking for a switch that
# machine does not have. When the desktop half lands, the same command walks the
# rest of the screens with no change here.
#
# ## HOME
#
# Its own, in /private/tmp, for `live-transfer.sh`'s two reasons: the packaged
# app is running on this Mac with Asad's own state and relay identity, and two
# hosts claiming one name at the rendezvous means a phone reaches whichever
# answered first; and the control socket path is copied into a fixed 104-byte
# field, which a HOME under the usual scratch directory overflows.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

DEVICE_NAME="iPhone 17"
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE_NAME="$2"; shift 2 ;;
        --keep)   KEEP=1; shift ;;
        *) echo "usage: live-copilot.sh [--device <name>] [--keep]" >&2; exit 2 ;;
    esac
done

TD_HOME=/private/tmp/tdcopilot
STATE="$TD_HOME/Library/Application Support/terminaldeck"
WORK="$TD_HOME/work"
PROOF="$TD_HOME/proof"
SHOTS="$PROOF/shots"
HARNESS="$repo/ios/Harness/run.sh"

say() { printf '\n=== %s\n' "$*"; }

# --------------------------------------------------------------- the host ----

say "host: clearing $TD_HOME"
if [[ -S "$STATE/host.sock" ]]; then
    HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
    sleep 1
fi
rm -rf "$TD_HOME"
mkdir -p "$STATE" "$WORK" "$SHOTS"

# A plain shell rather than whatever this Mac's default provider is: nothing here
# types into a session, and starting a Claude CLI per session would spend money
# to photograph a tab bar.
cat > "$STATE/state.json" <<'JSON'
{
  "version": 1,
  "projects": [],
  "preferences": {
    "theme": "dark",
    "defaultProvider": "shell",
    "restoreSessions": true,
    "notifyOnComplete": true
  },
  "openSessions": []
}
JSON

say "host: starting out/headless/host.mjs on the live relay"
HOME="$TD_HOME" node "$repo/out/headless/host.mjs" > "$PROOF/host.log" 2>&1 &
HOST_PID=$!
XCB_PID=""

cleanup() {
    if [[ "$KEEP" == "0" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        kill "$HOST_PID" 2>/dev/null || true
    fi
    kill "$XCB_PID" 2>/dev/null || true
    pkill -f "xcodebuild test -project $repo/ios/TerminalDeck.xcodeproj" 2>/dev/null || true
}
trap cleanup EXIT

# The relay, or nothing. A run that quietly fell back to loopback would be the
# stand-in again under another name.
for _ in $(seq 1 40); do
    if HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status 2>/dev/null | grep -q "connected      wss://relay"; then
        break
    fi
    sleep 1
done
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status | sed -n '1,12p'
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status | grep -q "connected      wss://relay" || {
    echo "the host never reached the live relay; not running a proof over anything else" >&2
    exit 1
}

# What the host says about itself, kept beside the frames. The claim this run
# makes is "a real desktop offers no copilot yet", and the evidence for it is
# this file rather than the phone's own screen.
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status > "$PROOF/host-status.txt" 2>&1 || true

# --------------------------------------------------------- the simulator -----

say "simulator: erasing and booting $DEVICE_NAME"
UDID="$(xcrun simctl list devices available -j \
    | python3 -c "import json,sys
devices = json.load(sys.stdin)['devices']
for runtime, entries in devices.items():
    for entry in entries:
        if entry['name'] == '$DEVICE_NAME' and 'iOS' in runtime:
            print(entry['udid']); raise SystemExit")"
[[ -n "$UDID" ]] || { echo "no simulator called $DEVICE_NAME" >&2; exit 1; }
echo "  $UDID"

# Erased, not merely reinstalled: the pairing lives in the Simulator's keychain
# and survives an uninstall, so without this the first run pairs and every run
# after it proves nothing about the pairing screen.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# ---------------------------------------------------------------- the run ----

READY="$PROOF/ready.txt"
CODE_FILE="$PROOF/pair-code.txt"
rm -f "$READY" "$CODE_FILE"
rm -rf "$PROOF/result.xcresult"

say "test: xcodebuild against $DEVICE_NAME"
# `TEST_RUNNER_…` in the **environment of xcodebuild**, never as build settings
# after it. Measured on this toolchain, the build-setting form reaches the runner
# as nothing at all, every case skips, and the run reports success — which is the
# one outcome this whole workstream exists to eliminate. `live-transfer.sh`
# records the measurement in full.
(
    TEST_RUNNER_TD_READY_FILE="$READY" \
    TEST_RUNNER_TD_CODE_FILE="$CODE_FILE" \
    TEST_RUNNER_TD_SHOTS="$SHOTS" \
    xcodebuild test \
        -project "$repo/ios/TerminalDeck.xcodeproj" \
        -scheme TerminalDeck \
        -destination "platform=iOS Simulator,id=$UDID" \
        -only-testing:TerminalDeckUITests/LiveCopilotUITests \
        -derivedDataPath "$repo/ios/build/DerivedData" \
        -resultBundlePath "$PROOF/result.xcresult" \
        > "$PROOF/xcodebuild.log" 2>&1
    echo $? > "$PROOF/xcodebuild.status"
) &
XCB_PID=$!

say "pairing: waiting for the phone to reach the pairing screen"
for _ in $(seq 1 900); do
    [[ -f "$READY" ]] && break
    kill -0 "$XCB_PID" 2>/dev/null || { echo "  xcodebuild stopped early:"; tail -5 "$PROOF/xcodebuild.log"; break; }
    sleep 1
done

if [[ -f "$READY" ]]; then
    CODE="$("$HARNESS" live pair --state "$STATE" --out "$CODE_FILE" | tail -1)"
    echo "  $CODE"
    say "pairing: approving the device the way pressing Approve does"
    "$HARNESS" live approve --state "$STATE" --wait 180000 || true
else
    say "pairing: the phone never asked for a code (already paired, or it never started)"
fi

say "grant: giving the device one folder to work in"
"$HARNESS" live folder --state "$STATE" --path "$WORK" || true

wait "$XCB_PID" || true
STATUS="$(cat "$PROOF/xcodebuild.status" 2>/dev/null || echo "?")"

# --------------------------------------------------------------- evidence ----

say "RESULT"
echo "xcodebuild exit: $STATUS"
grep -E "Test Case .* (passed|failed)|Testing failed|\*\* TEST" "$PROOF/xcodebuild.log" | tail -20 || true
echo
echo "frames:  $SHOTS"
ls -1 "$SHOTS" 2>/dev/null || echo "  none"
echo "host:    $PROOF/host.log"
echo "status:  $PROOF/host-status.txt"
