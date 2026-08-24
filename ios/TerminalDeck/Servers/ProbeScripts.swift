/*
 * GENERATED FILE — do not edit by hand.
 *
 * The two scripts the phone runs over SSH, generated from the ones the desktop
 * runs, by `src/main/servers/ios-probe-scripts.test.ts`. That test also checks
 * this file still matches, so an edit here fails the desktop suite rather than
 * quietly making the two sides disagree.
 *
 *     WRITE_IOS_PROBE=1 npx vitest run ios-probe-scripts
 *
 * Raw string literals, because both scripts are full of backslashes that belong
 * to `awk` and would be read as Swift escapes in an ordinary literal.
 */

enum ProbeScripts {
    /// `src/main/servers/probe.sh.ts` — what this machine is, and what it runs.
    static let server = #"""
LC_ALL=C
export LC_ALL
p() { printf '%s=%s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
sec() { printf '#%s %s%s\n' "$1" "$2" "${3:+ $3}"; }

p schema 1
p os      "$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || uname -s 2>/dev/null )"
p kernel  "$(uname -sr 2>/dev/null)"
p arch    "$(uname -m 2>/dev/null)"
p host    "$(hostname 2>/dev/null || uname -n 2>/dev/null)"
p user    "$(id -un 2>/dev/null)"

if   [ "$(id -u 2>/dev/null)" = "0" ];      then p root yes
elif have sudo && sudo -n true 2>/dev/null; then p root sudo-nopasswd
elif have sudo;                             then p root sudo-password
else                                             p root no; fi

if   [ -d /run/systemd/system ];            then INIT=systemd
elif have rc-status;                        then INIT=openrc
elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then INIT=launchd
elif [ -f /etc/inittab ] && have service;   then INIT=sysvinit
elif [ -f /.dockerenv ] || grep -qa 'docker\|containerd\|lxc' /proc/1/cgroup 2>/dev/null; then INIT=container-none
else                                             INIT=unknown; fi
p init "$INIT"

if   have docker && docker info >/dev/null 2>&1; then CTR=docker
elif have podman && podman info >/dev/null 2>&1; then CTR=podman
elif have docker || have podman;                 then CTR=present-no-permission
else                                                  CTR=none; fi
p containers "$CTR"

PKG=
for m in apt-get dnf yum apk pacman zypper pkg brew; do have "$m" && { PKG=$m; break; }; done
p packages "$PKG"

WEB=
for w in nginx apache2 httpd caddy lighttpd; do have "$w" && { WEB=$w; break; }; done
p web "$WEB"

AW="$PATH"
for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.claude/local" "$HOME/.npm-global/bin" \
         "$HOME/.volta/bin" "$HOME/.bun/bin" "$HOME/.asdf/shims" \
         "$HOME/.local/share/mise/shims" /usr/local/bin /opt/homebrew/bin /snap/bin; do
  [ -d "$d" ] && AW="$AW:$d"
done
for d in "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin \
         "$HOME"/.local/share/fnm/node-versions/*/installation/bin; do
  [ -d "$d" ] && AW="$AW:$d"
done

FETCH=
for f in curl wget; do have "$f" && { FETCH=$f; break; }; done
p installer_fetch "$FETCH"
p installer_npm "$(PATH="$AW" command -v npm 2>/dev/null)"
p mem_avail_kb "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
p home_free_kb "$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"

p cpus "$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
p disk_used_kb  "$(df -Pk / 2>/dev/null | awk 'NR==2{print $3}')"
p disk_total_kb "$(df -Pk / 2>/dev/null | awk 'NR==2{print $2}')"
p memory_total_kb "$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
p memory_free_kb  "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
p load1     "$(awk '{print $1}' /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
p uptime_s  "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)"

case "$INIT" in
  systemd)
    if have systemctl; then
      sec services ok
      systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null |
        awk '$2=="loaded"{n=$1;a=$3;s=$4;$1=$2=$3=$4="";sub(/^ +/,"");printf "%s\t%s\t%s\t%s\n",n,a,s,$0}' | head -n 400
    else
      sec services cannot "this server has no way to be asked what it keeps running"
    fi ;;
  openrc)
    sec services ok
    rc-status -s 2>/dev/null | awk -F'[][]' 'NF>1{n=$1;gsub(/^[ \t]+|[ \t]+$/,"",n);s=$2;gsub(/^[ \t]+|[ \t]+$/,"",s);if(n!="")printf "%s\t%s\t%s\t\n",n,s,s}' | head -n 200 ;;
  sysvinit)
    sec services ok
    service --status-all 2>/dev/null | awk '{m=$2;n=$4;if(n!="")printf "%s\t%s\t%s\t\n",n,m,m}' | head -n 200 ;;
  container-none)
    sec services cannot "this is running inside a container, which has nothing of its own that keeps programs running" ;;
  *)
    sec services cannot "we could not tell how this server starts and stops things" ;;
