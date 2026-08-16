#!/usr/bin/env bash
#
# Build the demo box from nothing, or bring it up to date.
#
#   ./demo/deploy.sh              provision, build the image, ship the broker
#   ./demo/deploy.sh --check      verify only, change nothing
#   ./demo/deploy.sh --escapes    run the escape table against a live container
#
# ## What this machine is
#
# A Hetzner CX23 that exists so an App Review engineer in Cupertino can attach to
# a real Linux shell. It is deliberately **not** the relay box: a stranger's shell
# there would sit one bridge network away from `coolify-db`, from
# `/data/coolify/ssh`, and from a paying client's WhatsApp gateway. Four euros
# fifty a month is not a saving worth that.
#
# Nothing of ours is on it. No tailnet, no ssh key but the one that reaches it, no
# cloud token, no git credential, no repository. If it is taken tomorrow the loss
# is a README and four euros.
#
# ## The two settings that are not obvious and are not optional
#
# **`userns-remap`.** Container root maps to host uid 100000, an account that owns
# nothing. This is what makes it affordable to give a visitor's container
# CAP_SYS_ADMIN, which `demo-shell` needs for the one mount namespace it builds
# and which `setpriv` takes away again before the visitor sees a prompt.
#
# **Egress default-deny on the demo network.** A shell can `curl`, and that is the
# largest practical danger here: port scanning, spam, mining, or using our address
# as a proxy. Hetzner suspends boxes for abuse and the reputation is ours. The
# rules below allow DNS and the relay and drop everything else — which means `git
# clone` and `npm install` do not work in the demo, and the session's motd says so
# in a sentence, because a reviewer who reads a firewall as a broken app is a
# rejection we wrote ourselves.
set -euo pipefail

HOST="${DEMO_SSH_HOST:-terminaldeck-server}"
REMOTE_DIR=/opt/terminaldeck-demo
IMAGE=terminaldeck-demo:latest
NETWORK=td-demo
SUBNET=172.31.240.0/24
RELAY_IP=178.105.248.86
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ssh_() { ssh -o ConnectTimeout=25 "$HOST" "$@"; }

check() {
  say "broker"
  ssh_ "systemctl is-active terminaldeck-demo-broker || true; curl -fsS localhost:8787/healthz || true"
  say "image"
  ssh_ "docker images $IMAGE --format '{{.Repository}}:{{.Tag}} {{.Size}} {{.CreatedSince}}'"
  say "egress rules"
  ssh_ "iptables -S DOCKER-USER"
  say "docker daemon"
  ssh_ "docker info --format 'userns-remap: {{.SecurityOptions}}'"
  say "containers"
  ssh_ "docker ps --format '{{.Names}} {{.Status}}'"
}

if [[ "${1:-}" == "--check" ]]; then check; exit 0; fi
if [[ "${1:-}" == "--escapes" ]]; then
  ssh_ "cd $REMOTE_DIR && bash escapes.sh"
  exit $?
fi

# ------------------------------------------------------------------- build --

say "building the headless host"
cd "$HERE"
npm run dist:headless

say "staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/context"

# `COPYFILE_DISABLE=1`, and it is not a tidiness flag.
#
# bsdtar on macOS writes an AppleDouble sidecar — `._name` — for any file
# carrying an extended attribute, and copies them into the archive as ordinary
# members. The tree here is clean and stayed clean; it is the *archive* that
# grew them. So deploying from this Mac put `._README.md` and `._hello.sh` in the
# build context on the box, `docker build` baked them into `/opt/demo-seed`, and
# the *first thing an App Review engineer saw* on "a real Linux machine in
# Germany" was two files of macOS resource-fork metadata sitting in their
# playground — `ls -a ~/playground` on the live box, 2026-08-16. Every one of the
# twenty-two escape tests passed the whole time, because nothing about it is a
# security question.
#
# It is also the exact shape of failure this project keeps re-finding: it cannot
# reproduce on the machine that causes it. The archive is correct on any Linux
# CI, and whether a given checkout triggers it depends on which files happen to
# have picked up `com.apple.quarantine` or `com.apple.provenance` — so a deploy
# that was clean yesterday can ship junk today with nothing in the tree changed.
# Belt and braces on purpose: the variable stops them being written, the exclude
# stops any that a future tool creates anyway, and neither costs anything.
export COPYFILE_DISABLE=1
cp -R out/headless "$STAGE/context/headless"
cp -R demo/image "$STAGE/context/image"
cp demo/Dockerfile "$STAGE/context/Dockerfile"
cp demo/escapes.sh "$STAGE/escapes.sh"
mkdir -p "$STAGE/broker"
cp demo/broker/broker.mjs "$STAGE/broker/"
cp demo/broker/terminaldeck-demo-broker.service "$STAGE/broker/"
cp demo/Caddyfile "$STAGE/Caddyfile"

