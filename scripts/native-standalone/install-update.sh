#!/bin/bash
# Copied from the signed bundle into private staging before launch. No signals
# are ever sent to the app; this helper waits for a normal exit, then swaps.
set -euo pipefail
umask 077

current_app= staged_app= archive_file= expected_hash= expected_size= expected_version=
bundle_id= executable_name= parent_pid= expected_team= ready_file= relaunch=0
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo 'missing helper argument' >&2; exit 1; }
  case "$1" in
    --current) current_app="$2" ;;
    --staged) staged_app="$2" ;;
    --archive) archive_file="$2" ;;
    --sha512) expected_hash="$2" ;;
    --size) expected_size="$2" ;;
    --version) expected_version="$2" ;;
    --bundle-id) bundle_id="$2" ;;
    --executable) executable_name="$2" ;;
    --parent-pid) parent_pid="$2" ;;
    --team) expected_team="$2" ;;
    --ready) ready_file="$2" ;;
    --relaunch) relaunch="$2" ;;
    *) echo "unknown helper option: $1" >&2; exit 1 ;;
  esac
  shift 2
done

fail() { echo "native update: $*" >&2; exit 1; }
case "$current_app" in /*.app) ;; *) fail 'invalid current app path' ;; esac
case "$staged_app" in /*.app) ;; *) fail 'invalid staged app path' ;; esac
case "$archive_file" in /*/update.zip) ;; *) fail 'invalid archive path' ;; esac
case "$current_app" in /Volumes/*|*/AppTranslocation/*) fail 'move the app into a writable folder first' ;; esac
[[ "$parent_pid" =~ ^[1-9][0-9]*$ ]] || fail 'invalid parent process'
[[ "$expected_size" =~ ^[1-9][0-9]*$ ]] || fail 'invalid archive size'
[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid release version'
[[ "$bundle_id" =~ ^[A-Za-z0-9.-]+$ ]] || fail 'invalid app identifier'
[ -n "$executable_name" ] && [[ "$executable_name" != */* ]] || fail 'invalid app program'
[[ "$expected_team" =~ ^[A-Z0-9]*$ ]] || fail 'invalid signing team'
[ "$relaunch" = 0 ] || [ "$relaunch" = 1 ] || fail 'invalid relaunch choice'
[ "$current_app" != "$staged_app" ] || fail 'staged app is the installed app'
[ ! -L "$current_app" ] && [ ! -L "$staged_app" ] && [ ! -L "$archive_file" ] || fail 'app or archive path is a link'

