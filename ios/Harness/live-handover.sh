#!/usr/bin/env bash
#
# **The handover proof, from one command.**
#
#     ios/Harness/live-handover.sh [--device "TD-handover"] [--keep] [--shots <dir>]
#
# It stands up the product's own headless host with a **real Chromium** in it, on
# a relay of its own on loopback, serves a real login page, erases and boots a
# simulator, pairs it, and drives `HandoverUITests` — which is an agent hitting a
# login wall, a person on the phone taking the page, typing into it, and handing
# it back.
#
# Nothing here touches the copy of the app anybody is using. The host runs under
# `HOME=/private/tmp/tdho` with a state directory, a browser profile, a relay
# port and a page port of its own; the simulator is a device of its own.
#
# ## Which host, and why not `scripts/remote-host.sh`
#
# Because that one has **no browser at all**, so it cannot carry a handover. The
# piece that can is `out/headless/host.mjs`: `HeadlessDriveHost` launches a real
# Chromium, `screencastOver` casts it, and `announceDriveState` in
# `src/headless/host.ts` is what tells a watching phone that a question has been
# asked about the page it is looking at.
#
# ## Why HOME is a short path in /tmp
#
# Not a preference — a hard limit. The control socket is `$HOME/Library/
# Application Support/terminaldeck/host.sock`, and a Unix socket path is copied
# into a fixed 104-byte field. A HOME under the usual scratch directory makes
# that path 160 characters and the host refuses to start.
#
# ## The one thing that leaves this Mac
#
# A rendezvous slot named by six digits, for sixty seconds, holding an address
# that reads `ws://127.0.0.1`. The phone has no relay setting — see
# `live-handover.ts`'s header — so a code is always *looked up* at
# `relay.terminaldeck.dev`, and what it answers with points back here. The
# session itself, the page, the frames and the keystrokes never leave loopback.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

DEVICE_NAME="TD-handover"
KEEP=0
SHOTS_OUT=""
RELAY_PORT=8877
PAGE_PORT=8879
# The browser the host drives, and why it is side-loaded rather than installed.
#
# `terminaldeck browser install` refuses on macOS — the chrome-for-testing mac
# zip contains a symbolic link and the hardened unpacker (which is shared with
# the extension store) does not unpack one. That is the host's own answer and it
# is the right one for a server; here it means the binary is unpacked by hand,
# once, with the system `unzip`:
#
#   curl -sSL -o /private/tmp/tdbrowser/chrome.zip \
#     https://storage.googleapis.com/chrome-for-testing-public/146.0.7680.165/mac-arm64/chrome-mac-arm64.zip
#   shasum -a 256 …   # must equal PINNED_CHROMIUM_SHA256['mac-arm64']
#   unzip -q -o chrome.zip -d /private/tmp/tdbrowser
#
# **Not** `/Applications/Google Chrome.app`: launching his own Chrome binary
# wakes GoogleUpdater under his home directory, and updating the browser
# somebody is working in is not a thing a test may do. `TERMINALDECK_CHROMIUM_PATH`
# is the product's supported side-load, so nothing is bypassed.
CFT="/private/tmp/tdbrowser/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
CHROMIUM="${TERMINALDECK_CHROMIUM_PATH:-$CFT}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)     DEVICE_NAME="$2"; shift 2 ;;
        --shots)      SHOTS_OUT="$2"; shift 2 ;;
        --relay-port) RELAY_PORT="$2"; shift 2 ;;
        --page-port)  PAGE_PORT="$2"; shift 2 ;;
        --chromium)   CHROMIUM="$2"; shift 2 ;;
        --keep)       KEEP=1; shift ;;
        *) echo "usage: live-handover.sh [--device <name>] [--shots <dir>] [--keep]" >&2; exit 2 ;;
    esac
done

TD_HOME=/private/tmp/tdho
STATE="$TD_HOME/Library/Application Support/terminaldeck"
PROOF="$TD_HOME/proof"
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

# The folder a session may be started in. The repository itself, read-only in
# practice: nothing in this proof types into that shell.
GRANT="$repo"

say "mac side: relay on 127.0.0.1:$RELAY_PORT, login page on 127.0.0.1:$PAGE_PORT"
"$here/run.sh" handover \
    --state "$STATE" --proof "$PROOF" --folder "$GRANT" \
    --relay-port "$RELAY_PORT" --page-port "$PAGE_PORT" \
    > "$PROOF/mac-side.log" 2>&1 &
MAC_PID=$!
HOST_PID=""
XCB_PID=""