esac

case "$CTR" in
  docker|podman)
    sec containers ok
    $CTR ps -a --no-trunc --format '{{.Names}}	{{.Image}}	{{.State}}	{{.Status}}	{{.Ports}}' 2>/dev/null ||
      $CTR ps -a --no-trunc --format '{{.Names}}	{{.Image}}		{{.Status}}	{{.Ports}}' 2>/dev/null ;;
  present-no-permission)
    sec containers cannot "this sign-in is not allowed to ask this server about its containers" ;;
  *)
    sec containers none ;;
esac

owners() {
  while IFS='	' read -r addr port prog pid; do
    unit=
    if [ -n "$pid" ] && [ -r "/proc/$pid/cgroup" ]; then
      while IFS= read -r cl; do
        case "$cl" in *.service|*.scope|*.slice) unit=${cl##*/} ;; esac
      done < "/proc/$pid/cgroup"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$addr" "$port" "$prog" "$pid" "$unit"
  done
}

if have ss; then
  sec listeners ok
  ss -H -tlnp 2>/dev/null | awk '{la=$4;n=split(la,a,":");port=a[n];addr=substr(la,1,length(la)-length(port)-1);prog="";pid="";if(match($0,/"[^"]+"/))prog=substr($0,RSTART+1,RLENGTH-2);if(match($0,/pid=[0-9]+/))pid=substr($0,RSTART+4,RLENGTH-4);printf "%s\t%s\t%s\t%s\n",addr,port,prog,pid}' | head -n 200 | owners
elif have netstat; then
  sec listeners ok
  netstat -tlnp 2>/dev/null | awk '/LISTEN/{la=$4;n=split(la,a,":");port=a[n];addr=substr(la,1,length(la)-length(port)-1);prog="";pid="";if($NF ~ /\//){split($NF,b,"/");pid=b[1];prog=b[2]}printf "%s\t%s\t%s\t%s\n",addr,port,prog,pid}' | head -n 200 | owners
else
  sec listeners cannot "this server has no tool installed for listing what is listening"
fi

case "$WEB" in
  caddy)
    if [ -r /etc/caddy/Caddyfile ]; then
      sec sites ok
      awk '/^[^ \t#{}].*\{[ \t]*$/{l=$0;sub(/[ \t]*\{[ \t]*$/,"",l);n=split(l,a,/[ \t]*,[ \t]*/);for(i=1;i<=n;i++)if(a[i]!="")printf "%s\n",a[i]}' /etc/caddy/Caddyfile | head -n 100
    else
      sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
    fi ;;
  nginx)
    if nginx -T >/dev/null 2>&1; then
      sec sites ok
      nginx -T 2>/dev/null | awk '/^[ \t]*server_name[ \t]/{for(i=2;i<=NF;i++){g=$i;sub(/;$/,"",g);if(g!=""&&g!="_")print g}}' | sort -u | head -n 100
    elif cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf >/dev/null 2>&1; then
      sec sites ok
      cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf 2>/dev/null |
        awk '/^[ \t]*server_name[ \t]/{for(i=2;i<=NF;i++){g=$i;sub(/;$/,"",g);if(g!=""&&g!="_")print g}}' | sort -u | head -n 100
    else
      sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
    fi ;;
  apache2|httpd)
    if ${WEB}ctl -S >/dev/null 2>&1; then
      sec sites ok
      ${WEB}ctl -S 2>&1 | awk '/namevhost/{print $4}' | sort -u | head -n 100
    else
      sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
    fi ;;
  "")
    sec sites none ;;
  *)
    sec sites cannot "we do not know how to read this web server's settings" ;;
