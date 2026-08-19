/**
 * The one round trip that works out what a server actually is.
 *
 * ## Why this is a script rather than a conversation
 *
 * Every question below could be its own command, and asking them one at a time
 * would be much easier to read. It would also be thirty round trips to a
 * machine that may be on another continent — and the standing rule this feature
 * is built under is his: **events, not polling**, *"they make the system
 * heavier."* One connection, one script, one answer, and then the connection
 * goes away when nobody is looking at the page. Measured on the test box, the
 * whole thing costs **293 ms** of the server's time and returns about 12 KB.
 *
 * ## Why POSIX `sh` and not `bash`
 *
 * Because `bash` is not there on plenty of real servers — Alpine ships `ash`,
 * and the smallest containers ship `dash` or nothing beyond `busybox`. Every
 * construct below is POSIX: no arrays, no `[[`, no `local`, no process
 * substitution, no `$'...'`. It is delivered on the far end's standard input to
 * `sh -s` rather than pasted into a command line, which also means it never
 * appears in the process list, in a shell history, or in a length limit.
 *
 * ## Every question can answer "not this way"
 *
 * That is the whole shape of the file. Nothing here assumes systemd, or a
 * container runtime, or a package manager, or that the account signing in is
 * allowed to ask. Each block ends in a branch that says plainly it could not
 * tell, and {@link parseProbe} turns that into the `cannot` state of
 * `Fact` — not into a zero, a dash, or an empty card.
 *
 * A worked example, measured rather than imagined. Run inside a Debian container
 * with nothing installed, the sections come back:
 *
 *     #services cannot this is running inside a container, which has nothing
 *                      of its own that keeps programs running
 *     #containers none
 *     #listeners cannot this server has no tool installed for listing what is
 *                       listening
 *     #sites none
 *
 * Four different honest answers, none of which is "0".
 *
 * ## Two things that were measured and changed the script
 *
 * **`systemctl list-unit-files --state=enabled` is not affordable.** It is the
 * obvious way to learn which services are *meant* to be running, and it cost
 * **1,060 ms** on the test box against 26 ms for `list-units --all` — five times
 * the entire rest of the probe, because it stats every unit file on disk. So
 * enablement is not collected, and the things that deserve a card are found the
 * two cheap ways instead: a unit whose own file sits in `/etc/systemd/system`
 * (somebody added it here), and a unit that owns a listening port.
 *
 * **The owner of a listening port is worth a section of its own.** Knowing that
 * something called `node` is on port 8787 is close to useless; knowing that the
 * process on port 8787 belongs to a *named service* is what lets a card say
 * "your website" and offer it a Restart button. It is read out of the process's
 * own cgroup line, which names the service or container it belongs to, and the
 * loop that does it uses shell redirection and the `read` builtin so that two
 * hundred listeners cost zero extra processes.
 *
 * ## The output format
 *
 * Scalars first, one `key=value` per line, and an empty value means the server
 * would not say — which becomes `cannot`, never `no`. Then sections, each
 * introduced by a line beginning `#`:
 *
 *     #<name> ok                 rows follow, tab separated
 *     #<name> none               there are none, and that is a fact about the server
 *     #<name> cannot <sentence>  we could not find out, and this is why
 *
 * `#end ok` is the last line. Its absence means the script was cut off, and
 * {@link parseProbe} says so on the sections that never arrived rather than
 * reporting them as empty.
 */

import {
  factCannot,
  factNo,
  factYes,
  CONTAINER_NUMBERS_WHY,
  type ContainerFact,
  type ContainerRuntime,
  type DiskFact,
  type Fact,
  type InitSystem,
  type ListenerFact,
  type MemoryFact,
  type Privilege,
  type RunState,
  type ServerFacts,
  type ServiceFact,
} from './facts'

/**
 * The script, exactly as it is sent.
 *
 * Kept as one string rather than assembled from pieces so that what ships is
 * what was measured. It is delivered on standard input; see `connection.ts`.
 */