cleanup() {
    if [[ "$KEEP" == "0" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        [[ -n "$HOST_PID" ]] && kill "$HOST_PID" 2>/dev/null || true
    fi
    kill "$MAC_PID" 2>/dev/null || true
    kill "$XCB_PID" 2>/dev/null || true
    # xcodebuild outliving this script is not hypothetical: it holds the result
    # bundle open and the next run dies on "Existing file at -resultBundlePath".
    pkill -f "xcodebuild test -project $repo/ios/TerminalDeck.xcodeproj" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 60); do
    [[ -f "$PROOF/cues/relay-up" ]] && break
    kill -0 "$MAC_PID" 2>/dev/null || { echo "the Mac side stopped early:"; tail -20 "$PROOF/mac-side.log"; exit 1; }
    sleep 1
done
[[ -f "$PROOF/cues/relay-up" ]] || { echo "no relay came up"; tail -20 "$PROOF/mac-side.log"; exit 1; }

say "host: out/headless/host.mjs, on ws://127.0.0.1:$RELAY_PORT"
if [[ ! -x "$CHROMIUM" ]]; then
    echo "  no browser at $CHROMIUM — the host will fetch its own pinned Chromium on first drive"
    CHROMIUM=""
else
    echo "  browser  $CHROMIUM"
fi
# Exported rather than written as a `${VAR:+NAME="$VAR"}` prefix: the path has
# spaces in it (`Google Chrome for Testing.app`), and that form word-splits into
# "no such file or directory" naming the whole assignment.
[[ -n "$CHROMIUM" ]] && export TERMINALDECK_CHROMIUM_PATH="$CHROMIUM"
HOME="$TD_HOME" \
TERMINALDECK_RELAY_URL="ws://127.0.0.1:$RELAY_PORT" \
    node "$repo/out/headless/host.mjs" > "$PROOF/host.log" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 90); do
    [[ -f "$PROOF/cues/host-up" ]] && break
    kill -0 "$HOST_PID" 2>/dev/null || { echo "the host stopped early:"; tail -20 "$PROOF/host.log"; exit 1; }
    sleep 1
done
[[ -f "$PROOF/cues/host-up" ]] || {
    echo "the host never reached the loopback relay"; tail -20 "$PROOF/host.log"; tail -20 "$PROOF/mac-side.log"; exit 1
}
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status | sed -n '1,10p' || true

# ---------------------------------------------------------- the simulator ----

UDID="$(xcrun simctl list devices -j | python3 -c "
import json, sys
for runtime, entries in json.load(sys.stdin)['devices'].items():
    if 'iOS' not in runtime: continue
    for entry in entries:
        if entry['name'] == '$DEVICE_NAME' and entry.get('isAvailable'):
            print(entry['udid']); raise SystemExit
")"
if [[ -z "$UDID" ]]; then
    say "simulator: creating $DEVICE_NAME"
    RUNTIME="$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
runtimes = [r for r in json.load(sys.stdin)['runtimes'] if r['isAvailable'] and 'iOS' in r['name']]
print(sorted(runtimes, key=lambda r: r['version'])[-1]['identifier'])")"
    UDID="$(xcrun simctl create "$DEVICE_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")"
fi
say "simulator: erasing and booting $DEVICE_NAME"
echo "  $UDID"
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
# Erased, not merely reinstalled: a pairing lives in the simulator's keychain and
# survives an uninstall, so without this a run finds the phone still holding
# whichever host it met last.
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# ---------------------------------------------------------------- the run ----

CODE_FILE="$PROOF/pair-code.txt"
RESULT="$PROOF/result.xcresult"
MARKER="$(cat "$PROOF/marker.txt")"
rm -rf "$RESULT"

say "test: HandoverUITests against $DEVICE_NAME (marker $MARKER)"
# `TEST_RUNNER_…` in the **environment of xcodebuild**, never as arguments after
# it. Measured on Xcode 26.6: the argument form is parsed as a build setting,
# never reaches the runner's environment, and every case skips while the run
# reports "** TEST SUCCEEDED **" — a green run in which nothing was tested.
(
    TEST_RUNNER_TD_PROOF="$PROOF" \
    TEST_RUNNER_TD_CODE_FILE="$CODE_FILE" \
    TEST_RUNNER_TD_MARKER="$MARKER" \
    TEST_RUNNER_TD_SHOTS="$SHOTS_OUT" \
    xcodebuild test \
        -project "$repo/ios/TerminalDeck.xcodeproj" \
        -scheme TerminalDeck \
        -destination "platform=iOS Simulator,id=$UDID" \
        -only-testing:TerminalDeckUITests/HandoverUITests \
        -derivedDataPath "$repo/ios/build/DerivedData" \
        -clonedSourcePackagesDirPath "$repo/ios/build/SourcePackages" \
        -resultBundlePath "$RESULT" \
        > "$PROOF/xcodebuild.log" 2>&1
    echo $? > "$PROOF/xcodebuild.status"
) &
XCB_PID=$!

# Both halves are running now and talk to each other through $PROOF. This waits
# on the build rather than on a stage, because every stage is the Mac side's to
# drive and it is already doing it.
while kill -0 "$XCB_PID" 2>/dev/null; do
    sleep 5
done
wait "$XCB_PID" || true
STATUS="$(cat "$PROOF/xcodebuild.status" 2>/dev/null || echo "?")"

# --------------------------------------------------------------- evidence ----

say "screenshots"
if [[ -d "$RESULT" ]]; then
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS_OUT" \
        >/dev/null 2>&1 || true
    python3 - "$SHOTS_OUT" <<'PY' || true
# The bundle carries far more than the frames this walk asked for — a screen
# recording, every synthesized tap, a UI hierarchy dump per failure. Those are
# kept and put aside, so the folder a person opens is the twelve pictures.
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
        if asked and "." not in asked and is_png(source):
            shutil.move(source, os.path.join(folder, asked + ".png"))
        else:
            shutil.move(source, os.path.join(aside, os.path.basename(source)))
PY
fi
ls -1 "$SHOTS_OUT"/*.png 2>/dev/null | sed 's|^|  |' || echo "  none"

say "what the Mac saw"
sed -n '1,200p' "$PROOF/evidence.jsonl" 2>/dev/null || echo "  nothing"

say "RESULT"
echo "xcodebuild exit: $STATUS"
grep -E "Test Case .*(passed|failed|skipped)|error:" "$PROOF/xcodebuild.log" | sed 's/^/  /' | tail -20 || true
echo
echo "  screenshots     $SHOTS_OUT"
echo "  evidence        $PROOF/evidence.jsonl  $PROOF/evidence.json"
echo "  host log        $PROOF/host.log"
echo "  mac-side log    $PROOF/mac-side.log"
echo "  xcodebuild log  $PROOF/xcodebuild.log"
exit "${STATUS:-1}"