stage_dir="$(cd "$(dirname "$archive_file")" && /bin/pwd -P)"
case "$staged_app" in "$stage_dir"/unpacked/*.app) ;; *) fail 'staged app is outside its private folder' ;; esac
[ "$ready_file" = "$stage_dir/helper-ready" ] || fail 'invalid acknowledgement path'
app_parent="$(cd "$(dirname "$current_app")" && /bin/pwd -P)"
[ -w "$app_parent" ] || fail 'the app folder is not writable'
[ -d "$current_app/Contents" ] || fail 'current app disappeared'

plist() { /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist"; }
verify_archive() {
  [ "$(/usr/bin/stat -f %z "$archive_file")" = "$expected_size" ] || fail 'archive size changed after download'
  actual_hash="$(/usr/bin/openssl dgst -sha512 -binary "$archive_file" | /usr/bin/openssl base64 -A)"
  [ "$actual_hash" = "$expected_hash" ] || fail 'archive SHA512 changed after download'
}
verify_app() {
  candidate="$1"
  [ "$(plist "$candidate" CFBundleIdentifier)" = "$bundle_id" ] || fail 'staged app identifier differs'
  [ "$(plist "$candidate" CFBundleShortVersionString)" = "$expected_version" ] || fail 'staged app version differs'
  [ "$(plist "$candidate" CFBundleExecutable)" = "$executable_name" ] || fail 'staged program differs'
  [ -x "$candidate/Contents/MacOS/$executable_name" ] || fail 'staged program is missing'
  [ -x "$candidate/Contents/Resources/runtime/bin/node" ] || fail 'bundled Node is missing'
  [ -s "$candidate/Contents/Resources/runtime/manifest.json" ] || fail 'Node manifest is missing'
  [ -s "$candidate/Contents/Resources/engine/manifest.json" ] || fail 'engine manifest is missing'
  [ ! -e "$candidate/Contents/Frameworks/Electron Framework.framework" ] || fail 'Electron app cannot replace the native app'
  /usr/bin/codesign --verify --deep --strict "$candidate" || fail 'staged code signature is invalid'
  if [ -n "$expected_team" ]; then
    actual_team="$(/usr/bin/codesign -dv --verbose=4 "$candidate" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    [ "$actual_team" = "$expected_team" ] || fail 'staged signing team differs'
  fi
}

[ "$(plist "$current_app" CFBundleIdentifier)" = "$bundle_id" ] || fail 'installed app identifier differs'
[ "$(plist "$current_app" CFBundleExecutable)" = "$executable_name" ] || fail 'installed app program differs'
parent_started="$(/bin/ps -p "$parent_pid" -o lstart=)"
[ -n "$parent_started" ] || fail 'parent process already exited before acknowledgement'
verify_archive
verify_app "$staged_app"
/usr/bin/codesign --verify --deep --strict "$current_app" || fail 'current app signature is invalid'
[ ! -e "$stage_dir/helper-cancelled" ] || fail 'helper acknowledgement was cancelled'
echo "native update: verified $expected_version; waiting for process $parent_pid"
: > "$ready_file"

deadline=$((SECONDS + 60))
while /bin/kill -0 "$parent_pid" 2>/dev/null; do
  [ ! -e "$stage_dir/helper-cancelled" ] || fail 'install was cancelled before app termination'
  now_started="$(/bin/ps -p "$parent_pid" -o lstart= 2>/dev/null || true)"
  [ "$now_started" = "$parent_started" ] || break
  [ "$SECONDS" -lt "$deadline" ] || fail 'the app did not exit; no files were moved'
  /bin/sleep 0.25
done
[ ! -e "$stage_dir/helper-cancelled" ] || fail 'install was cancelled before app termination'

# The active bundle has gone away. Recheck anything that could have changed
# while the helper waited, and prepare an adjacent copy on the same filesystem.
verify_archive
verify_app "$staged_app"
work_dir="$(/usr/bin/mktemp -d "$app_parent/.td-native-update.XXXXXX")"
incoming_app="$work_dir/incoming.app"
backup_app="$work_dir/backup.app"
rollback() {
  status="$?"
  if [ "$status" -ne 0 ] && [ -d "$backup_app" ]; then
    if [ -e "$current_app" ]; then
      /bin/mv "$current_app" "$work_dir/failed.app" || true
    fi
    /bin/mv "$backup_app" "$current_app" || true
    echo "native update: install failed; previous app restored at $current_app" >&2
  fi
  exit "$status"
}
trap rollback EXIT
/usr/bin/ditto "$staged_app" "$incoming_app"
verify_app "$incoming_app"
[ ! -L "$current_app" ] && [ -d "$current_app/Contents" ] || fail 'current app changed while waiting'
[ "$(plist "$current_app" CFBundleIdentifier)" = "$bundle_id" ] || fail 'current app changed while waiting'
/bin/mv "$current_app" "$backup_app"
/bin/mv "$incoming_app" "$current_app"
verify_app "$current_app"
echo "native update: installed $expected_version at $current_app"
echo "native update: previous app retained at $backup_app"

# Retain a recovery copy. A successful open command alone cannot prove that the
# new app finished launching, so it is never a reason to delete the old bundle.
if [ "$relaunch" = 1 ]; then
  /usr/bin/open "$current_app" || fail 'the new app could not be opened'
fi
pending_file="$stage_dir/../pending.json"
if [ -f "$pending_file" ] && [ "$(/usr/bin/plutil -extract release.version raw -o - "$pending_file" 2>/dev/null || true)" = "$expected_version" ]; then
  /bin/rm -f "$pending_file"
fi
trap - EXIT
exit 0