# ------------------------------------------------------------- provisioning --

say "provisioning the box"
ssh_ "bash -s" <<PROVISION
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Unattended upgrades, because this machine will be forgotten about between App
# Store submissions and Apple re-tests old versions months later.
apt-get update -qq
apt-get install -y -qq docker.io unattended-upgrades nodejs caddy >/dev/null 2>&1 || {
  # Caddy is not in Ubuntu's own archive. Its repository is added once, here,
  # rather than being a step somebody has to remember.
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq docker.io unattended-upgrades nodejs caddy >/dev/null
}
systemctl enable --now docker >/dev/null 2>&1 || true

# userns-remap. Written with python rather than a heredoc so that running this a
# second time does not throw away whatever else is in daemon.json.
python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
cfg = json.load(open(p)) if os.path.exists(p) else {}
if cfg.get("userns-remap") != "default":
    cfg["userns-remap"] = "default"
    json.dump(cfg, open(p, "w"), indent=2)
    print("daemon.json updated")
PY
systemctl restart docker
sleep 3

# The network every visitor's container joins, with a fixed subnet so the egress
# rules can name it. Docker assigns from a pool otherwise, and a firewall rule
# written against yesterday's pool is a firewall rule that stopped working.
#
# `enable_icc=false` is the second visitor.
#
# The egress rules in DOCKER-USER do not see container-to-container traffic on
# one bridge: that is bridged, not routed, and this kernel has no `br_netfilter`
# loaded at all (`/proc/sys/net/bridge/bridge-nf-call-iptables` does not exist),
# so it never reaches an iptables chain. Measured on the live box with four
# visitors up: one container could open a TCP connection to another's address.
# Nothing answered — every listener a demo container has is bound to 127.0.0.1,
# so the scan came back refused on every port — but "there is nothing to reach"
# is a fact about today's process list, and the fence should not depend on one.
# With icc off the packet does not arrive in the first place.
#
# Recreated rather than left alone when the flag is missing, and that matters:
# `docker network create` cannot change an existing network, so the plain
# `inspect || create` below would have quietly kept a box provisioned before this
# comment on the old settings forever — the deploy would report success and
# change nothing. It is safe here because `systemctl restart docker` a few lines
# up has already taken every `--rm` visitor container with it, so nothing is
# attached at this point in the script.
if docker network inspect $NETWORK >/dev/null 2>&1; then
  if [ "\$(docker network inspect $NETWORK -f '{{index .Options "com.docker.network.bridge.enable_icc"}}')" != "false" ]; then
    echo "the demo network predates enable_icc=false; recreating it"
    docker network rm $NETWORK >/dev/null
  fi
fi
docker network inspect $NETWORK >/dev/null 2>&1 || \
  docker network create --subnet $SUBNET \
    -o com.docker.network.bridge.enable_icc=false $NETWORK >/dev/null

mkdir -p $REMOTE_DIR
PROVISION

# ------------------------------------------------------------ egress rules --

