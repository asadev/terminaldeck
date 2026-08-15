#!/usr/bin/env bash
#
# Put the browser client live at app.terminaldeck.dev.
#
#   ./pwa/deploy.sh            check DNS, build on Vercel, promote, verify
#   ./pwa/deploy.sh --check    verify what is live, change nothing
#
# `relay/deploy.sh` is the precedent and the reasoning is the same one: the relay
# was first put up by hand and that is a bad way for a thing people depend on to
# exist. This is the record of what the commands were, so the deployment can be
# rebuilt from nothing and a redeploy is not an act of memory.
#
# ## Why the client has a host of its own
#
# Browsers isolate storage by **origin**, and this client keeps a bearer
# credential and an X25519 private key in web storage — `pwa/src/endpoint.ts`
# argues why it has to. On terminaldeck.dev those bytes would be readable by
# anything that ever lands on the marketing site: an analytics tag, an embedded
# widget, a dependency that changes hands. A path on the same host would not fix
# that; only a different host would, because the origin is the boundary the
# platform actually enforces. Hence `app.` and not `/app`.
#
# ## What is deployed, and what "from source" means here
#
# Vercel runs `npm ci && npm run build` in `pwa/` on its own machine. Nothing
# built on this Mac is uploaded — `.vercelignore` excludes `pwa/dist` on purpose
# — because a `dist/` somebody uploaded is a deployment nobody can reproduce.
# What is uploaded is `pwa/` and `src/shared/`, which is the whole of what the
# client compiles from; the allowlist and the reason for it are in `.vercelignore`.
#
# The project is also linked to `asadev/terminaldeck` on GitHub, so a push to
# `main` that touches `pwa/` or `src/shared/` deploys on its own. Its Ignored
# Build Step is `git diff --quiet HEAD^ HEAD -- pwa src/shared`, so a commit that
# touches neither does not rebuild the client and does not disturb what is live.
# This script is the path for deploying a tree that is not committed yet, and the
# only way to run the checks at the bottom.
#
# ## Credentials
#
# `VERCEL_TOKEN` is required. On Asad's machine it is in the personal credential
# store and is picked up automatically; anywhere else, export it.
#
# `GD_KEY` / `GD_SECRET` are the GoDaddy API key pair for the account that holds
# terminaldeck.dev, and are needed only to *change* DNS. Without them this
# script still checks the record and prints the exact one to create, rather than
# failing at a step nobody can act on.
set -euo pipefail

DOMAIN="app.terminaldeck.dev"
APEX="terminaldeck.dev"
SUBDOMAIN="app"
# Not secrets — the address of the project, in the same spirit as the relay
# script's IP. The token is what grants access, and that is never in here.
VERCEL_ORG_ID="team_k1DViUeE6Svt5eFrMkLQGzBF"
VERCEL_PROJECT_ID="prj_5c2y9Da69XZe8pkSErFkQZUQTQUj"
export VERCEL_ORG_ID VERCEL_PROJECT_ID

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${TERMINALDECK_DEPLOY_ENV:-$HOME/ClaudeAsad/credentials/terminaldeck-vercel.env}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

