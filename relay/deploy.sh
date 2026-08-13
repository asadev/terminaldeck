#!/usr/bin/env bash
#
# Deploy the rendezvous relay to relay.terminaldeck.dev.
#
# The relay was first put up by hand — bundle, scp, docker run — and that is a
# bad way for the one machine every phone depends on to exist. This script is
# the record of what those commands were, so the box can be rebuilt from nothing
# and so a redeploy is not an act of memory.
#
#   ./relay/deploy.sh            build, ship, restart, verify
#   ./relay/deploy.sh --check    verify only, change nothing
#
# ## What is deployed
#
# One bundled ESM file with **zero runtime dependencies**, run by a stock
# `node:22-alpine` container. There is no npm install on the server, no
# lockfile to drift, and nothing to patch but the base image. `esbuild` is
# already a dependency of the desktop app.
#
# ## Where it sits
#
# On the same Hetzner box as Coolify and the Evolution API — deliberately, so no
# second machine was bought. It joins Coolify's `coolify` network and is routed
# by the Traefik that is already there, with a Let's Encrypt certificate it
# already manages. **Nothing here touches Evolution**, and the script checks that
# it is still healthy afterwards, because "I deployed a relay and broke the
# client's WhatsApp gateway" is the failure worth guarding against.
#
# ## Restarts
#
# `unless-stopped`, and Docker is enabled at boot, so a reboot brings the relay
# back without anyone noticing. A deploy stops the listener politely: hosts
# reconnect on their own with backoff, so a redeploy costs a few seconds of
# reconnects rather than dropped sessions.
set -euo pipefail

HOST="root@178.105.248.86"
KEY="$HOME/.ssh/hetzner_personal"
REMOTE_DIR="/opt/terminaldeck-relay"
CONTAINER="terminaldeck-relay"
DOMAIN="relay.terminaldeck.dev"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ssh_() { ssh -i "$KEY" -o ConnectTimeout=20 "$HOST" "$@"; }

check() {
  say "health"
  curl -fsS --max-time 15 "https://$DOMAIN/healthz" || { echo "relay is not answering"; return 1; }
  echo
  say "container"
  ssh_ "docker inspect $CONTAINER --format 'restart={{.HostConfig.RestartPolicy.Name}} running={{.State.Running}}'"
  say "the neighbour we must not disturb"
  ssh_ "docker ps --filter name=evolution --format '{{.Names}} {{.Status}}'"
}

if [[ "${1:-}" == "--check" ]]; then check; exit 0; fi

say "bundling"
cd "$HERE"
npx --yes esbuild relay/src/main.ts \
  --bundle --platform=node --target=node22 --format=esm \
  --outfile=relay/dist/relay.mjs --log-level=warning
ls -l relay/dist/relay.mjs

# Piped over one connection rather than scp: this box drops rapid repeat
# connections, and a half-written file would be a broken relay.
say "shipping"
ssh_ "mkdir -p $REMOTE_DIR"
< relay/dist/relay.mjs ssh -i "$KEY" "$HOST" "cat > $REMOTE_DIR/relay.mjs && wc -c $REMOTE_DIR/relay.mjs"

say "running"
ssh_ "docker rm -f $CONTAINER >/dev/null 2>&1 || true
docker run -d --name $CONTAINER --restart unless-stopped --network coolify \
  -v $REMOTE_DIR:/app:ro -w /app -e PORT=8080 \
  --label traefik.enable=true \
  --label 'traefik.http.routers.tdrelay.rule=Host(\`$DOMAIN\`)' \
  --label traefik.http.routers.tdrelay.entrypoints=https \
  --label traefik.http.routers.tdrelay.tls=true \
  --label traefik.http.routers.tdrelay.tls.certresolver=letsencrypt \
  --label traefik.http.services.tdrelay.loadbalancer.server.port=8080 \
  --label 'traefik.http.routers.tdrelayhttp.rule=Host(\`$DOMAIN\`)' \
  --label traefik.http.routers.tdrelayhttp.entrypoints=http \
  --label traefik.http.routers.tdrelayhttp.middlewares=tdrelayredir \
  --label traefik.http.middlewares.tdrelayredir.redirectscheme.scheme=https \
  node:22-alpine node relay.mjs >/dev/null"
sleep 6
ssh_ "docker logs --tail 3 $CONTAINER"

check

say "done — TERMINALDECK_LIVE_RELAY=1 npx vitest run src/main/remote/relay-live.test.ts proves a real client can still connect"
