import Foundation

/// Exact Mac script template from open-shim.ts. Construction performs no I/O.
public enum BackendMacAppHandoffOpenShimScript {
    public static func make(realOpener: String, configPath: String) -> String {
        (source + "\n").replacingOccurrences(of: "__TD_REAL_OPENER__", with: quote(realOpener))
            .replacingOccurrences(of: "__TD_CONFIG_PATH__", with: quote(configPath))
    }
    public static func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "'\\''") }
    private static let source = #"""
#!/bin/sh
# Written by Terminal Deck at every start, and deleted when it quits.
# Do not edit: this file is regenerated, and an edit here would be lost on the
# next launch while looking permanent in between.
#
# It exists so that a URL opened by an agent inside a session lands in that
# session's own browser window instead of in a browser somewhere else on the
# machine. Everything that is not a http(s) URL is handed straight to the real
# opener with its arguments untouched.

# Absolute, and never a PATH lookup: this directory is FIRST on PATH, so a
# lookup would find this script and exec it for ever, on every URL, in every
# session.
REAL_OPENER='__TD_REAL_OPENER__'
CONFIG='__TD_CONFIG_PATH__'

open_for_real() {
  if [ -x "$REAL_OPENER" ]; then
    exec "$REAL_OPENER" "$@"
  fi
  printf '%s\n' "Could not open $1: no opener at $REAL_OPENER" >&2
  exit 1
}

# 1. Anything that is not exactly one argument is not a plain "open this URL".
[ "$#" -eq 1 ] || open_for_real "$@"

# 2 and 3. A flag, or an argument that is not a http(s) URL — a folder, a file,
# a custom scheme. Mixed-case schemes fall through here too, which fails in the
# safe direction: the URL still opens, just not in the app.
case "$1" in
  http://*|https://*|HTTP://*|HTTPS://*|Http://*|Https://*) ;;
  *) open_for_real "$@" ;;
esac

# 4. Ask the app. The session id is what ties this URL to the tab he is looking
# at; the config file holds the socket path and this run's token, exactly as the
# hook commands read it.
ANSWER=$(printf '%s' "$1" | curl -s \
  --connect-timeout 1 \
  --max-time 3 \
  -X POST \
  -H 'content-type: text/plain' \
  -H "x-terminaldeck-session: $TERMINALDECK_SESSION_ID" \
  -K "$CONFIG" \
  --data-binary @- \
  'http://localhost/open' 2>/dev/null)

ROUTE=$(printf '%s\n' "$ANSWER" | head -n 1)
LINE=$(printf '%s\n' "$ANSWER" | sed -n '2,$p')

if [ "$ROUTE" = "tab" ]; then
  printf '%s\n' "$LINE"
  exit 0
fi

# Everything else lands here: the app said "system", the app is not running, the
# socket refused, curl timed out, or the answer was something this script does
# not understand. All of them mean the same thing to whoever ran the command —
# the app did not take it, so the machine gets it — and all of them say so out
# loud rather than exiting 0 having done nothing.
if [ -n "$LINE" ]; then
  printf '%s\n' "$LINE"
else
  printf '%s\n' "Terminal Deck did not take this link — opening it in your default browser."
fi
open_for_real "$@"
"""#
}
