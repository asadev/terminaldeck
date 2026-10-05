#!/usr/bin/env bash
# Offscreen check that screen windows really open and load.
#
# Builds the app's real scenes + AppModel (every app source except the @main file)
# into a throwaway check program, starts it against a FAKE engine that serves a test
# page, and drives it through the same paths the user takes. Invisible: the program
# cannot activate, has no Dock icon, and every window it shows is fully transparent.
# Never touches the installed app, its data folder, its log or its settings.
#
#   macos/checks/window-check.sh        → prints PASS/FAIL lines, exits non-zero on a failure
#   TD_CHECK_SOURCES=<dir> …            → check another copy of the Sources folder
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${TD_CHECK_SOURCES:-$HERE/../TerminalDeckNative/Sources}"
MAIN_PACKAGE="$HERE/../TerminalDeckNative/Package.swift"
# Kept between runs so packages (SwiftTerm) are fetched and built once.
BUILD_CACHE="${TMPDIR:-/tmp}/td-window-check-build"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/td-window-check.XXXXXX")"
BUNDLE_ID="dev.terminaldeck.native-proof.window-check"
cleanup() {
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  # What macOS keeps under the check's own id (never the app's): settings, web data, caches.
  rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" "$HOME/Library/WebKit/$BUNDLE_ID" \
         "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
         "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- the program: real sources + the check entry point -------------------------------
mkdir -p "$WORK/pkg/Core" "$WORK/pkg/App"
cp "$SRC"/TerminalDeckNativeCore/*.swift "$WORK/pkg/Core/"
for f in "$SRC"/TerminalDeckNative/*.swift; do
  [ "$(basename "$f")" = "TerminalDeckNativeApp.swift" ] || cp "$f" "$WORK/pkg/App/"
done
cp "$HERE/WindowCheck.swift" "$WORK/pkg/App/"
# Stand-ins (this copy only): test screens for the switchboard, an in-memory browser.
rm -f "$WORK/pkg/App/NativeScreens.swift" "$WORK/pkg/App/NativeBrowserTabsAdapter.swift"
cp "$HERE/NativeScreensStub.swift" "$HERE/BrowserTabsStub.swift" "$WORK/pkg/App/"

cat > "$WORK/pkg/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Window Check</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

# The app's own package dependencies (SwiftTerm, for the native terminal).
DEPS=""; PRODUCTS=""
if grep -q "SwiftTerm" "$MAIN_PACKAGE"; then
  DEPS='.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.19.0"),'
  PRODUCTS='.product(name: "SwiftTerm", package: "SwiftTerm"),'
fi

cat > "$WORK/pkg/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "WindowCheck",
    platforms: [.macOS(.v26)],
    dependencies: [$DEPS],
    targets: [
        .target(name: "TerminalDeckNativeCore", path: "Core"),
        .executableTarget(
            name: "WindowCheck", dependencies: ["TerminalDeckNativeCore", $PRODUCTS], path: "App",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("WebKit"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "$WORK/pkg/Info.plist"]),
            ]),
    ]
)
SWIFT

# --- the fake engine: serves one test page, says READY, stops when stdin closes -------
FAKE="$WORK/repo"
ELECTRON="$FAKE/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
mkdir -p "$(dirname "$ELECTRON")" "$FAKE/www"
cat > "$FAKE/www/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>check</title>
<script>
  // A stand-in for the web app: answers the native window the way the contract says.
  const q = new URLSearchParams(location.search)
  const post = (m) => window.webkit.messageHandlers.tdNative.postMessage(m)
  const token = q.get('t') === 'tok' ? 'token=ok' : 'token=missing'
  const state = { selected: 't1', active: 't1' }
  window.__ran = []
  function sendSidebar() {
    post({ type: 'sidebar', state: {
      groups: [
        { id: 'hoot', title: null, items: [{ id: 'hoot', title: 'Hoot', symbol: 'bird', kind: 'hoot' }] },
        { id: 'project', title: 'Project', items: [
          { id: 'tasks', title: 'Tasks', symbol: 'checklist', kind: 'panel' },
          { id: 'files', title: 'Files', symbol: 'folder', kind: 'panel' } ] } ],
      projects: [{ id: '/tmp/p', title: 'p', expanded: true, sessions: [
        { id: 't1', title: 'claude', symbol: 'terminal', kind: 'session' },
        { id: 's9', title: 'zsh', symbol: 'terminal', kind: 'session' } ] }],
      selectedId: state.selected } })
  }
  function sendTabs() {
    post({ type: 'tabs', state: { tabs: [
        { id: 't1', title: 'claude', symbol: 'terminal', kind: 'session', active: state.active === 't1', closable: true },
        { id: 't2', title: 'docs', symbol: 'globe', kind: 'browser', active: state.active === 't2', closable: true } ],
      canNewTerminal: true, canNewBrowser: true } })
  }
  window.tdNative = { run: (name, arg) => {
    window.__ran.push(arg === undefined ? name : `${name}:${arg}`)
    // As the real page: the sidebar's selection is the open panel, else the active tab.
    if (name === 'select-tab') { state.active = arg; state.selected = arg; sendSidebar(); sendTabs() }
    if (name === 'select') { state.selected = arg; state.active = ['t1', 't2'].includes(arg) ? arg : null; sendSidebar(); sendTabs() }
    if (name === 'open-settings') post({ type: 'open-settings', url: '/?settings=1' })
    return true
  } }
  post({ type: 'ready' })
  if (q.get('settings')) {
    post({ type: 'title', value: 'Settings page' })
    post({ type: 'settings-sections', sections: [
      { id: 'general', title: 'General', symbol: 'gearshape' },
      { id: 'hoot', title: 'Hoot', symbol: 'bird', kind: 'hoot' } ], selected: 'general' })
  } else {
    post({ type: 'title', value: q.get('screen') ? `screen=${q.get('screen')} id=${q.get('id')} ${token}` : 'Main', subtitle: 'check' })
    if (!q.get('screen')) { sendSidebar(); sendTabs() }
  }
</script>
HTML
cat > "$ELECTRON" <<'ENGINE'
#!/bin/bash
repo="$1"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cd "$repo/www" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
echo "TD_NATIVE_READY http://127.0.0.1:$PORT/?t=tok"
cat > /dev/null          # until the shell closes our stdin
kill "$SERVER" 2>/dev/null
ENGINE
chmod +x "$ELECTRON"

# A window that was open at the "last quit", to prove restoring works.
defaults write "$BUNDLE_ID" openScreenWindows -data "$(printf '[{"kind":"panel","id":"memory"}]' | xxd -p | tr -d '\n')"

echo "==> building the check"
BIN="$(swift build --package-path "$WORK/pkg" --scratch-path "$BUILD_CACHE" -c debug --show-bin-path)/WindowCheck"
rm -f "$BIN" # never run a program left over from an earlier build
if ! swift build --package-path "$WORK/pkg" --scratch-path "$BUILD_CACHE" -c debug > "$WORK/build.log" 2>&1; then
  grep -E "error:" "$WORK/build.log" | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -20
  echo "FAIL  the check did not build"
  exit 1
fi
[ -x "$BIN" ] || { echo "FAIL  the check did not build"; exit 1; }

echo "==> running it (invisible)"
set +e
TD_REPO="$FAKE" TD_NATIVE_DATA_DIR="$WORK/data" timeout 90 "$BIN"
STATUS=$?
set -e
sleep 0.5
if pgrep -f "$FAKE/www" >/dev/null 2>&1 || pgrep -f "$ELECTRON" >/dev/null 2>&1; then
  echo "FAIL  fake engine left running"; STATUS=1
fi
exit $STATUS
