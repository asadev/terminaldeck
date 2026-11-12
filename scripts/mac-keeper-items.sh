#!/usr/bin/env bash
# Sourced by build-app.sh. Copies the session keepers' background items into the app (Contents/Library/LaunchAgents).
# The release app keeps the production labels. Any other bundle id (a test or scratch copy) gets labels of its own,
# so a test copy can never register under the production label (review-one-name-0609 #3; 6 Nov rule).
td_install_keeper_items() {
  local source_dir="$1" app="$2" bundle_id="$3" item target label
  case "$bundle_id" in ''|*[!A-Za-z0-9.-]*) echo 'error: invalid bundle id for the keeper items' >&2; return 1 ;; esac
  mkdir -p "$app/Contents/Library/LaunchAgents"
  for item in "$source_dir"/*.plist; do
    target="$app/Contents/Library/LaunchAgents/$(basename "$item")"
    cp "$item" "$target"
    plutil -replace AssociatedBundleIdentifiers -json "[\"$bundle_id\"]" "$target"
    if [ "$bundle_id" != dev.terminaldeck.app ]; then
      label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$target")"
      plutil -replace Label -string "$bundle_id${label#dev.terminaldeck}" "$target"
    fi
  done
}