esac
if [ "$INIT" = systemd ] && [ -d /etc/systemd/system ]; then
  sec adminunits ok
  for f in /etc/systemd/system/*.service; do
    [ -e "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done | head -n 200
else
  sec adminunits cannot "we can only tell which programs were added by hand on a server that keeps them this way"
fi

ALOGIN=$("${SHELL:-/bin/sh}" -lc 'command -v claude; command -v codex; command -v gemini; printf "TDENV\t%s\t%s\n" "${CODEX_HOME:-}" "${GEMINI_API_KEY:+k}${GOOGLE_GENAI_USE_VERTEXAI:+v}${GOOGLE_GENAI_USE_GCA:+g}"' 2>/dev/null)
TDENV=$(printf '%s\n' "$ALOGIN" | grep '^TDENV' | head -n 1)
CXH=$(printf '%s' "$TDENV" | cut -f2)
GENV=$(printf '%s' "$TDENV" | cut -f3)
sec agents ok
for a in claude codex gemini; do
  ab=$(PATH="$AW" command -v "$a" 2>/dev/null)
  [ -n "$ab" ] || ab=$(printf '%s\n' "$ALOGIN" | grep "/$a$" 2>/dev/null | head -n 1)
  [ -n "$ab" ] || continue
  av=$("$ab" --version 2>/dev/null | head -n 1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^v?[0-9]+\.[0-9]/) {sub(/^v/,"",$i); print $i; exit}}')
  ai=unknown
  ae=
  if [ -n "$av" ]; then
case "$a" in
claude)
tds=$("$ab" auth status --json 2>/dev/null | tr -d ' \t\n\r')
case "$tds" in
  *'"loggedIn":true'*)  ai=yes ;;
  *'"loggedIn":false'*) ai=no ;;
esac
ae=$(printf '%s' "$tds" | sed -n 's/.*"email":"\([^"]*\)".*/\1/p')
  ;;
