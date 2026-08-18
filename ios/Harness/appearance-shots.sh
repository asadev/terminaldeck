#!/usr/bin/env bash
#
# Every screen of the phone app, in both appearances, from one command.
#
#     ios/Harness/appearance-shots.sh [--device "iPhone 17 Pro"] [--fresh] [--keep]
#
# Asad: *"mobile iOS is only dark mode — it should have both, in settings."*
# The palette arithmetic is asserted in `Tests/AppearanceTests.swift`; this is
# the other half — the frames a person looks at before deciding it is right,
# taken by `UITests/AppearanceShotsUITests.swift`, which also measures each one
# and fails on a screen that did not follow the appearance.
#
# ## Why it needs the real host and not the stand-in
#
# `ios/Harness/run.sh host` implements no `ports` handler at all, so the
# Localhost tab is permanently empty against it and three of the stops would be
# photographs of an empty screen. What this needs is the product's own headless
# host — the same `registerRemoteIpc`, `PtyManager` and sealed channel the window
# build links. `live-transfer.sh` is the same arrangement for a different proof
# and its header argues the whole case; the short version is that the headless
# host's pairing can be driven end to end, and that it cannot disturb the copy of
# Terminal Deck running on this Mac because it lives under a HOME of its own.
#
# HOME is a short path in /tmp for a reason that is a hard limit rather than a
# preference: the control socket is `$HOME/Library/Application Support/
# terminaldeck/host.sock` and a Unix socket path is copied into a 104-byte field.
#
# ## The page the localhost stop opens
#
# Its own tiny server on a port this script owns, rather than whatever else is
# listening on this Mac. Opening a tunnel is a real HTTP request to a real
# program, and pointing it at somebody else's dev server to take a screenshot is
# not a read-only act in any sense worth relying on.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

DEVICE_NAME="iPhone 17 Pro"
KEEP=0
FRESH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE_NAME="$2"; shift 2 ;;
        --keep)   KEEP=1; shift ;;
        --fresh)  FRESH=1; shift ;;
        *) echo "usage: appearance-shots.sh [--device <name>] [--fresh] [--keep]" >&2; exit 2 ;;
    esac
done

TD_HOME=/private/tmp/tdshots
STATE="$TD_HOME/Library/Application Support/terminaldeck"
WORK="$TD_HOME/work"
PROOF="$TD_HOME/proof"
SHOTS="$PROOF/shots"
HARNESS="$repo/ios/Harness/run.sh"
# A port nothing on this machine is likely to be using, so the row the test taps
# is the page this script served rather than a coincidence.
PAGE_PORT=4399

say() { printf '\n=== %s\n' "$*"; }

# --------------------------------------------------------------- the host ----