export const PROBE_SCRIPT = `LC_ALL=C
export LC_ALL
p() { printf '%s=%s\\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
sec() { printf '#%s %s%s\\n' "$1" "$2" "\${3:+ $3}"; }

p schema 1
p os      "$( (. /etc/os-release 2>/dev/null && printf '%s' "\${PRETTY_NAME:-}") || uname -s 2>/dev/null )"
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
elif [ -f /.dockerenv ] || grep -qa 'docker\\|containerd\\|lxc' /proc/1/cgroup 2>/dev/null; then INIT=container-none
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
        awk '$2=="loaded"{n=$1;a=$3;s=$4;$1=$2=$3=$4="";sub(/^ +/,"");printf "%s\\t%s\\t%s\\t%s\\n",n,a,s,$0}' | head -n 400
    else
      sec services cannot "this server has no way to be asked what it keeps running"
    fi ;;
  openrc)
    sec services ok
    rc-status -s 2>/dev/null | awk -F'[][]' 'NF>1{n=$1;gsub(/^[ \\t]+|[ \\t]+$/,"",n);s=$2;gsub(/^[ \\t]+|[ \\t]+$/,"",s);if(n!="")printf "%s\\t%s\\t%s\\t\\n",n,s,s}' | head -n 200 ;;
  sysvinit)
    sec services ok
    service --status-all 2>/dev/null | awk '{m=$2;n=$4;if(n!="")printf "%s\\t%s\\t%s\\t\\n",n,m,m}' | head -n 200 ;;
  container-none)
    sec services cannot "this is running inside a container, which has nothing of its own that keeps programs running" ;;
  *)
    sec services cannot "we could not tell how this server starts and stops things" ;;
esac

case "$CTR" in
  docker|podman)
    sec containers ok
    $CTR ps -a --no-trunc --format '{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null ||
      $CTR ps -a --no-trunc --format '{{.Names}}\t{{.Image}}\t\t{{.Status}}\t{{.Ports}}' 2>/dev/null ;;
  present-no-permission)
    sec containers cannot "this sign-in is not allowed to ask this server about its containers" ;;
  *)
    sec containers none ;;
esac

owners() {
  while IFS='\t' read -r addr port prog pid; do
    unit=
    if [ -n "$pid" ] && [ -r "/proc/$pid/cgroup" ]; then
      while IFS= read -r cl; do
        case "$cl" in *.service|*.scope|*.slice) unit=\${cl##*/} ;; esac
      done < "/proc/$pid/cgroup"
    fi
    printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "$addr" "$port" "$prog" "$pid" "$unit"
  done
}

if have ss; then
  sec listeners ok
  ss -H -tlnp 2>/dev/null | awk '{la=$4;n=split(la,a,":");port=a[n];addr=substr(la,1,length(la)-length(port)-1);prog="";pid="";if(match($0,/"[^"]+"/))prog=substr($0,RSTART+1,RLENGTH-2);if(match($0,/pid=[0-9]+/))pid=substr($0,RSTART+4,RLENGTH-4);printf "%s\\t%s\\t%s\\t%s\\n",addr,port,prog,pid}' | head -n 200 | owners
elif have netstat; then
  sec listeners ok
  netstat -tlnp 2>/dev/null | awk '/LISTEN/{la=$4;n=split(la,a,":");port=a[n];addr=substr(la,1,length(la)-length(port)-1);prog="";pid="";if($NF ~ /\\//){split($NF,b,"/");pid=b[1];prog=b[2]}printf "%s\\t%s\\t%s\\t%s\\n",addr,port,prog,pid}' | head -n 200 | owners
else
  sec listeners cannot "this server has no tool installed for listing what is listening"
fi

case "$WEB" in
  caddy)
    if [ -r /etc/caddy/Caddyfile ]; then
      sec sites ok
      awk '/^[^ \\t#{}].*\\{[ \\t]*$/{l=$0;sub(/[ \\t]*\\{[ \\t]*$/,"",l);n=split(l,a,/[ \\t]*,[ \\t]*/);for(i=1;i<=n;i++)if(a[i]!="")printf "%s\\n",a[i]}' /etc/caddy/Caddyfile | head -n 100
    else
      sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
    fi ;;
  nginx)
    if nginx -T >/dev/null 2>&1; then
      sec sites ok
      nginx -T 2>/dev/null | awk '/^[ \\t]*server_name[ \\t]/{for(i=2;i<=NF;i++){g=$i;sub(/;$/,"",g);if(g!=""&&g!="_")print g}}' | sort -u | head -n 100
    elif cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf >/dev/null 2>&1; then
      sec sites ok
      cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf 2>/dev/null |
        awk '/^[ \\t]*server_name[ \\t]/{for(i=2;i<=NF;i++){g=$i;sub(/;$/,"",g);if(g!=""&&g!="_")print g}}' | sort -u | head -n 100
    else
      sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
    fi ;;
  apache2|httpd)
    if \${WEB}ctl -S >/dev/null 2>&1; then
      sec sites ok
      \${WEB}ctl -S 2>&1 | awk '/namevhost/{print $4}' | sort -u | head -n 100
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
    printf '%s\\n' "\${f##*/}"
  done | head -n 200
else
  sec adminunits cannot "we can only tell which programs were added by hand on a server that keeps them this way"
fi
printf '#end ok\\n'

`

