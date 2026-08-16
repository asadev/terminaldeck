#!/usr/bin/env bash
#
# The whole iOS transfer-and-clipboard proof, from one command.
#
# It stands up the product's own headless host on the **live** relay, erases and
# boots a Simulator, drives `LiveTransferUITests` against it, and then reads the
# evidence off the Mac — where the phone cannot reach it.
#
#     ios/Harness/live-transfer.sh [--device "iPhone 17 Pro"] [--media <file>] [--keep]
#
# With no `--media` it generates its own several-megabyte noise photo. Point
# `--media` at a video and the same proof runs for a video; the phone's path is
# identical either way.
#
# ## Why this script exists at all
#
# `LiveTransferUITests` skips itself when `TD_READY_FILE` is unset, and a skipped
# test reporting green is the exact failure this workstream is about. The gate
# cannot be removed — without a host on the far end every case would fail for a
# reason that has nothing to do with the code — so the answer is to make starting
# the host and running the tests one action instead of two. If it is one command
# it gets run.
#
# ## Which host, and why not the app in /Applications
#
# The headless build, `out/headless/host.mjs`. It is not a stand-in: it is the
# same `registerRemoteIpc`, `PtyManager`, `uploads.ts`, folder grants and sealed
# channel the window build links, assembled by `src/headless/host.ts` with no
# window around it. Two things make it the right host for an unattended proof and
# the packaged app the wrong one:
#
#  1. **Pairing can be driven.** The desktop mints a code behind Settings → Pair
#     a device and wants a person to press Approve. There is no person here at
#     3 a.m., and a proof that needs one is a proof that gets skipped.
#  2. **It cannot disturb the real machine.** `/Applications/Terminal Deck.app`
#     is running on this Mac right now with Asad's own state and its own relay
#     identity. A second host sharing that state directory would be two processes
#     claiming one name at the rendezvous — `HEADLESS.md` names this exactly —
#     and a phone would reach whichever answered first.
#
# So this host gets its own HOME, and everything it touches lives under it.
#
# ## Why HOME is a short path in /tmp
#
# Not a preference — a hard limit. The control socket is `$HOME/Library/
# Application Support/terminaldeck/host.sock`, and a Unix socket path is copied
# into a fixed 104-byte field. A HOME under the usual scratch directory makes
# that path 160 characters and the host refuses to start, which it says in as
# many words. `src/headless/control.ts` documents the same limit.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

DEVICE_NAME="iPhone 17 Pro"
KEEP=0
# What gets sent. Empty means "generate the noise photo", which is the default
# because it is reproducible and needs nothing installed. `--media` takes any
# file `simctl addmedia` will accept, so the same proof runs for a **video**
# without a line of code changing — the phone's path is identical either way
# (`PHPickerViewController` with `preferredAssetRepresentationMode = .current`,
# then `FileUpload`), and the only honest way to say a video works is to have
# sent one.
MEDIA=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE_NAME="$2"; shift 2 ;;
        --media)  MEDIA="$2"; shift 2 ;;
        --keep)   KEEP=1; shift ;;
        *) echo "usage: live-transfer.sh [--device <name>] [--media <file>] [--keep]" >&2; exit 2 ;;
    esac
done

# The Mac's own home, captured before anything below borrows the name. `HOME=…`
# in front of a command changes it for that command only, but the Simulator's
# device directory is under the *real* one and reading it through `$HOME` after
# an inline assignment is exactly the sort of thing that works until it does not.
REAL_HOME="$HOME"

TD_HOME=/private/tmp/tdios
STATE="$TD_HOME/Library/Application Support/terminaldeck"
WORK="$TD_HOME/work"
UPLOADS="$TD_HOME/Downloads/Terminal Deck"
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
mkdir -p "$STATE" "$WORK" "$UPLOADS" "$SHOTS"

# The host's own setting decides which agent a phone's New Session starts —
# `host-core.ts` reads `preferences.defaultProvider` and falls back to a plain
# shell when that CLI is not installed. A plain shell is what this proof needs,
# because every claim it makes is read out of a command's *output*: a file
# written in the granted folder, and a `$RANDOM` the host minted itself. Claude
# is installed on this Mac, so the preference has to say so rather than be left
# to the default.
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

say "host: starting out/headless/host.mjs on the live relay"
HOME="$TD_HOME" node "$repo/out/headless/host.mjs" > "$PROOF/host.log" 2>&1 &
HOST_PID=$!
# Declared before the trap that names it: `set -u` turns an unset variable in a
# cleanup handler into a second failure on top of the first.
SAMPLER_PID=""
XCB_PID=""