if [[ -z "${VERCEL_TOKEN:-}" && -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
fi
[[ -n "${VERCEL_TOKEN:-}" ]] || die "no VERCEL_TOKEN — export one, or point TERMINALDECK_DEPLOY_ENV at a file that does"

api() { curl -fsS -H "Authorization: Bearer $VERCEL_TOKEN" "https://api.vercel.com$1?teamId=$VERCEL_ORG_ID"; }

# ---------------------------------------------------------------------- DNS --
#
# The CNAME target is *asked for* rather than remembered. Vercel now hands each
# project its own `<hash>.vercel-dns-NNN.com` and only falls back to the shared
# `cname.vercel-dns.com`, so a value hardcoded here would be right until the
# project was ever recreated and then wrong in a way that looks like a TLS
# failure. `/v6/domains/<d>/config` is the authority; this reads it every run.
#
# Asked of the zone's own nameservers rather than of whatever this machine
# resolves through, and that is not a nicety. A lookup made before the record
# existed leaves an NXDOMAIN cached for the zone's SOA minimum — an hour on
# GoDaddy — so a resolver that has ever been asked will keep saying "nothing"
# long after the record is live. The first run of this script hit exactly that
# and declared a perfectly good DNS change a five-minute failure. The zone is
# the authority on what the zone contains.
authoritative_cname() {
  local ns
  ns="$(dig +short NS "$APEX" | head -1)"
  [[ -n "$ns" ]] || die "$APEX has no nameservers, which is a bigger problem than this deploy"
  dig "@$ns" +short "$DOMAIN" CNAME | head -1 | sed 's/\.$//'
}

dns() {
  local want have code
  want="$(api "/v6/domains/$DOMAIN/config" | node -e '
    let s = ""
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const config = JSON.parse(s)
      const best = (config.recommendedCNAME ?? []).sort((a, b) => a.rank - b.rank)[0]
      if (!best) { console.error("vercel named no CNAME for this domain"); process.exit(1) }
      // Trailing dot stripped: it is how DNS spells absolute and how GoDaddy
      // stores the value are not the same thing, and a mismatched dot would
      // make every run think the record needed changing.
      process.stdout.write(String(best.value).replace(/\.$/, ""))
    })')"

  say "dns — $DOMAIN should be a CNAME to $want"

  have="$(authoritative_cname)"
  if [[ "$have" == "$want" ]]; then
    echo "already answering there"
    return 0
  fi
  echo "answers with: ${have:-nothing}"

  if [[ -z "${GD_KEY:-}" || -z "${GD_SECRET:-}" ]]; then
    cat >&2 <<EOF

This needs a DNS change and there are no GoDaddy credentials in the environment.
terminaldeck.dev answers from ns59/ns60.domaincontrol.com, so the record has to
be created there:

    type   CNAME
    name   $SUBDOMAIN
    value  $want
    ttl    600

Export GD_KEY and GD_SECRET for that GoDaddy account to have this script do it.
EOF
    exit 1
  fi

  code="$(curl -s -o /tmp/td-godaddy.out -w '%{http_code}' -X PUT \
    -H "Authorization: sso-key ${GD_KEY}:${GD_SECRET}" -H 'Content-Type: application/json' \
    "https://api.godaddy.com/v1/domains/$APEX/records/CNAME/$SUBDOMAIN" \
    -d "[{\"data\":\"$want\",\"ttl\":600}]")"
  [[ "$code" == 2* ]] || die "godaddy refused the record (HTTP $code): $(cat /tmp/td-godaddy.out)"
  echo "record written; waiting for it to resolve"

  # Not a fixed sleep: GoDaddy takes a few seconds to push a record out to its
  # own nameservers, and a script that carried on regardless would fail its own
  # checks below and blame the deployment for a DNS delay.
  for _ in $(seq 1 40); do
    [[ "$(authoritative_cname)" == "$want" ]] && { echo "answering"; return 0; }
    sleep 5
  done
  die "the nameservers for $APEX still do not answer $DOMAIN with $want"
}

