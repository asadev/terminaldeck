#!/bin/bash
# What Squirrel's ShipIt does with an update zip before it swaps the app, run as
# a normal user on a copy, so a zip that would roll back is caught before release.
#
#   scripts/native-standalone/check-update-zip.sh <zip file or https URL> [--require-developer-id]
#
# 1. unpack with ditto, as ShipIt does;
# 2. every file owner-writable (0.19.0 shipped a 0444 licence; ShipIt then failed
#    with "Couldn't remove quarantine attribute … Permission denied" and rolled back);
# 3. mark the whole bundle quarantined, then `xattr -r -d com.apple.quarantine` must
#    succeed with no error — ShipIt's own step;
# 4. codesign --verify --deep --strict;
# 5. with --require-developer-id: the signature satisfies Terminal Deck 0.18.x's
#    designated requirement, which Squirrel checks before it installs.
set -euo pipefail
SOURCE="${1:?zip file or URL}"; REQUIRE_DEVID=0
[[ "${2:-}" == "--require-developer-id" ]] && REQUIRE_DEVID=1
DR='identifier "dev.terminaldeck.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "6U4VNX5W87"'
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$1"; }

if [[ "$SOURCE" == https://* ]]; then curl -fsSL -o "$WORK/update.zip" "$SOURCE"; ZIP="$WORK/update.zip"; else ZIP="$SOURCE"; fi
ditto -x -k "$ZIP" "$WORK/x" || fail "ditto could not unpack the zip"
APP="$(find "$WORK/x" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP" ]] || fail "no .app at the top of the zip"
ok "unpacked $(basename "$APP") $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"

READONLY="$(find "$APP" ! -perm -u+w)"
[[ -z "$READONLY" ]] || fail "files not owner-writable (ShipIt cannot clear their quarantine):"$'\n'"$READONLY"
ok "every file owner-writable"

xattr -r -w com.apple.quarantine "0081;00000000;ShipIt-check;" "$APP" 2>"$WORK/w.err" || fail "could not set quarantine: $(cat "$WORK/w.err")"
xattr -r -d com.apple.quarantine "$APP" 2>"$WORK/d.err" || fail "removing quarantine failed (ShipIt would roll back): $(cat "$WORK/d.err")"
[[ ! -s "$WORK/d.err" ]] && ok "quarantine set and removed on every file, no error" || fail "xattr reported: $(cat "$WORK/d.err")"

codesign --verify --deep --strict "$APP" 2>"$WORK/cs.err" || fail "codesign --verify --deep --strict: $(cat "$WORK/cs.err")"
ok "codesign --verify --deep --strict"
if [[ "$REQUIRE_DEVID" -eq 1 ]]; then
  codesign --verify --deep --strict -R="$DR" "$APP" 2>"$WORK/dr.err" || fail "does not satisfy Terminal Deck 0.18.x's designated requirement: $(cat "$WORK/dr.err")"
  ok "satisfies Terminal Deck 0.18.x's designated requirement (Developer ID, team 6U4VNX5W87)"
fi
echo "The update zip passes ShipIt's steps."
