#!/usr/bin/env bash
# Passkey spare key, signed-app check (Release, 14 Nov). Reads only; prints PASS/FAIL lines; exit 1 on any FAIL.
# Usage: mac-passkey-signing-check.sh <Terminal Deck.app> [baseline app entitlements plist]
#   baseline default: macos/signing/app-entitlements-0220z.plist (the main app's entitlements in 0220z, 84a6e1086)
set -u
APP="$1"; HERE="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${2:-$HERE/macos/signing/app-entitlements-0220z.plist}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
f=0; ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*"; f=1; }
ents(){ codesign -d --entitlements :- "$1" 2>/dev/null | sed -n '/<?xml/,$p'; }
ents "$APP" > "$T/app.plist"
security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$T/profile.plist" 2>/dev/null \
  && ok "embedded.provisionprofile present and Apple-signed" || bad "no readable embedded.provisionprofile"
(cd "$T" && codesign -d --extract-certificates "$APP" >/dev/null 2>&1)
python3 - "$T/app.plist" "$T/profile.plist" "$BASE" "$T/codesign0" "$APP/Contents/Info.plist" <<'PY' || f=1
import plistlib, sys, datetime, os
app_p, prof_p, base_p, leaf_p, info_p = sys.argv[1:]
f = 0
def out(good, text):
    global f
    print(('PASS ' if good else 'FAIL ') + text); f |= (not good)
app = plistlib.load(open(app_p, 'rb')) if os.path.getsize(app_p) else {}
prof = plistlib.load(open(prof_p, 'rb')) if os.path.getsize(prof_p) else {}
base = plistlib.load(open(base_p, 'rb'))
bundle = plistlib.load(open(info_p, 'rb'))['CFBundleIdentifier']
appid = '6U4VNX5W87.' + bundle
out('webcredentials:terminaldeck.dev' in app.get('com.apple.developer.associated-domains', []), 'entitlement webcredentials:terminaldeck.dev')
out(app.get('com.apple.application-identifier') == appid, 'application-identifier ' + appid)
out(app.get('com.apple.developer.team-identifier') == '6U4VNX5W87', 'team-identifier 6U4VNX5W87')
out('keychain-access-groups' not in app, 'no keychain-access-groups (file-based keychain items unchanged)')
missing = [k for k, v in base.items() if app.get(k) != v]
out(not missing, 'every 0220z entitlement still there, same value' + (': missing/changed ' + ', '.join(missing) if missing else f' ({len(base)})'))
pe = prof.get('Entitlements', {})
out(prof.get('TeamIdentifier') == ['6U4VNX5W87'] and pe.get('com.apple.application-identifier') == appid, 'profile is for ' + appid)
out(prof.get('Platform') == ['OSX'] and prof.get('ProvisionsAllDevices') is True, 'profile is Developer ID (macOS, all devices)')
ad = pe.get('com.apple.developer.associated-domains')
out(ad == '*' or (isinstance(ad, list) and 'webcredentials:terminaldeck.dev' in ad), 'profile carries Associated Domains')
exp = prof.get('ExpirationDate')
out(bool(exp) and exp > datetime.datetime.now(), f'profile valid until {exp:%Y-%m-%d}' if exp else 'profile expiry')
leaf = open(leaf_p, 'rb').read() if os.path.exists(leaf_p) else b''
out(bool(leaf) and leaf in prof.get('DeveloperCertificates', []), 'signing certificate is one the profile allows')
sys.exit(f)
PY
# Restricted entitlements only on the main app: helpers, the copied-out keeper and the widget have no profile.
for x in "$APP/Contents/MacOS/TerminalDeckNativeHelper" "$APP/Contents/MacOS/TerminalDeckJSCorePluginHelper" \
         "$APP/Contents/MacOS/TerminalDeckSessionHostHelper" "$APP/Contents/PlugIns/DeckWidgets.appex"; do
  [ -e "$x" ] || continue
  ents "$x" | grep -qE 'associated-domains|application-identifier|team-identifier' \
    && bad "restricted entitlement on $(basename "$x")" || ok "$(basename "$x") without restricted entitlements"
done
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "codesign --deep --strict" || bad "codesign verify"
DR='identifier "dev.terminaldeck.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "6U4VNX5W87"'
codesign --verify --strict -R="$DR" "$APP" 2>/dev/null && ok "same designated requirement as 0220z (updates and Keychain ACLs still match)" || bad "designated requirement changed"
exit $f
