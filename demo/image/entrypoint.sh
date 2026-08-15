#!/bin/bash
#
# PID 1 of one visitor's container.
#
# It does three things and then becomes the demo host, which is what the rest of
# the container's life is. Everything below runs as the container's root — which,
# because the daemon on the demo box runs with `userns-remap`, is host uid 100000
# and owns nothing outside this container.
#
#  1. **Lay out the playground from the seed.** The seed lives on the image's
#     read-only layer, and the visitor's home is a tmpfs, so this is the copy
#     that makes the folder writable. It also means the reset between visitors is
#     structural: the next container starts from the same read-only seed, not
#     from whatever the last one left behind.
#
#  2. **Prove the relay is reachable before offering anybody a machine.** Not
#     strictly necessary — the host retries on its own — but a container that
#     cannot dial out is a slot the broker would hand to a visitor who then waits
#     for a pairing that can never complete, and the honest failure is this one,
#     here, where the broker can see it.
#
#  3. **exec the demo host**, so it is PID 1 and gets `docker stop`'s SIGTERM
#     directly rather than through a shell that would swallow it.
set -euo pipefail

VISITOR_UID="${DEMO_VISITOR_UID:-1001}"
VISITOR_GID="${DEMO_VISITOR_GID:-1001}"
VISITOR_HOME="${DEMO_VISITOR_HOME:-/home/visitor}"
PLAYGROUND="${TERMINALDECK_DEMO_PLAYGROUND:-$VISITOR_HOME/playground}"
SEED="${DEMO_SEED:-/opt/demo-seed}"

# ------------------------------------------------------------- the playground --

# Mode first, owner second, and that order is not a style choice — it is the
# first thing that broke on the real box. The container holds CHOWN but not
# FOWNER, so once a directory belongs to the visitor this process can no longer
# change its permissions: `install -d -m 0700 -o 1001` chowns and then chmods,
# and failed with "Operation not permitted" on a directory it had just created.
mkdir -p "$VISITOR_HOME" "$PLAYGROUND"
# 0711, not 0700, and the difference is a whole afternoon.
#
# The container holds CAP_CHOWN and deliberately not CAP_DAC_OVERRIDE, so its
# root is subject to ordinary permission checks like anybody else. With the home
# at 0700 and owned by the visitor, root could not traverse into it — which broke
# two things at once: `demo-shell` could not bind the playground, and the host
# process could not have started a session there either, because node-pty spawns
# with that directory as its cwd. 0711 is traversable and still not listable, so
# nothing can enumerate the visitor's home but the paths through it work.
chmod 0711 "$VISITOR_HOME"
chmod 0755 "$PLAYGROUND"
cp -a "$SEED/." "$PLAYGROUND/"

# A git repository with real history, made here rather than committed into this
# repository's own tree: a `.git` directory inside a `.git` directory is a thing
# that confuses tools for years afterwards. The identity is deliberately not a
# person — `git log` in the demo must not print anybody's real address.
if [ ! -d "$PLAYGROUND/.git" ]; then
  (
    cd "$PLAYGROUND"
    export HOME="$VISITOR_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    git init -q -b main
    git -c user.name='Terminal Deck demo' -c user.email='demo@terminaldeck.invalid' \
      add -A
    git -c user.name='Terminal Deck demo' -c user.email='demo@terminaldeck.invalid' \
      commit -q -m 'The playground, as every visitor finds it'
  )
fi

# Last, for the reason above: after this the visitor owns it and this process
# cannot change its permissions again.
chown -R "$VISITOR_UID:$VISITOR_GID" "$PLAYGROUND"
chown "$VISITOR_UID:$VISITOR_GID" "$VISITOR_HOME"

# ------------------------------------------------------------------ the relay --

# One TCP connect, no payload. `getent hosts` first so that a DNS failure and a
# routing failure are two different messages in the broker's log rather than one
# vague one — the egress rules deny almost everything on this box, and telling
# "the firewall is too tight" from "the relay is down" at three in the morning is
# worth the extra line.
RELAY_HOST="${TERMINALDECK_DEMO_RELAY_HOST:-relay.terminaldeck.dev}"
if ! getent hosts "$RELAY_HOST" >/dev/null; then
  echo "This container cannot resolve $RELAY_HOST. DNS is denied or broken." >&2
  exit 1
fi
if ! timeout 8 bash -c "exec 3<>/dev/tcp/$RELAY_HOST/443" 2>/dev/null; then
  echo "This container resolved $RELAY_HOST but could not open a socket to it." >&2
  exit 1
fi

# -------------------------------------------------------------------- the host --

exec node /opt/terminaldeck/demo.mjs