codex)
if CODEX_HOME="${CXH:-$HOME/.codex}" "$ab" login status >/dev/null 2>&1; then ai=yes; else ai=no; fi
if [ "$ai" = yes ]; then
  tdt=$(sed -n 's/.*"id_token"[^"]*"\([^"]*\)".*/\1/p' "${CXH:-$HOME/.codex}/auth.json" 2>/dev/null | head -n 1 | cut -d. -f2)
  if [ -n "$tdt" ]; then
    case $(( ${#tdt} % 4 )) in 2) tdt="$tdt==" ;; 3) tdt="$tdt=" ;; esac
    tdp=$(printf '%s' "$tdt" | tr '_-' '/+')
    tdj=$(printf '%s' "$tdp" | base64 -d 2>/dev/null)
    [ -n "$tdj" ] || tdj=$(printf '%s' "$tdp" | base64 -D 2>/dev/null)
    [ -n "$tdj" ] || tdj=$(printf '%s' "$tdp" | openssl base64 -d -A 2>/dev/null)
    ae=$(printf '%s' "$tdj" | tr -d ' \t\n\r' | sed -n 's/.*"email":"\([^"]*\)".*/\1/p' | head -n 1)
  fi
fi
  ;;
gemini)
tdg=$(sed -n 's/.*"selectedType"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)
[ -n "$tdg" ] || tdg=$(sed -n 's/.*"selectedAuthType"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)
[ -n "$tdg" ] || tdg=$GENV
if [ -n "$tdg" ]; then ai=yes; else ai=no; fi
if [ "$ai" = yes ]; then
  ae=$(sed -n 's/.*"active"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.gemini/google_accounts.json" 2>/dev/null | head -n 1)
fi
  ;;
esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$ab" "$av" "$ai" "$ae"
done
printf '#end ok\n'


"""#

    /// `src/main/servers/host.ts` — is the headless host on it, and could it be.
    static let host = #"""
AW="$PATH"
for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.terminaldeck/runtime/bin" \
         "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin /snap/bin; do
  [ -d "$d" ] && AW="$AW:$d"
done
p() { printf "%s\t%s\n" "$1" "$2"; }
have() { PATH="$AW" command -v "$1" >/dev/null 2>&1; }

p os "$(uname -s 2>/dev/null)"
p arch "$(uname -m 2>/dev/null)"
LIBC=gnu
if (ldd --version 2>&1 || true) | grep -qi musl; then LIBC=musl
elif ls /lib/ld-musl-* >/dev/null 2>&1; then LIBC=musl; fi
p libc "$LIBC"

p node "$(PATH="$AW" node --version 2>/dev/null)"
p npm "$(PATH="$AW" command -v npm 2>/dev/null)"
MISS=
have python3 || have python || MISS="$MISS python3"
have make || MISS="$MISS make"
have cc || have gcc || have clang || MISS="$MISS gcc"
have c++ || have g++ || have clang++ || MISS="$MISS g++"
p tools "$MISS"
FETCH=
for f in curl wget; do have "$f" && { FETCH=$f; break; }; done
p fetch "$FETCH"
HASH=
for h in sha256sum shasum openssl; do have "$h" && { HASH=$h; break; }; done
p hash "$HASH"
have tar && p tar yes
p home_free_kb "$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"

# The state folder, XDG first, because that is what the host itself reads.
SD="${XDG_DATA_HOME:-$HOME/.local/share}/terminaldeck"
p state_dir "$SD"
[ -d "$SD" ] && p state yes

# Whether a session on this box could be **held inside the folder it was
# granted** — which is a different question from whether the host will install,
# and the one nobody was asking. A box with no `unshare`, or one whose kernel
# refuses an unprivileged user namespace, takes the install perfectly and then
# throws ConfinementUnavailableError at every session, because `confineSpawn`
# will not pretend a boundary it cannot build. That is an install that looks
# like a success and is a dead end, which is the shape this whole flow exists to
# stop.
#
# Asked by opening the namespace rather than by reading a kernel version, for
# the reason `confine/index.ts` gives about its own proof: the machine can
# change its mind — apparmor_restrict_unprivileged_userns is a sysctl — and a
# version number never knew the answer in the first place. The two sysctls below
# are read only to say *why* after the attempt has already failed, so a person
# gets the machine's own reason rather than "it did not work".
CONF=
CONFWHY=
case "$(uname -s 2>/dev/null)" in
  Linux)
    if ! have unshare; then
      CONFWHY="it has no unshare, which is the util-linux package"
    elif ! have setpriv; then
      CONFWHY="it has no setpriv, which is the util-linux package"
    elif PATH="$AW" unshare --user --map-root-user --mount true >/dev/null 2>&1; then
      CONF=yes
    elif [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" = 0 ]; then
      CONFWHY="user namespaces are switched off on it (user.max_user_namespaces is 0)"
    elif [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
      CONFWHY="its kernel restricts unprivileged user namespaces (apparmor_restrict_unprivileged_userns is 1)"
    else
      CONFWHY="this account cannot open a user namespace on it"
    fi ;;
  Darwin)
    if [ -x /usr/bin/sandbox-exec ]; then CONF=yes; else CONFWHY="it has no sandbox-exec"; fi ;;
esac
p confine "$CONF"
p confine_why "$CONFWHY"

systemctl --user is-system-running >/dev/null 2>&1 && p systemd_user yes
# The unit *file*, not just `is-active`. Measured on a real box: asking
# `is-active` about a unit that does not exist answers "inactive" — so a
# server with no unit of ours and a server whose unit is stopped were
# indistinguishable, and `reachLine` would have claimed the first one starts
# with the machine.
if [ -f "$HOME/.config/systemd/user/terminaldeck.service" ]; then
  p unit "$(systemctl --user is-active terminaldeck.service 2>/dev/null)"
fi
[ "$(loginctl show-user "$(id -u)" -p Linger --value 2>/dev/null)" = yes ] && p linger yes

B=$(PATH="$AW" command -v terminaldeck 2>/dev/null)
p command "$B"
if [ -n "$B" ]; then
  p version "$(PATH="$AW" "$B" --version 2>/dev/null | head -n 1)"
  # The whole answer, verbatim. The running/not-running verdict is decided on
  # the other side rather than grepped here — see readHostProbe.
  printf "%s\n" "--- status ---"
  PATH="$AW" "$B" status 2>&1 | head -n 60
fi
exit 0
"""#
}