/* ------------------------------------------------------------ the reader -- */

/** What the probe called each check, in words a person can read. */
const HOW = {
  identity: 'asked the server what it is',
  privilege: 'asked what this sign-in is allowed to do',
  init: 'looked for how this server starts and stops things',
  containers: 'asked whether this server runs containers',
  packages: 'looked for how software is installed here',
  web: 'looked for a web server',
  resources: 'asked how much room and memory it has',
  services: 'asked what it is set up to keep running',
  listeners: 'asked what is listening',
  sites: "read the web server's own settings",
} as const

/**
 * What a section says when the script never got to it.
 *
 * Only reachable when `#end ok` is missing, which means the far end stopped
 * partway — a killed shell, a closed connection, a full output buffer. Saying
 * that is materially different from saying there are none, and the difference
 * is the whole point of the third state.
 */
const CUT_OFF = 'The server stopped answering before it finished this check.'

/** A section that should have been in the output of a script that ran to the end. */
const NEVER_ASKED = 'This check did not run.'

interface Section {
  state: string
  reason: string
  rows: string[]
}

interface Parsed {
  scalars: Map<string, string>
  sections: Map<string, Section>
  finished: boolean
}

/**
 * Split the raw output into scalars and sections without interpreting any of it.
 *
 * Deliberately forgiving: a line that is neither `key=value` nor a section
 * header is dropped rather than treated as an error. Servers print things
 * nobody asked for — a login banner, a `stdin: is not a tty` warning, an MOTD —
 * and refusing to parse because of one is refusing to work on a machine that is
 * fine.
 */
function split(stdout: string): Parsed {
  const scalars = new Map<string, string>()
  const sections = new Map<string, Section>()
  let current: Section | null = null
  let finished = false
  for (const line of stdout.split('\n')) {
    if (line.startsWith('#')) {
      const rest = line.slice(1)
      const firstSpace = rest.indexOf(' ')
      const name = firstSpace === -1 ? rest : rest.slice(0, firstSpace)
      const after = firstSpace === -1 ? '' : rest.slice(firstSpace + 1)
      const secondSpace = after.indexOf(' ')
      const state = secondSpace === -1 ? after : after.slice(0, secondSpace)
      const reason = secondSpace === -1 ? '' : after.slice(secondSpace + 1)
      if (name === 'end') {
        finished = true
        current = null
        continue
      }
      current = { state, reason, rows: [] }
      sections.set(name, current)
      continue
    }
    if (current !== null) {
      if (line !== '') current.rows.push(line)
      continue
    }
    const equals = line.indexOf('=')
    if (equals > 0) scalars.set(line.slice(0, equals), line.slice(equals + 1))
  }
  return { scalars, sections, finished }
}

/**
 * A scalar that is present and non-empty, or `cannot`.
 *
 * The empty string is the script's way of saying the server would not answer —
 * every scalar is printed unconditionally so that a missing answer is visible
 * as an empty value rather than as an absent line, which would be
 * indistinguishable from a line that scrolled off.
 */
