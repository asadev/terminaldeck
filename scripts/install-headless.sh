#!/bin/sh
# Terminal Deck — headless host installer.
#
#     curl -fsSL https://terminaldeck.dev/install.sh | sh
#
# What this is, and what it deliberately is not.
#
# It is a wrapper around `npm install -g terminaldeck`, and that is not a
# cop-out — it is the honest shape of the problem. Sessions are real pseudo
# terminals, so `node-pty` is a native module, and something has to put the right
# prebuilt binary on this machine. npm already does that correctly for every
# platform, architecture and libc this could land on. A hand-rolled installer
# that downloaded a tarball would have to redo that decision, get it wrong on
# Alpine, and be the thing standing between somebody and a working host.
#
# What it adds over typing the npm line yourself:
#
#   - it refuses early, with a sentence, when Node is missing or too old, rather
#     than letting npm fail halfway through a native build;
#   - it installs into a user prefix when the global one is not writable,
#     instead of telling you to re-run the whole thing under sudo;
#   - it says what to do next, which on a server is the part people get wrong —
#     a host installed and never started is indistinguishable from a broken one
#     when you are looking at a phone in another country.
#
# POSIX sh, no bashisms: this runs on whatever /bin/sh a minimal server image
# ships, which is dash as often as not.

set -eu

PACKAGE="terminaldeck"
VERSION="${TERMINALDECK_VERSION:-latest}"
MIN_NODE_MAJOR=22

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------- Node ------

command -v node >/dev/null 2>&1 || die "Node ${MIN_NODE_MAJOR} or newer is required and node is not on PATH.
Install it from https://nodejs.org or with your distribution's package manager, then run this again."

node_version=$(node --version 2>/dev/null | sed 's/^v//')
node_major=$(printf '%s' "$node_version" | cut -d. -f1)

case "$node_major" in
  ''|*[!0-9]*) die "Could not read a version out of \`node --version\` (got '$node_version')." ;;
esac

[ "$node_major" -ge "$MIN_NODE_MAJOR" ] || die "Node $node_version is installed and this needs $MIN_NODE_MAJOR or newer.
The host uses features that are not in older runtimes, and failing here is better
than failing inside a native build."

command -v npm >/dev/null 2>&1 || die "npm is required — it is what places the right node-pty binary for this machine."

# ------------------------------------------------------------- where to put it

# `npm prefix -g` is where a global install lands. On a system Node it is often
# root-owned, and the usual advice at that point is "run it with sudo", which
# installs a user's tool as root and then leaves every future update needing sudo
# too. A user prefix is the better answer and costs one PATH line.
prefix=$(npm prefix -g 2>/dev/null || printf '')
target=""

if [ -n "$prefix" ] && [ -w "$prefix/lib" ] 2>/dev/null; then
  target="global"
else
  target="user"
  npm_config_prefix="${HOME}/.local"
  export npm_config_prefix
  mkdir -p "${HOME}/.local/bin"
fi

say "Installing ${PACKAGE}@${VERSION}…"
npm install -g "${PACKAGE}@${VERSION}" >/dev/null

# ------------------------------------------------------------------- report --

bin_dir=$(npm prefix -g)/bin
say ""
say "Installed to ${bin_dir}"

if ! command -v terminaldeck >/dev/null 2>&1; then
  say ""
  say "${bin_dir} is not on your PATH. Add it:"
  say ""
  say "    export PATH=\"${bin_dir}:\$PATH\""
  say ""
  say "…in your shell's startup file, then open a new shell."
fi

say ""
say "Next:"
say ""
say "    terminaldeck pair      # show a code, type it into your phone, approve it"
say "    terminaldeck status    # what this machine needs to stay reachable"
say ""
say "Read the status output before you rely on this from somewhere else. On a"
say "server it usually says there is nothing to do. Inside WSL it does not: Windows"
say "shuts the distribution down when the last terminal closes, and a phone that"
say "then finds nothing here looks exactly like the app being broken."

if [ "$target" = "user" ]; then
  say ""
  say "(Installed under ${HOME}/.local because the global npm prefix is not writable."
  say " That is deliberate — installing your own tool as root makes every update need sudo.)"
fi