# -------------------------------------------------------------------- check --
#
# Every assertion here is about the *live* origin, fetched over the real
# internet. A deploy that returned 200 to the CLI and serves the wrong headers
# to a browser is the failure this exists to catch, and it cannot be caught by
# looking at `vercel.json`.
check() {
  local head body csp

  say "tls + document"
  # Retried, because the very first run of this script asked one second after
  # the alias was assigned and got a 404 from an edge that did not know about
  # the domain yet — and then reported a deployment that was in fact fine as a
  # failure. A minute of patience here is cheaper than a false negative that
  # sends somebody looking for a bug in the build.
  for attempt in $(seq 1 12); do
    head="$(curl -fsS -D - -o /tmp/td-app.html "https://$DOMAIN/" 2>/dev/null)" && break
    [[ $attempt == 12 ]] && die "$DOMAIN did not answer over https"
    sleep 5
  done
  printf '%s' "$head" | head -1

  say "headers"
  # Header names are matched case-insensitively because HTTP/2 lowercases them
  # and HTTP/1.1 does not, and a check that passed only over one of the two
  # would be a check that starts failing when a CDN changes protocol.
  want_header() {
    local name="$1" expect="$2" got
    got="$(printf '%s' "$head" | tr -d '\r' | awk -v n="$(printf '%s' "$name" | tr 'A-Z' 'a-z')" \
      'BEGIN{IGNORECASE=1} tolower($1) == n ":" { $1=""; sub(/^ /,""); print }' | head -1)"
    [[ -n "$got" ]] || die "$name is missing from $DOMAIN"
    if [[ -n "$expect" && "$got" != "$expect" ]]; then
      die "$name is \"$got\", expected \"$expect\""
    fi
    printf '  %-32s %s\n' "$name" "$got"
  }

  want_header x-frame-options 'DENY'
  want_header x-content-type-options 'nosniff'
  want_header referrer-policy 'no-referrer'
  want_header strict-transport-security ''
  want_header permissions-policy ''
  want_header content-security-policy ''

  csp="$(printf '%s' "$head" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} tolower($1) == "content-security-policy:" { $1=""; sub(/^ /,""); print }' | head -1)"

  # The relay origin in the CSP is a copy of `DEFAULT_RELAY_URL`, and the copy is
  # the thing that rots. `pwa/tests/headers.test.ts` holds the two against each
  # other at test time; this holds the *served* header against the source at
  # deploy time, which is the version that catches a stale CDN config.
  say "the relay this page may reach"
  node -e '
    const csp = process.argv[1]
    const wanted = process.argv[2]
    const connect = csp.split(";").map((d) => d.trim()).find((d) => d.startsWith("connect-src"))
    if (!connect) { console.error("no connect-src in the CSP — this page can open no socket at all"); process.exit(1) }
    const origin = `wss://${new URL(wanted).host}`
    if (!connect.split(/\s+/).includes(origin)) {
      console.error(`connect-src is "${connect}" and does not include ${origin}`)
      process.exit(1)
    }
    for (const source of connect.split(/\s+/).slice(1)) {
      if (/^(wss|ws|https|http):$/.test(source) || source.includes("*")) {
        console.error(`connect-src allows ${source}, which is a scheme rather than a host`)
        process.exit(1)
      }
    }
    console.log(`  ${connect}`)
  ' "$csp" "$(node -e '
    // Read straight out of the shared module rather than restating it, so this
    // check cannot be the thing that is out of date.
    const src = require("fs").readFileSync("'"$HERE"'/src/shared/relay-wire.ts", "utf8")
    const found = /DEFAULT_RELAY_URL\s*=\s*[\x27"]([^\x27"]+)/.exec(src)
    if (!found) { console.error("DEFAULT_RELAY_URL is not where this expected it"); process.exit(1) }
    process.stdout.write(found[1])
  ')"

  say "the bundle the document asks for"
  # A 200 on `/` proves the CDN answered, not that it is serving this client. The
  # document names one hashed module; fetching it is what proves a real build is
  # behind the domain.
  body="$(node -e '
    const html = require("fs").readFileSync("/tmp/td-app.html", "utf8")
    const found = /<script[^>]+src="([^"]+\.js)"/.exec(html)
    if (!found) { console.error("the document names no module — that is not this client"); process.exit(1) }
    process.stdout.write(found[1])
  ')"
  curl -fsS -o /dev/null -w "  %{http_code}  %{size_download} bytes  $body\n" "https://$DOMAIN$body" \
    || die "the document names $body and the origin does not serve it"

  say "the service worker"
  curl -fsS -o /dev/null -w "  %{http_code}  %{header_json}\n" "https://$DOMAIN/sw.js" >/dev/null \
    || die "no service worker at /sw.js — an installed client cannot update"
  echo "  200"

  say "the relay it will dial"
  curl -fsS --max-time 15 "https://$(node -e '
    const src = require("fs").readFileSync("'"$HERE"'/src/shared/relay-wire.ts", "utf8")
    process.stdout.write(new URL(/DEFAULT_RELAY_URL\s*=\s*[\x27"]([^\x27"]+)/.exec(src)[1]).host)
  ')/healthz" || die "the relay is not answering, so nothing paired through it will connect"
  echo
}

if [[ "${1:-}" == "--check" ]]; then check; exit 0; fi

dns

say "building on vercel"
cd "$HERE"
# `--prod` promotes, `--yes` skips the "link to which project?" prompt that the
# env vars above have already answered.
npx --yes vercel@latest deploy --prod --yes --token "$VERCEL_TOKEN" | tee /tmp/td-deploy.out

check

say "live — https://$DOMAIN"