function text(parsed: Parsed, key: string, at: number, how: string, why: string): Fact<string> {
  const value = parsed.scalars.get(key)
  if (value === undefined || value.trim() === '') return factCannot(at, why)
  return factYes(value.trim(), at, how)
}

function number(parsed: Parsed, key: string, at: number, how: string, why: string): Fact<number> {
  const value = parsed.scalars.get(key)
  if (value === undefined || value.trim() === '') return factCannot(at, why)
  const parsedNumber = Number(value.trim())
  if (!Number.isFinite(parsedNumber)) return factCannot(at, why)
  return factYes(parsedNumber, at, how)
}

/**
 * Read a section, handing its rows to `build` only when there are rows to read.
 *
 * The three outcomes map exactly onto the three states, and the mapping is here
 * in one place rather than repeated per section, because the repeated version
 * is where somebody eventually writes `factNo` for a `cannot`.
 */
function section<T>(
  parsed: Parsed,
  name: string,
  at: number,
  how: string,
  build: (rows: readonly string[]) => T,
): Fact<T> {
  const found = parsed.sections.get(name)
  if (found === undefined) return factCannot(at, parsed.finished ? NEVER_ASKED : CUT_OFF)
  if (found.state === 'cannot') {
    return factCannot(at, found.reason === '' ? NEVER_ASKED : sentence(found.reason))
  }
  if (found.state === 'none') return factNo(at, how)
  return factYes(build(found.rows), at, how)
}

/** The script writes its reasons unpunctuated; a person reads a sentence. */
function sentence(raw: string): string {
  const trimmed = raw.trim()
  if (trimmed === '') return NEVER_ASKED
  const capitalised = trimmed.charAt(0).toUpperCase() + trimmed.slice(1)
  return /[.!?]$/.test(capitalised) ? capitalised : `${capitalised}.`
}

function columns(row: string, count: number): string[] {
  const parts = row.split('\t')
  while (parts.length < count) parts.push('')
  return parts.slice(0, count)
}

/* ------------------------------------------------------- the small reads -- */

const PRIVILEGES: readonly Privilege[] = ['yes', 'sudo-nopasswd', 'sudo-password', 'no']
const INITS: readonly InitSystem[] = [
  'systemd',
  'openrc',
  'launchd',
  'sysvinit',
  'container-none',
]

/**
 * systemd's own verdict on a unit, mapped to the four states a card can show.
 *
 * The interesting case is `active (exited)`, which is what a one-shot job looks
 * like *after it has successfully finished*. systemd itself calls that active,
 * so that is what this reports; the alternative would be a page announcing that
 * `apparmor` is not running on a machine where AppArmor is loaded and fine.
 *
 * What follows from that, and is worth saying because it decides how the
 * classifier is written: `state` is not a good filter for what deserves a card.
 * `addedHere` and the port-owner join are. A one-shot that ran at boot and
 * exited is honestly "active" and honestly not a thing anybody wants a Restart
 * button for.
 */
function systemdState(active: string, sub: string): RunState {
  if (sub === 'running') return 'running'
  if (active === 'failed' || sub === 'failed') return 'failed'
  if (active === 'active' || active === 'activating' || active === 'reloading') return 'running'
  if (active === 'inactive' || active === 'deactivating') return 'stopped'
  return 'unknown'
}

/** OpenRC prints its state in square brackets: `started`, `stopped`, `crashed`. */
function openrcState(word: string): RunState {
  if (word === 'started') return 'running'
  if (word === 'crashed') return 'failed'
  if (word === 'stopped') return 'stopped'
  return 'unknown'
}

/** SysV `service --status-all` prints `+`, `-` or `?` in brackets. */
function sysvinitState(mark: string): RunState {
  if (mark === '+') return 'running'
  if (mark === '-') return 'stopped'
  return 'unknown'
}

/**
 * A container runtime's own state word.
 *
 * `restarting` is deliberately `unknown` rather than `failed`. A container in a
 * crash loop and a container that was asked to restart a second ago look
 * identical from here, and calling the second one failed would put a red mark
 * on a page for something that is about to be fine. The runtime's own status
 * line — *"Restarting (1) 5 seconds ago"* — is carried alongside and says which.
 */
