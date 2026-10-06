#!/usr/bin/env bash
# On-screen check of the native screens against the REAL engine (this tree's out/).
#
#   SC_ROOT=<folder> macos/checks/screen-check.sh start          build + launch (behind everything)
#   SC_ROOT=<folder> macos/checks/screen-check.sh cmd <command…>  drive it; prints the answer
#   SC_ROOT=<folder> macos/checks/screen-check.sh shot <window> <name>   → $SC_ROOT/shots/<name>.png
#   SC_ROOT=<folder> macos/checks/screen-check.sh stop           quit it and remove everything it left
#
# Opening a screen (answers the window to shoot, e.g. "2142"):
#   cmd open <sidebar id>              overview files artifacts git simulators tasks memory staysfixed
#                                      store github readiness mcp remote hooks alerts hoot …
#   cmd open settings:<section id>     general appearance notifications agents features browser scraping
#                                      copilot ai-apps tasks plugins power advanced help …
#   cmd open window:<panel|session|browser>:<id>   a screen in a window of its own
#   cmd open session                   a fresh local shell session, selected
# <window> for shot/click/type/…: a number from `open`, or main | settings | island.
# `shot` includes the window's sheets and popovers. Other commands: state, windows, allwindows,
# screens, click/rclick/dclick <win> <x> <y> (points from the window's top-left), menu <title>,
# type <win> <text> (\n = Return), key <win> <cmd+k|escape|return|…>, js <main|settings|win> <body>,
# jsat <win> <x> <y> <body>, bridge <channel> [json args], do select|tab|settings|section <id>,
# vclick/vdrag, hit/focus/responder <win> …, viewshot <win> <path>, splits <win>, close <win>.
#
# Never touches the installed app: its own bundle id, its own data folder, its own
# WebKit/defaults, and it cannot come to the front (no Dock icon, never activates);
# every window it opens is put at the very back. The engine is told not to dial the
# relay (TERMINALDECK_RELAY=off), so no new machine appears on anyone's phone. Run
# `npx electron-vite build` and `npm run build:native-web` first — the engine serves out/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="${SC_SRC:-$HERE/../TerminalDeckNative/Sources}"  # SC_SRC: a frozen copy that builds (scratchpad/native-full/good-src)
ROOT="${SC_ROOT:-${TMPDIR:-/tmp}/td-screen-check}"
BUNDLE_ID="dev.terminaldeck.native-proof.screencheck"
APP="$ROOT/Screen Check.app"
EXE="$APP/Contents/MacOS/TerminalDeckNative"
IPC="$ROOT/ipc"

