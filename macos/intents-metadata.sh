#!/usr/bin/env bash
# Siri / Shortcuts (lane R): puts the App Intents metadata into the built app.
#
#   macos/intents-metadata.sh <scratch-path> <app-bundle> <deployment-target>
#
# Siri, Shortcuts and Spotlight find an app's intents only through
# Contents/Resources/Metadata.appintents, which Xcode makes with
# `appintentsmetadataprocessor`. `swift build` compiles the intents (and, with
# Xcode 27's toolchain, already writes the compiler's `.swiftconstvalues` for
# them) but never runs that processor — so this does, with the arguments Xcode
# passes, against the module's own source list and const values. Then it checks
# the result: every intent present, and the Siri phrases exactly the ones in
# Sources/TerminalDeckNativeCore/IntentCatalog.swift. Run by build-app.sh before
# signing; needs Xcode (not only the Command Line Tools).
set -euo pipefail

SCRATCH="$1"
APP="$2"
MIN_OS="$3"
MODULE="TerminalDeckNative"
HERE="$(cd "$(dirname "$0")" && pwd)"
CATALOG="$HERE/TerminalDeckNative/Sources/TerminalDeckNativeCore/IntentCatalog.swift"
EXPECTED_INTENTS="AskHootIntent WhatNeedsMeIntent AddTaskIntent StartSessionIntent OpenProjectIntent OpenTerminalDeckIntent GoalStatusIntent"

PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
[ -n "$PROCESSOR" ] || { echo "error: appintentsmetadataprocessor not found — Siri support needs Xcode (xcode-select -s /Applications/Xcode.app)" >&2; exit 1; }

# The release build's compile products for the app module (not Core: no intents there).
LIST="$(find "$SCRATCH/out/Intermediates.noindex" -path "*/Release/*" -name "$MODULE.SwiftFileList" -print 2>/dev/null | head -1)"
[ -n "$LIST" ] || { echo "error: no $MODULE.SwiftFileList under $SCRATCH/out (release build missing?)" >&2; exit 1; }
OBJ="$(dirname "$LIST")"
ARCH="$(basename "$OBJ")"
WORK="$SCRATCH/intents-metadata"
rm -rf "$WORK" && mkdir -p "$WORK"
find "$OBJ" -maxdepth 1 -name '*.swiftconstvalues' > "$WORK/constvalues.list"
[ -s "$WORK/constvalues.list" ] || { echo "error: the compiler wrote no .swiftconstvalues in $OBJ" >&2; exit 1; }
: > "$WORK/dependencies.list"
: > "$WORK/static-dependencies.list"

TOOLCHAIN="$(cd "$(dirname "$(xcrun --find swift)")/../.." && pwd)"
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"

rm -rf "$APP/Contents/Resources/Metadata.appintents"
"$PROCESSOR" \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name "$MODULE" \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "${XCODE_BUILD:-unknown}" \
  --platform-family macOS \
  --deployment-target "$MIN_OS" \
  --bundle-identifier "$BUNDLE_ID" \
  --output "$APP/Contents/Resources" \
  --target-triple "$ARCH-apple-macos$MIN_OS" \
  --binary-file "$APP/Contents/MacOS/$MODULE" \
  --dependency-file "$WORK/dependency_info.dat" \
  --stringsdata-file "$WORK/ExtractedAppShortcutsMetadata.stringsdata" \
  --source-file-list "$LIST" \
  --metadata-file-list "$WORK/dependencies.list" \
  --static-metadata-file-list "$WORK/static-dependencies.list" \
  --swift-const-vals-list "$WORK/constvalues.list" \
  --compile-time-extraction \
  --deployment-aware-processing \
  --no-app-shortcuts-localization \
  --force > "$WORK/processor.log" 2>&1 || { cat "$WORK/processor.log" >&2; exit 1; }
grep -i "error" "$WORK/processor.log" >&2 && exit 1 || true

DATA="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
[ -s "$DATA" ] || { echo "error: no Metadata.appintents was written" >&2; cat "$WORK/processor.log" >&2; exit 1; }

# Proof: every intent is in the metadata, and Siri's phrases are the catalogue's.
/usr/bin/python3 - "$DATA" "$CATALOG" $EXPECTED_INTENTS <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
catalog = open(sys.argv[2]).read()
expected = sys.argv[3:]
actions = data.get("actions", {})
missing = [name for name in expected if name not in actions]
if missing:
    sys.exit("error: App Intents metadata lacks " + ", ".join(missing))
phrases = {t["key"] for s in data.get("autoShortcuts", []) for t in s.get("phraseTemplates", [])}
wanted = set(re.findall(r'"([^"\n]*\$\{applicationName\}[^"\n]*)"', catalog)) - {"${applicationName}"}
if phrases != wanted:
    sys.exit("error: Siri phrases differ from IntentCatalog.swift\n  only in the app: %s\n  only in the catalogue: %s"
             % (sorted(phrases - wanted), sorted(wanted - phrases)))
for shortcut in data.get("autoShortcuts", []):
    own = actions.get(shortcut["actionIdentifier"], {}).get("availabilityAnnotations", {})
    if shortcut.get("availabilityAnnotations", {}).get("LNPlatformNameMACOS") != own.get("LNPlatformNameMACOS"):
        sys.exit("error: the App Shortcut for %s needs a newer macOS than its intent (keep `if #available` shortcuts last)"
                 % shortcut["actionIdentifier"])
entities = sorted(data.get("entities", {}).keys())
schemas = sorted({"%s.%s" % (s["domain"], s["name"]) for a in actions.values() for s in (a.get("assistantDefinedSchemas") or [])})
print("    %d intents, %d App Shortcuts (%d phrases), entities: %s, schemas: %s"
      % (len(actions), len(data.get("autoShortcuts", [])), len(phrases), ", ".join(entities), ", ".join(schemas) or "none"))
PY