function containerState(word: string): RunState {
  if (word === 'running') return 'running'
  if (word === 'restarting') return 'unknown'
  if (word === '') return 'unknown'
  return 'stopped'
}

/* ---------------------------------------------------------- the assembly -- */

/**
 * Turn one probe's output into the facts the rest of the feature reads.
 *
 * `serverId` and `measuredAt` are passed in rather than derived: the same
 * output parsed twice must produce the same record, which is what lets the
 * fixtures in `probe.test.ts` pin the third-state behaviour without a clock.
 */
export function parseProbe(stdout: string, serverId: string, measuredAt: number): ServerFacts {
  const parsed = split(stdout)
  const at = measuredAt

  const privilegeRaw = parsed.scalars.get('root') ?? ''
  const privilege: Fact<Privilege> = PRIVILEGES.includes(privilegeRaw as Privilege)
    ? factYes(privilegeRaw as Privilege, at, HOW.privilege)
    : factCannot(at, 'We could not tell what this sign-in is allowed to do on this server.')

  const initRaw = parsed.scalars.get('init') ?? ''
  const init: Fact<InitSystem> = INITS.includes(initRaw as InitSystem)
    ? factYes(initRaw as InitSystem, at, HOW.init)
    : factCannot(at, 'We could not tell how this server starts and stops the things it runs.')

  const containersRaw = parsed.scalars.get('containers') ?? ''
  const containerRuntime: Fact<ContainerRuntime> =
    containersRaw === 'docker' || containersRaw === 'podman'
      ? factYes(containersRaw, at, HOW.containers)
      : containersRaw === 'none'
        ? factNo(at, HOW.containers)
        : containersRaw === 'present-no-permission'
          ? factCannot(
              at,
              'This sign-in is not allowed to ask this server about its containers.',
            )
          : factCannot(at, 'We could not tell whether this server runs containers.')

  // Present-and-empty and absent-entirely are different answers, and this is
  // the one scalar where they are. The script prints `web=` unconditionally, so
  // an empty value means *it looked and found no web server* — a fact about the
  // machine, which is `no`. A missing line means the script never got that far,
  // which is `cannot`. Collapsing the two would put "this server has no
  // website" on a page that measured nothing.
  const webRaw = parsed.scalars.get('web')
  const webServer: Fact<string> =
    webRaw === undefined
      ? factCannot(at, parsed.finished ? NEVER_ASKED : CUT_OFF)
      : webRaw.trim() === ''
        ? factNo(at, HOW.web)
        : factYes(webRaw.trim(), at, HOW.web)

  // The units an administrator added by hand, used to mark the services below.
  // A `cannot` here is not a failure of the services list — it only means every
  // service is reported with `addedHere: false`, which is the safe direction:
  // it never claims somebody put something there when we could not check.
  const adminSection = parsed.sections.get('adminunits')
  const addedHere = new Set(
    adminSection !== undefined && adminSection.state === 'ok' ? adminSection.rows : [],
  )

  const initValue = init.known === 'yes' ? init.value : null

  const services = section<ServiceFact[]>(parsed, 'services', at, HOW.services, (rows) => {
    const out: ServiceFact[] = []
    for (const row of rows) {
      const [name, second, third, description] = columns(row, 4)
      if (name === '') continue
      const state =
        initValue === 'openrc'
          ? openrcState(second)
          : initValue === 'sysvinit'
            ? sysvinitState(second)
            : systemdState(second, third)
      out.push({ name, state, description, addedHere: addedHere.has(name) })
    }
    return out
  })

  const containers = section<ContainerFact[]>(parsed, 'containers', at, HOW.containers, (rows) => {
    const out: ContainerFact[] = []
    for (const row of rows) {
      const [name, image, state, status, ports] = columns(row, 5)
      if (name === '') continue
      out.push({ name, image, state: containerState(state), status, ports })
    }
    return out
  })

  const listeners = section<ListenerFact[]>(parsed, 'listeners', at, HOW.listeners, (rows) => {
    const out: ListenerFact[] = []
    for (const row of rows) {
      const [address, port, program, pid, unit] = columns(row, 5)
      const portNumber = Number(port)
      if (!Number.isInteger(portNumber) || portNumber <= 0) continue
      const pidNumber = Number(pid)
      out.push({
        address,
        port: portNumber,
        program,
        pid: Number.isInteger(pidNumber) && pidNumber > 0 ? pidNumber : null,
        unit,
      })
    }
    return out
  })

  const siteNames = section<string[]>(parsed, 'sites', at, HOW.sites, (rows) =>
    rows.map((row) => row.trim()).filter((row) => row !== ''),
  )

  // The four numbers a container reports about somebody else's computer. This
  // is the one place the rule is applied, so that no card can opt out of it by
  // reading the scalar itself — the scalars are not exported.
  const inherited = initValue === 'container-none'
  const disk: Fact<DiskFact> = inherited
    ? factCannot(at, CONTAINER_NUMBERS_WHY)
    : pair(
        number(parsed, 'disk_used_kb', at, HOW.resources, DISK_WHY),
        number(parsed, 'disk_total_kb', at, HOW.resources, DISK_WHY),
        (usedKb, totalKb) => ({ usedKb, totalKb }),
      )
  const memory: Fact<MemoryFact> = inherited
    ? factCannot(at, CONTAINER_NUMBERS_WHY)
    : pair(
        number(parsed, 'memory_total_kb', at, HOW.resources, MEMORY_WHY),
        number(parsed, 'memory_free_kb', at, HOW.resources, MEMORY_WHY),
        (totalKb, freeKb) => ({ totalKb, freeKb }),
      )
  const load1: Fact<number> = inherited
    ? factCannot(at, CONTAINER_NUMBERS_WHY)
    : number(parsed, 'load1', at, HOW.resources, 'This server does not report how busy it is.')
  const uptimeSeconds: Fact<number> = inherited
    ? factCannot(at, CONTAINER_NUMBERS_WHY)
    : number(
        parsed,
        'uptime_s',
        at,
        HOW.resources,
        'This server does not report how long it has been on.',
      )

  return {
    serverId,
    measuredAt,
    os: text(parsed, 'os', at, HOW.identity, 'This server did not say what it is running.'),
    kernel: text(parsed, 'kernel', at, HOW.identity, 'This server did not say what it is running.'),
    arch: text(parsed, 'arch', at, HOW.identity, 'This server did not say what kind it is.'),
    hostname: text(parsed, 'host', at, HOW.identity, 'This server did not say what it is called.'),
    user: text(parsed, 'user', at, HOW.identity, 'This server did not say who we signed in as.'),
    privilege,
    init,
    containerRuntime,
    packageManager: text(
      parsed,
      'packages',
      at,
      HOW.packages,
      'We do not recognise how software is installed on this server.',
    ),
    webServer,
    cpus: number(
      parsed,
      'cpus',
      at,
      HOW.resources,
      'This server did not say how many processors it has.',
    ),
    disk,
    memory,
    load1,
    uptimeSeconds,
    services,
    containers,
    listeners,
    siteNames,
  }
}

const DISK_WHY = 'This server did not say how much room it has.'
const MEMORY_WHY = 'This server did not say how much memory it has.'

/**
 * Combine two facts into one, where either being unknown makes the pair unknown.
 *
 * Used total is meaningless without a total, and a page showing "5.5 GB used"
 * with no denominator is a number nobody can act on. So the pair travels
 * together or not at all, and the `cannot` reason is the first one that had one
 * — which is the more specific of the two, since both come from the same check.
 */
function pair<A, B, T>(
  first: Fact<A>,
  second: Fact<B>,
  combine: (a: A, b: B) => T,
): Fact<T> {
  if (first.known === 'yes' && second.known === 'yes') {
    return factYes(combine(first.value, second.value), first.measuredAt, first.how)
  }
  if (first.known === 'cannot') return factCannot(first.measuredAt, first.why)
  if (second.known === 'cannot') return factCannot(second.measuredAt, second.why)
  return factNo(first.measuredAt, first.known === 'no' ? first.how : 'no')
}