# Written as a script on the box rather than inline, because they have to be
# reapplied after every reboot — Docker rebuilds its own chains — and a rule that
# only exists until the next restart is a rule that will not be there on the day
# it matters.
say "egress rules"
ssh_ "cat > /usr/local/sbin/td-demo-firewall" <<FIREWALL
#!/bin/bash
# Default-deny egress for the demo network. See demo/deploy.sh for why.
#
# DOCKER-USER is the chain Docker leaves alone, and it is consulted for every
# FORWARDed packet — which is everything a container sends to the world. The
# container's traffic to the *host itself* is not forwarded, so the INPUT rules
# below are a separate matter and are not a duplicate.
set -e
SUBNET=$SUBNET
RELAY=$RELAY_IP

# Idempotent: the whole set is removed and rebuilt, because appending to a chain
# on every deploy is how a firewall ends up with sixty copies of one rule and an
# order nobody can predict.
iptables -S DOCKER-USER | grep -- '--comment td-demo' | sed 's/^-A/-D/' | while read -r rule; do
  iptables \$rule 2>/dev/null || true
done
iptables -S INPUT | grep -- '--comment td-demo' | sed 's/^-A/-D/' | while read -r rule; do
  iptables \$rule 2>/dev/null || true
done

# Order matters and iptables -I inserts at the top, so the DROP goes in first and
# everything allowed is inserted above it afterwards.
iptables -I DOCKER-USER 1 -s \$SUBNET -m comment --comment td-demo -j DROP
iptables -I DOCKER-USER 1 -s \$SUBNET -d \$RELAY -p tcp --dport 443 -m comment --comment td-demo -j RETURN
iptables -I DOCKER-USER 1 -s \$SUBNET -p udp --dport 53 -m comment --comment td-demo -j RETURN
iptables -I DOCKER-USER 1 -s \$SUBNET -p tcp --dport 53 -m comment --comment td-demo -j RETURN
iptables -I DOCKER-USER 1 -s \$SUBNET -m state --state ESTABLISHED,RELATED -m comment --comment td-demo -j RETURN

# The host is not the internet, and a container reaching the broker on 8787 could
# ask for more containers. Everything to the host is dropped except DNS, which
# Docker's embedded resolver forwards on the container's behalf.
iptables -I INPUT 1 -s \$SUBNET -m comment --comment td-demo -j DROP
iptables -I INPUT 1 -s \$SUBNET -p udp --dport 53 -m comment --comment td-demo -j ACCEPT
iptables -I INPUT 1 -s \$SUBNET -p tcp --dport 53 -m comment --comment td-demo -j ACCEPT
FIREWALL
ssh_ "chmod 0755 /usr/local/sbin/td-demo-firewall && /usr/local/sbin/td-demo-firewall && iptables -S DOCKER-USER | head"

ssh_ "cat > /etc/systemd/system/td-demo-firewall.service" <<'UNIT'
[Unit]
Description=Terminal Deck demo egress rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/td-demo-firewall

[Install]
WantedBy=multi-user.target
UNIT
ssh_ "systemctl daemon-reload && systemctl enable --now td-demo-firewall >/dev/null 2>&1 || true"

# ------------------------------------------------------------------- ship --

say "shipping"
# The `find -delete` is for a box that was deployed *before* the export above
# existed. `tar -x` does not remove what it does not carry, so a machine that
# already has `._README.md` in its build context keeps it forever and rebuilds
# the same contaminated image on every deploy — the fix has to reach backwards
# or it only helps machines nobody has deployed to yet.
tar -C "$STAGE" --exclude '._*' -czf - . | ssh_ "find $REMOTE_DIR -name '._*' -delete 2>/dev/null; tar -C $REMOTE_DIR -xzf -"

say "building the image"
ssh_ "cd $REMOTE_DIR/context && docker build -q -t $IMAGE . && docker images $IMAGE --format '{{.Size}}'"

say "broker"
ssh_ "install -m 0644 $REMOTE_DIR/broker/terminaldeck-demo-broker.service /etc/systemd/system/ \
  && systemctl daemon-reload \
  && systemctl enable --now terminaldeck-demo-broker \
  && systemctl restart terminaldeck-demo-broker"

say "caddy"
ssh_ "install -m 0644 $REMOTE_DIR/Caddyfile /etc/caddy/Caddyfile && systemctl reload caddy || systemctl restart caddy"

check