case "${1:-}" in
start)
    mkdir -p "$ROOT/shots" "$ROOT/data" "$IPC"
    rm -f "$IPC"/*
    WORK="$ROOT/pkg"
    rm -rf "$WORK/Core" "$WORK/App"
    mkdir -p "$WORK/Core" "$WORK/App"
    cp "$SRC"/TerminalDeckNativeCore/*.swift "$WORK/Core/"
    for f in "$SRC"/TerminalDeckNative/*.swift; do
        [ "$(basename "$f")" = "TerminalDeckNativeApp.swift" ] || cp "$f" "$WORK/App/"
    done
    cp "$HERE/ScreenCheckDriver.swift" "$WORK/App/"
    cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ScreenCheck",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.19.0")],
    targets: [
        .target(name: "TerminalDeckNativeCore", path: "Core"),
        .executableTarget(name: "TerminalDeckNative",
                          dependencies: ["TerminalDeckNativeCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
                          path: "App",
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]),
    ]
)
SWIFT
    echo "==> building"
    if ! swift build --package-path "$WORK" --scratch-path "$ROOT/build" -c debug > "$ROOT/build.log" 2>&1; then
        grep -E "error:" "$ROOT/build.log" | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -20
        echo "FAIL  did not build"; exit 1
    fi
    BIN="$(swift build --package-path "$WORK" --scratch-path "$ROOT/build" -c debug --show-bin-path)"

    echo "==> assembling $APP"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN/TerminalDeckNative" "$EXE"
    cp "$HERE/../Info.plist" "$APP/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
    plutil -replace CFBundleName -string "Screen Check" "$APP/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "Screen Check" "$APP/Contents/Info.plist"
    for bundle in "$BIN"/*.bundle; do [ -d "$bundle" ] && ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"; done
    for bundle in "$APP/Contents/Resources"/*.bundle; do [ -d "$bundle" ] && codesign --force --sign - --timestamp=none "$bundle"; done
    codesign --force --options runtime --sign - --timestamp=none --entitlements "$HERE/../NativePreview.entitlements" "$APP"

    echo "==> launching (behind everything, its own data in $ROOT/data)"
    TD_REPO="$REPO" TD_NATIVE_DATA_DIR="$ROOT/data" TERMINALDECK_RELAY=off SC_DIR="$IPC" SC_ROOT="$ROOT" \
        nohup "$EXE" > "$ROOT/app.log" 2>&1 &
    echo $! > "$ROOT/pid"
    disown || true
    for _ in $(seq 1 100); do [ -f "$IPC/ready" ] && break; sleep 0.1; done
    [ -f "$IPC/ready" ] || { echo "FAIL  did not start (see $ROOT/app.log)"; exit 1; }
    echo "started pid $(cat "$ROOT/pid")"
    ;;
cmd)
    shift
    N="$(python3 -c "import time; print(time.time_ns())")"
    printf '%s' "$*" > "$IPC/$N.tmp" && mv "$IPC/$N.tmp" "$IPC/$N.cmd"
    for _ in $(seq 1 600); do
        if [ -f "$IPC/$N.res" ]; then cat "$IPC/$N.res"; echo; rm -f "$IPC/$N.res"; exit 0; fi
        sleep 0.05
    done
    echo "timeout"; exit 1
    ;;
shot)
    WIN="${2:?window: a number, or main | settings | island}"; NAME="${3:?name}"
    OUT="$ROOT/shots/$NAME.png"
    # The window and its sheets/popovers (their own windows), composited as on screen.
    FAMILY="$("$0" cmd family "$WIN")"
    case "$FAMILY" in error*|timeout*) echo "$FAMILY"; exit 1 ;; esac
    PARTS=()
    while read -r num x y w h scale; do
        [ -n "$num" ] || continue
        screencapture -l "$num" -o -x "$ROOT/shots/_part-$num.png"
        PARTS+=("$num $x $y $w $h $scale")
    done <<< "$FAMILY"
    if [ "${#PARTS[@]}" -eq 1 ]; then
        mv "$ROOT/shots/_part-${PARTS[0]%% *}.png" "$OUT"
    else
        printf '%s\n' "${PARTS[@]}" | python3 -c '
import sys
from PIL import Image
rows = [l.split() for l in sys.stdin if l.strip()]
root, out = sys.argv[1], sys.argv[2]
scale = float(rows[0][5])
left = min(int(r[1]) for r in rows); top = max(int(r[2]) + int(r[4]) for r in rows)
right = max(int(r[1]) + int(r[3]) for r in rows); bottom = min(int(r[2]) for r in rows)
canvas = Image.new("RGBA", (int((right - left) * scale), int((top - bottom) * scale)), (0, 0, 0, 0))
for num, x, y, w, h, _ in rows:  # parent first, then what sits on it
    part = Image.open(f"{root}/shots/_part-{num}.png").convert("RGBA")
    canvas.alpha_composite(part, (int((int(x) - left) * scale), int((top - int(y) - int(h)) * scale)))
canvas.save(out)
' "$ROOT" "$OUT"
        rm -f "$ROOT"/shots/_part-*.png
    fi
    echo "$OUT"
    ;;
stop)
    if [ -f "$ROOT/pid" ]; then
        PID="$(cat "$ROOT/pid")"
        kill -TERM "$PID" 2>/dev/null || true
        for _ in $(seq 1 80); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        rm -f "$ROOT/pid"
    fi
    sleep 1
    if pgrep -f -- "--user-data-dir=$ROOT/data" >/dev/null 2>&1; then echo "WARN  engine still running"; else echo "engine gone"; fi
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" "$HOME/Library/WebKit/$BUNDLE_ID" \
           "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
           "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
           "$ROOT/data" "$IPC" "$APP"
    echo "cleaned (screenshots kept in $ROOT/shots)"
    ;;
*)
    sed -n 2,14p "$0"; exit 2 ;;
esac