# Everything this script started, stopped — including xcodebuild.
#
# An earlier version left that one out and it cost a whole run: the script exited
# on a failed approval, its xcodebuild carried on in the background holding
# `result.xcresult`, and the *next* run died on "Existing file at
# -resultBundlePath" three seconds in. The symptom was a run that reported the
# phone never asked for a code, which is a sentence about the phone describing a
# process nobody had killed.
cleanup() {
    if [[ "$KEEP" == "0" ]]; then
        HOME="$TD_HOME" node "$repo/out/headless/cli.mjs" stop >/dev/null 2>&1 || true
        kill "$HOST_PID" 2>/dev/null || true
    fi
    kill "$SAMPLER_PID" 2>/dev/null || true
    kill "$XCB_PID" 2>/dev/null || true
    pkill -f "xcodebuild test -project $repo/ios/TerminalDeck.xcodeproj" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for the relay, and refuse to go on without it. A proof that quietly ran
# over loopback would be the stand-in again under another name.
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

# ------------------------------------------------------------- the media -----

say "media: the file that will be sent"
if [[ -n "$MEDIA" ]]; then
    [[ -f "$MEDIA" ]] || { echo "no file at $MEDIA" >&2; exit 1; }
    SOURCE_FILE="$PROOF/$(basename "$MEDIA")"
    cp "$MEDIA" "$SOURCE_FILE"
else
    SOURCE_FILE="$PROOF/td-proof.png"
    "$HARNESS" live media --out "$SOURCE_FILE" >/dev/null
fi
SOURCE_SHA="$(shasum -a 256 "$SOURCE_FILE" | awk '{print $1}')"
SOURCE_BYTES="$(stat -f%z "$SOURCE_FILE")"
echo "  $(basename "$SOURCE_FILE")  $SOURCE_BYTES bytes  $SOURCE_SHA"

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

# Erased, not merely reinstalled. The pairing lives in the Simulator's keychain
# and survives an uninstall, so without this the first run proves pairing and
# every run after it proves nothing about the pairing screen at all.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

xcrun simctl addmedia "$UDID" "$SOURCE_FILE"
sleep 3
SOURCE_MEDIA="$(find "$REAL_HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/DCIM" -type f \
    -exec shasum -a 256 {} + | awk -v want="$SOURCE_SHA" '$1 == want {print $2}' | head -1)"
[[ -n "$SOURCE_MEDIA" ]] || {
    echo "$(basename "$SOURCE_FILE") did not survive addmedia byte for byte; the digests" >&2
    echo "would be comparing two different files and the proof would be void" >&2
    exit 1
}
echo "  library holds it verbatim at $SOURCE_MEDIA"

# ------------------------------------------------- the clipboard sentinel ----

# Written to the DEVICE clipboard first, and read straight back. That read is the
# point: it proves the reader works *before* anything depends on it, so a later
# empty pbpaste means the app did not copy rather than that the tool is broken.
# It is also the payload for the inbound half — a command the shell on the Mac
# will run, whose output only that shell could have produced.
PASTE_MARK="TD-PASTEIN-$RANDOM$RANDOM$RANDOM"
printf 'echo %s > pasted.txt' "$PASTE_MARK" | xcrun simctl pbcopy "$UDID"
SENTINEL="$(xcrun simctl pbpaste "$UDID")"
say "clipboard: sentinel on the device pasteboard"
echo "  wrote: echo $PASTE_MARK > pasted.txt"
echo "  read back: $SENTINEL"
[[ "$SENTINEL" == "echo $PASTE_MARK > pasted.txt" ]] || {
    echo "simctl pbpaste did not read back what pbcopy wrote; nothing downstream would mean anything" >&2
    exit 1
}

# --------------------------------------------------------- the .part watch ---

# The Android proof did not accept the progress bar either: it watched the
# partial file on the Mac grow, and every step it grew by was a multiple of
# MAX_UPLOAD_CHUNK_BYTES. Same here. Sampling a file's size is a poll, and it is
# the honest kind — there is no event a shell can subscribe to for "this file got
# bigger", and the alternative is believing a bar the phone drew for itself.
: > "$PROOF/part-sizes.txt"
(
    while true; do
        for part in "$UPLOADS"/*.part; do
            [[ -e "$part" ]] || continue
            stat -f%z "$part" >> "$PROOF/part-sizes.txt"
        done
        sleep 0.05
    done
) &
SAMPLER_PID=$!
# Off the job table, so killing it later does not print "Terminated: 15" and a
# copy of the loop into the middle of the results.
disown "$SAMPLER_PID" 2>/dev/null || true

# ---------------------------------------------------------------- the run ----

READY="$PROOF/ready.txt"
# The other half of the same handshake, in the other direction: the phone says
# it is at the pairing screen by writing READY, and the harness answers with six
# digits in CODE_FILE. It has to be a file rather than an environment variable
# because the code is minted *after* the phone gets there — a code is good for
# sixty seconds and a Simulator takes longer than that to build, install and
# launch, so minting one before `xcodebuild` starts would hand the test something
# that had already expired.
CODE_FILE="$PROOF/pair-code.txt"
rm -f "$READY" "$CODE_FILE"
rm -rf "$PROOF/result.xcresult"

say "test: xcodebuild against $DEVICE_NAME"
#
# `TEST_RUNNER_…` in the **environment of xcodebuild**, not as build settings on
# its command line. That distinction cost the first run of this script and is the
# whole reason this comment is here.
#
# Measured on Xcode 26.6 with iOS 26.5, twice, changing nothing but the form:
#
#   xcodebuild test … TEST_RUNNER_TD_READY_FILE=/tmp/probe
#     → "Build settings from command line: TEST_RUNNER_TD_READY_FILE = /tmp/probe"
#       at the top of the log, and inside the runner `ProcessInfo.environment`
#       has no TD_ variable at all. Both cases skip. "** TEST SUCCEEDED **".
#
#   TEST_RUNNER_TD_READY_FILE=/tmp/probe xcodebuild test …
#     → the runner sees TD_READY_FILE and the case runs.
#
# The build-setting form is what `RealDesktopUITests` and `project.yml` document,
# and on this toolchain it produces a green run in which nothing was tested. That
# is the exact failure mode this workstream exists to eliminate, arriving through
# the door marked "how to run the tests" — both files have been corrected.
(
    TEST_RUNNER_TD_READY_FILE="$READY" \
    TEST_RUNNER_TD_CODE_FILE="$CODE_FILE" \
    TEST_RUNNER_TD_UPLOADS_DIR="$UPLOADS" \
    TEST_RUNNER_TD_SOURCE_MEDIA="$SOURCE_MEDIA" \
    TEST_RUNNER_TD_SHOTS="$SHOTS" \
    xcodebuild test \
        -project "$repo/ios/TerminalDeck.xcodeproj" \
        -scheme TerminalDeck \
        -destination "platform=iOS Simulator,id=$UDID" \
        -only-testing:TerminalDeckUITests/LiveTransferUITests \
        -derivedDataPath "$repo/ios/build/DerivedData" \
        -resultBundlePath "$PROOF/result.xcresult" \
        > "$PROOF/xcodebuild.log" 2>&1
    echo $? > "$PROOF/xcodebuild.status"
) &
XCB_PID=$!

# The phone says when it is standing at the pairing screen. A code is good for
# sixty seconds and a Simulator takes longer than that to build, install and
# launch — mint it first and it has expired before anything can read it.
say "pairing: waiting for the phone to reach the pairing screen"
for _ in $(seq 1 900); do
    [[ -f "$READY" ]] && break
    # xcodebuild dying before the phone gets anywhere is worth saying out loud.
    # Silently falling through to "the phone never asked for a code" describes
    # the phone, and the phone was never the problem.
    kill -0 "$XCB_PID" 2>/dev/null || { echo "  xcodebuild stopped early:"; tail -5 "$PROOF/xcodebuild.log"; break; }
    sleep 1
done

if [[ -f "$READY" ]]; then
    # Six digits, written where the test is watching for them. This used to be
    # `simctl openurl` with a `terminaldeck://pair?…` link, which was the door a
    # scanned QR came through — and which also raised a SpringBoard alert
    # ("Open in Terminal Deck?") that the test had to find and tap, because as far
    # as iOS was concerned another program was handing this app a link. None of
    # that exists now: the product's only way in is a typed code, so the proof
    # types one.
    CODE="$("$HARNESS" live pair --state "$STATE" --out "$CODE_FILE" | tail -1)"
    echo "  $CODE"
    say "pairing: approving the device the way pressing Approve does"
    # Not fatal. If nothing pairs, the run has still produced screenshots, a host
    # log and a test result, and the evidence section at the bottom is where that
    # gets said out loud — a script that exits here reports nothing at all about
    # the thing it was asked to prove.
    "$HARNESS" live approve --state "$STATE" --wait 180000 || true
else
    say "pairing: the phone never asked for a code (already paired, or it never started)"
fi

say "grant: giving the device one folder to work in"
"$HARNESS" live folder --state "$STATE" --path "$WORK" || true

wait "$XCB_PID" || true
kill "$SAMPLER_PID" 2>/dev/null || true
STATUS="$(cat "$PROOF/xcodebuild.status" 2>/dev/null || echo "?")"

# --------------------------------------------------------------- evidence ----

say "RESULT — read on the Mac, not on the phone"
echo "xcodebuild exit: $STATUS"
grep -E "Test Case .* (passed|failed)|Testing failed|\*\* TEST" "$PROOF/xcodebuild.log" | tail -20 || true

echo
echo "--- the file ---"
echo "source   $SOURCE_BYTES bytes  $SOURCE_SHA"
LANDED="$(find "$UPLOADS" -type f ! -name '*.part' -print | head -1)"
if [[ -n "$LANDED" ]]; then
    LANDED_SHA="$(shasum -a 256 "$LANDED" | awk '{print $1}')"
    echo "landed   $(stat -f%z "$LANDED") bytes  $LANDED_SHA"
    echo "path     $LANDED"
    if [[ "$LANDED_SHA" == "$SOURCE_SHA" ]]; then
        echo "VERDICT  identical — the bytes crossed the live relay whole"
    else
        echo "VERDICT  DIFFERENT — the file that landed is not the file that was sent"
    fi
else
    echo "landed   nothing whole in $UPLOADS"
    ls -la "$UPLOADS" || true
fi

echo
echo "--- progress, from the partial file on the Mac ---"
python3 - "$PROOF/part-sizes.txt" <<'PY'
#
# What "the progress was real" means, stated so that it is true of every reading.
#
# The Android proof phrased it as "every step a multiple of
# MAX_UPLOAD_CHUNK_BYTES". That is very nearly right and it fails on the last
# step for two innocent reasons: the final slice of a file is short by
# construction, and a sampler at 20 Hz misses readings on a fast link, so two
# slices can land between one `stat` and the next. Both showed up on the first
# green run as a single step of 43345 — which is 24576 + 18769, the tail of a
# 6,752,593-byte file, and not a protocol violation at all.
#
# So the property checked is the one the samples can actually support: the
# partial file only ever grows, every size it is caught at is a whole number of
# slices, and the one that is not is the last, which is the file's exact length.
import sys

sizes = [int(line) for line in open(sys.argv[1]) if line.strip()]
seen = []
for size in sizes:
    if not seen or size != seen[-1]:
        seen.append(size)
if not seen:
    print("no .part file was ever sampled")
    raise SystemExit

chunk = 24576
print(f"{len(sizes)} samples, {len(seen)} distinct sizes, {seen[0]} to {seen[-1]}")
print("only ever grew:", all(b > a for a, b in zip(seen, seen[1:])))
partial = [size for size in seen[:-1] if size % chunk]
print(f"every size but the last a whole number of {chunk}-byte slices:", not partial)
if partial:
    print("  sizes that were not:", partial[:10])
print(f"last size {seen[-1]} = {seen[-1] // chunk} slices + {seen[-1] % chunk} bytes")
PY

echo
echo "--- clipboard inwards: device pasteboard -> a shell on the Mac ---"
echo "expected in $WORK/pasted.txt: $PASTE_MARK"
if [[ -f "$WORK/pasted.txt" ]]; then
    echo "found:   $(cat "$WORK/pasted.txt")"
    grep -q "$PASTE_MARK" "$WORK/pasted.txt" \
        && echo "VERDICT  the shell on the Mac ran what was on the phone's clipboard" \
        || echo "VERDICT  the file is there but does not carry the marker"
else
    echo "found:   nothing — the paste never reached a shell"
fi

echo
echo "--- clipboard outwards: the host's own \$RANDOM -> device pasteboard ---"
if [[ -f "$WORK/said.txt" ]]; then
    HOST_SAID="$(cat "$WORK/said.txt")"
    echo "host said:      $HOST_SAID"
    AFTER="$(xcrun simctl pbpaste "$UDID" || true)"
    echo "pasteboard now: $(printf '%s' "$AFTER" | tail -3)"
    if [[ "$AFTER" == "$SENTINEL" ]]; then
        echo "VERDICT  unchanged — Copy Screen never reached the pasteboard"
    elif printf '%s' "$AFTER" | grep -q "$HOST_SAID"; then
        echo "VERDICT  replaced, and carries a value only the host could have produced"
    else
        echo "VERDICT  replaced, but not by the host's value"
    fi
else
    echo "the host never wrote said.txt, so there is nothing it could have produced"
fi

echo
echo "screenshots: $SHOTS"
echo "logs:        $PROOF/xcodebuild.log, $PROOF/host.log"