#
# **Reused by default, erased only on `--fresh`.**
#
# The first version of this script erased both ends on every run, which is what
# `live-transfer.sh` does and is right for that proof: it is *about* pairing, so
# a phone that was already paired would prove nothing. This one is about
# photographs, and erasing costs two things it cannot afford. The host's relay
# identity is in $TD_HOME, so throwing it away un-pairs the phone; and a freshly
# erased Simulator spends its first few minutes firing first-boot notifications
# — "Ready for Apple Intelligence" landed over the port list on the first run,
# and XCUITest dismisses an interrupting element by **tapping** it, so the tap
# went through to the row underneath and opened a page nobody had asked for. The
# rest of that run photographed a web view.
#
# So: keep both unless told otherwise, and the pairing carries over.
if [[ "$FRESH" == "1" ]] || [[ ! -f "$STATE/state.json" ]]; then
    say "host: clearing $TD_HOME"
    if [[ -S "$STATE/host.sock" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -rf "$TD_HOME"
    ERASE=1
else
    say "host: reusing $TD_HOME (pass --fresh to start over)"
    if [[ -S "$STATE/host.sock" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        sleep 1
    fi
    ERASE=0
fi
mkdir -p "$STATE" "$WORK" "$SHOTS"
rm -f "$SHOTS"/*.png

# A plain shell rather than whichever agent CLI is installed: every frame of the
# terminal stop is a photograph of program output, and a shell is the only
# program whose output this script decides.
if [[ ! -f "$STATE/state.json" ]]; then
cat > "$STATE/state.json" <<JSON
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
fi

say "page: serving something to tunnel to on :$PAGE_PORT"
mkdir -p "$TD_HOME/page"
cat > "$TD_HOME/page/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Basket</title>
<style>
  body { font: 16px -apple-system, sans-serif; margin: 0; padding: 24px; }
  h1 { font-size: 28px; margin: 0 0 12px; }
  a { display: inline-block; margin-top: 16px; }
</style>
<h1>Basket</h1>
<p>A page from the machine, opened through the tunnel.</p>
<a href="#" onclick="history.pushState({}, '', '/delivery'); document.querySelector('h1').textContent = 'Delivery'; return false">Go to Delivery &raquo;</a>
HTML
(cd "$TD_HOME/page" && python3 -m http.server "$PAGE_PORT" >/dev/null 2>&1) &
PAGE_PID=$!

say "host: starting out/headless/host.mjs"
HOME="$TD_HOME" node "$repo/out/headless/host.mjs" > "$PROOF/host.log" 2>&1 &
HOST_PID=$!
XCB_PID=""

cleanup() {
    if [[ "$KEEP" == "0" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        kill "$HOST_PID" 2>/dev/null || true
    fi
    kill "$PAGE_PID" 2>/dev/null || true
    kill "$XCB_PID" 2>/dev/null || true
    pkill -f "xcodebuild test -project $repo/ios/TerminalDeck.xcodeproj" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 40); do
    if HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status 2>/dev/null | grep -q "connected      wss://relay"; then
        break
    fi
    sleep 1
done
HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" status | sed -n '1,12p'

# --------------------------------------------------------- the simulator -----

say "simulator: booting $DEVICE_NAME"
UDID="$(xcrun simctl list devices available -j \
    | python3 -c "import json,sys
devices = json.load(sys.stdin)['devices']
for runtime, entries in devices.items():
    for entry in entries:
        if entry['name'] == '$DEVICE_NAME' and 'iOS' in runtime:
            print(entry['udid']); raise SystemExit")"
[[ -n "$UDID" ]] || { echo "no simulator called $DEVICE_NAME" >&2; exit 1; }
echo "  $UDID"

xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
# An `if` rather than `[[ … ]] && …`, because under `set -e` a false test is the
# last command's exit status and would end the script here rather than skip a
# line.
if [[ "$ERASE" == "1" ]]; then
    echo "  erasing (--fresh, or nothing paired yet)"
    xcrun simctl erase "$UDID"
fi
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# The **system** appearance is left dark on purpose, and it is the control in
# this experiment: the app is asked for Light through its own setting while the
# phone underneath it says Dark. A run in which the simulator was also switched
# would prove that the app follows the system, which is a different claim and the
# easier one.
xcrun simctl ui "$UDID" appearance dark || true

# ---------------------------------------------------------------- the run ----

READY="$PROOF/ready.txt"
CODE_FILE="$PROOF/pair-code.txt"
rm -f "$READY" "$CODE_FILE"
rm -rf "$PROOF/result.xcresult"

# Which suite the runner drives.
#
# `AppearanceShotsUITests` is the tour this script was written for and stays the
# default. It is a variable because `ReviewScreensUITests` needs the *identical*
# apparatus — the same headless host under the same HOME, the same
# `TD_READY_FILE` handshake, the same page on `TD_PAGE_PORT` — and the only thing
# that differs is the name after `-only-testing`. A second copy of ninety lines
# of host setup, drifting from this one, is the alternative.
#
#     TD_ONLY=TerminalDeckUITests/ReviewScreensUITests ios/Harness/appearance-shots.sh
ONLY="${TD_ONLY:-TerminalDeckUITests/AppearanceShotsUITests/testEveryScreenInBothSchemes}"

say "test: xcodebuild against $DEVICE_NAME ($ONLY)"
# `TEST_RUNNER_…` in the ENVIRONMENT of xcodebuild rather than on its command
# line. Put after it they are parsed as build settings, never reach the runner,
# and every case skips while the run reports "** TEST SUCCEEDED **" — measured on
# Xcode 26.6, and the reason this file exists as one command.
(
    TEST_RUNNER_TD_READY_FILE="$READY" \
    TEST_RUNNER_TD_CODE_FILE="$CODE_FILE" \
    TEST_RUNNER_TD_SHOTS="$SHOTS" \
    TEST_RUNNER_TD_PAGE_PORT="$PAGE_PORT" \
    xcodebuild test \
        -project "$repo/ios/TerminalDeck.xcodeproj" \
        -scheme TerminalDeck \
        -destination "platform=iOS Simulator,id=$UDID" \
        -only-testing:"$ONLY" \
        -derivedDataPath "$repo/ios/build/DerivedData" \
        -clonedSourcePackagesDirPath "$repo/ios/build/SourcePackages" \
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
    say "pairing: the phone never asked for a code"
fi

say "grant: giving the device one folder to work in"
"$HARNESS" live folder --state "$STATE" --path "$WORK" || true

wait "$XCB_PID" || true
STATUS="$(cat "$PROOF/xcodebuild.status" 2>/dev/null || echo "?")"

# --------------------------------------------------------------- evidence ----

say "RESULT"
echo "xcodebuild exit: $STATUS"
grep -E "Test Case .* (passed|failed)|error:|\*\* TEST" "$PROOF/xcodebuild.log" | tail -30 || true

echo
echo "--- the frames ---"
ls -1 "$SHOTS" 2>/dev/null | sed 's/^/  /' || echo "  none"
echo
echo "open them with:  open $SHOTS"
