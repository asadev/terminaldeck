#!/usr/bin/env bash
# Sourced by macos/build-app.sh just before the outer app is signed (after every nested item).
# Passkey spare key (14 Nov): a Developer ID signed dev.terminaldeck.app embeds the Developer ID provisioning profile
# and signs the MAIN app with the passkey entitlements merged into its existing ones. Helpers, the keeper and the
# widget keep their entitlements exactly (a restricted entitlement on them would get them killed: they have no profile,
# and the keeper is copied out of the bundle).
#   TD_MAC_APP_PROFILE   unset: the committed profile (signed release builds only); a path: that profile;
#                        "none": the 0220z signature (no profile, no passkey) - the rollback switch.
# Usage: td_mac_app_profile <app> <identity> <entitlements in>   -> prints the entitlements file to sign the app with
td_mac_app_profile() {
  local app="$1" identity="$2" base="$3" here bundle profile team appid tmp merged
  here="${TD_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"  # TD_REPO_ROOT: callers in zsh
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  profile="${TD_MAC_APP_PROFILE:-}"
  if [ "$profile" = none ] || { [ -z "$profile" ] && { [ "$identity" = "-" ] || [ "$bundle" != dev.terminaldeck.app ]; }; }; then
    printf '%s\n' "$base"; return 0   # ad-hoc, test copies and the switch-off: exactly as before
  fi
  [ -n "$profile" ] || profile="$here/macos/signing/dev.terminaldeck.app.developer-id.provisionprofile"
  [ "$identity" != "-" ] || { echo "error: TD_MAC_APP_PROFILE needs a Developer ID signature, not ad-hoc" >&2; return 1; }
  [ -r "$profile" ] || { echo "error: provisioning profile $profile is missing" >&2; return 1; }
  tmp="$(mktemp -d)"
  security cms -D -i "$profile" > "$tmp/profile.plist" 2>/dev/null || { echo "error: $profile is not a signed profile" >&2; rm -rf "$tmp"; return 1; }
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$tmp/profile.plist")"
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$tmp/profile.plist")"
  if [ "$appid" != "$team.$bundle" ] || [ "$team" != 6U4VNX5W87 ]; then
    echo "error: profile is for $appid, app is $team.$bundle" >&2; rm -rf "$tmp"; return 1
  fi
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.associated-domains' "$tmp/profile.plist" >/dev/null 2>&1 \
    || { echo "error: profile has no Associated Domains" >&2; rm -rf "$tmp"; return 1; }
  if [ -e "$app/Contents/embedded.provisionprofile" ] && ! cmp -s "$profile" "$app/Contents/embedded.provisionprofile"; then
    echo "error: the app already embeds another profile (TD_APP_GROUP_PROFILE?); one profile per app" >&2; rm -rf "$tmp"; return 1
  fi
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  merged="$tmp/app-passkey.entitlements"
  python3 - "$base" "$here/macos/MainAppPasskey.entitlements" "$merged" <<'PY' || { rm -rf "$tmp"; return 1; }
import plistlib, sys
base = plistlib.load(open(sys.argv[1], 'rb')); extra = plistlib.load(open(sys.argv[2], 'rb'))
clash = [k for k in extra if k in base and base[k] != extra[k]]
if clash: sys.exit('error: entitlement clash ' + ', '.join(clash))
base.update(extra)
plistlib.dump(base, open(sys.argv[3], 'wb'))
PY
  echo "==> passkey: embedded profile $(/usr/libexec/PlistBuddy -c 'Print :UUID' "$tmp/profile.plist"), webcredentials:terminaldeck.dev on the main app only" >&2
  printf '%s\n' "$merged"
}
