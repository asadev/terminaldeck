/**
 * Putting the headless host **on** a server from the connector, and taking it
 * off again.
 *
 * ## What he asked for
 *
 * > *"for the headless part … instead of going inside a server and doing some
 * > stuff there … we will directly install through from our application, from
 * > the main application we can give some steps there for installation, they
 * > will click on install and it will install … and it should actually be
 * > installed in the connected server. If we want to uninstall we can
 * > uninstall."*
 *
 * So this is `scripts/install-headless.sh` driven by a button instead of by
 * somebody who has already SSH'd in — which is the whole point, because the
 * person this feature is for is the one who does not want to.
 *
 * ## The same narrow exception §7 already names, and no wider
 *
 * `SERVERS-DESIGN.md` §7 lists *"installing software"* as a non-goal and
 * `setup.ts` records the one exception it now names: **one program, into the
 * account's own home, with no administrator access, with a way back, driven by
 * a person pressing a button.** This is the second program under that same
 * sentence and it obeys every clause of it:
 *
 *  - it goes to `$HOME/.local` or `$HOME/.terminaldeck`, never to `/usr`;
 *  - it never runs `sudo`, and where root would be needed — `loginctl
 *    enable-linger` — it **says so and carries on**, rather than asking;
 *  - the way back is {@link ServerHosts.uninstall}, and it states what it
 *    leaves behind rather than quietly leaving it;
 *  - nothing here happens on a timer.
 *
 * There is no entry for any of this in `tools.ts` and there must not be, for
 * the reason §6.1 gives and `no-run-tool.test.ts` pins.
 *
 * ## Why the package travels with the app
 *
 * `terminaldeck` on npm is a **name reservation** — see `host-package.ts` — so
 * `npm install -g terminaldeck` would put a package with no `bin` entry on
 * somebody's server and leave a host that looks installed and answers nothing.
 * The tarball and the installer are uploaded over the SFTP channel this
 * connection already has, and the installer is handed the local path through
 * `TERMINALDECK_PACKAGE`, which it has supported since it was written: *"a local
 * tarball is a real case — a server with no route to npmjs.org, or a build being
 * tried before it is published."*
 *
 * ## Why every step runs in the terminal that is on screen
 *
 * The identical argument `setup.ts` makes for the agent installs, and one extra
 * reason that is specific to this flow and is not a preference:
 *
 * **`terminaldeck pair` refuses to finish without a tty.** Measured in
 * `main.ts`: `if (!process.stdin.isTTY)` it prints the code, says *"Not a
 * terminal, so nothing can be confirmed here"*, and exits — deliberately,
 * because *"pretending to wait and then approving nothing would leave a device
 * paired and permanently locked out."* An exec channel is not a tty. A shell is.
 * So pairing happens in the same real terminal the install ran in, the code is
 * read out of its output, and the fingerprint question is answered by the person
 * looking at it — which is the one part of pairing a person can actually check,
 * and the one part this app must not answer for them.
 */

import { BRAND } from '../../shared/brand'
import type { HostPackage } from './host-package'

/* --------------------------------------------------------- what it needs -- */

/** What one command on the server answered. `connection.ts`'s shape. */
export interface HostRunResult {
  code: number | null
  stdout: string
  stderr: string
}

/**
 * The terminal on screen, as this file needs it.
 *
 * Structural rather than imported, so the whole flow can be exercised against a
 * plain object — the same seam `setup.ts` takes, and for the same reason.
 */
export interface HostShell {
  onData(listener: (chunk: string) => void): () => void
  write(data: string): void
}

export interface HostDeps {
  /** One script, one round trip. `ServerConnections.runScript`. */
  runScript(serverId: string, script: string): Promise<HostRunResult>
  /**
   * Put a file from this computer onto that server, over SFTP, and answer where
   * it landed.
   *
   * Optional, and its absence is an honest refusal rather than a fallback: the
   * alternative is `cat > file` down a shell, which cannot survive a folder with
   * a space in its name and turns a full disk into an exit status nobody can
   * read. `connection.ts` argues that at length beside `putFile` itself.
   */
  putFile?(serverId: string, localPath: string, name: string): Promise<string>
  /** The tarball and installer this build carries, or null when it carries none. */
  hostPackage(): HostPackage | null
  /** Push the state to every window. */
  broadcast(state: HostState): void
}

/* ------------------------------------------------------------ the state -- */

/**
 * Where one server's host install has got to.
 *
 * Every one of these is a step somebody watches happen. *"Report each step as it
 * happens; a long silent operation on somebody's server is the worst version of
 * this."*
 */
export type HostStep =
  | 'idle'
  | 'checking'
  | 'uploading'
  | 'installing'
  | 'service'
  | 'pairing'
  | 'done'
  | 'removing'
  | 'failed'

export interface HostState {
  serverId: string
  step: HostStep
  /** The one line under the terminal. Written here, never in the renderer. */
  line: string
  /** The server's own words when something failed. Shown behind a disclosure. */
  detail: string
  /**
   * Every step that has finished, in order, each already a sentence.
   *
   * A list rather than one line, because the whole complaint this answers is
   * about silence: a person who looked away for a minute needs to come back to
   * what happened, not only to whatever is happening now.
   */
  done: readonly string[]
  /**
   * The code the host printed, once it has printed one.
   *
   * Exactly as it was printed. `cli.ts` states the rule and the bug that made it
   * one: *"an earlier version regrouped an already-grouped code into
   * `CSPA--0EC-H`, which nobody can type."* Nothing here reformats it.
   */
  code: string | null
  /** True once this app put it here, which is what makes a way back honest. */
  weInstalled: boolean
}

function state(
  serverId: string,
  step: HostStep,
  line: string,
  over: Partial<HostState> = {},
): HostState {
  return { serverId, step, line, detail: '', done: [], code: null, weInstalled: false, ...over }
}

/* ------------------------------------------------- what is on the server -- */

/** Whether the host on that server is up, as far as its own `status` will say. */
export type HostRunning = 'yes' | 'no' | 'unknown'

/** What one probe found out about the headless host on one server. */
export interface HostOnServer {
  /** The absolute path of the `terminaldeck` command, or `''` when there is none. */
  command: string
  /** What it answers to `--version`, or `''` when it will not start. */
  version: string
  running: HostRunning
  /** The host's own `status` output, verbatim. Empty when there is nothing to ask. */
  status: string
  /** `active`, `inactive`, `failed`, or `''` when there is no unit of ours. */
  unit: string
  /**
   * True when the account's own systemd manager will keep the host running after
   * the last login ends. False is a fact somebody has to be told.
   */
  linger: boolean
  /** True when the host's state folder is on that server. */
  data: boolean
  /** Where that folder is, so the sentence about it can name it. */
  dataDir: string
}

/** What it would take to put one here. Every refusal is decided from this. */
export interface HostRoom {
  /** `linux` or `darwin`; anything else and there is no host to install. */
  os: string
  /** `uname -m`, unmapped. The installer does Node's spelling. */
  arch: string
  /** `gnu` or `musl`. Node publishes no musl build; see {@link whyNotHost}. */
  libc: string
  /** What `node --version` said, or `''`. */
  node: string
  /** The path to `npm`, or `''`. */
  npm: string
  /** The build tools node-pty needs on Linux and did not find. */
  missingTools: readonly string[]
  /** `curl`, `wget`, or `''`. */
  downloader: string
  /** True when there is some way to check a sha256 here. */
  canHash: boolean
  /** True when `tar` is here. */
  canUnpack: boolean
  /** Free space in the account's own home, in kilobytes, or null. */
  homeFreeKb: number | null
  /** True when `systemctl --user` answered, so a user unit can be written. */
  systemdUser: boolean
}

export interface HostLook {
  host: HostOnServer
  room: HostRoom
}

/* ------------------------------------------------------------ the probe -- */

/**
 * Everything this feature needs to know about a server, in one round trip.
 *
 * A separate script from `probe.sh` rather than eight more fields on it, and the
 * reason is the one `setup.ts` gives for its own `findScript`: this runs when
 * somebody opens a panel, about one program, and the probe is a 293 ms survey of
 * the whole machine. Widening that survey to answer a question only this panel
 * asks would make every page slower for it.
 *
 * The PATH is widened the way the agent search widens it, and it is the same
 * blind spot: `~/.local/bin` is where both the installer's launcher and a
 * user-prefix npm install land, and a non-interactive `sh -s` has neither on
 * PATH — so a bare `command -v terminaldeck` answers "not found" about a file
 * that is sitting right there.
 */
export const HOST_PROBE = [
  'AW="$PATH"',
  `for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.${BRAND.id}/runtime/bin" \\`,
  '         "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin /snap/bin; do',
  '  [ -d "$d" ] && AW="$AW:$d"',
  'done',
  'p() { printf "%s\\t%s\\n" "$1" "$2"; }',
  'have() { PATH="$AW" command -v "$1" >/dev/null 2>&1; }',
  '',
  'p os "$(uname -s 2>/dev/null)"',
  'p arch "$(uname -m 2>/dev/null)"',
  'LIBC=gnu',
  'if (ldd --version 2>&1 || true) | grep -qi musl; then LIBC=musl',
  'elif ls /lib/ld-musl-* >/dev/null 2>&1; then LIBC=musl; fi',
  'p libc "$LIBC"',
  '',
  'p node "$(PATH="$AW" node --version 2>/dev/null)"',
  'p npm "$(PATH="$AW" command -v npm 2>/dev/null)"',
  'MISS=',
  'have python3 || have python || MISS="$MISS python3"',
  'have make || MISS="$MISS make"',
  'have cc || have gcc || have clang || MISS="$MISS gcc"',
  'have c++ || have g++ || have clang++ || MISS="$MISS g++"',
  'p tools "$MISS"',
  'FETCH=',
  'for f in curl wget; do have "$f" && { FETCH=$f; break; }; done',
  'p fetch "$FETCH"',
  'HASH=',
  'for h in sha256sum shasum openssl; do have "$h" && { HASH=$h; break; }; done',
  'p hash "$HASH"',
  'have tar && p tar yes',
  'p home_free_kb "$(df -Pk "$HOME" 2>/dev/null | awk \'NR==2{print $4}\')"',
  '',
  '# The state folder, XDG first, because that is what the host itself reads.',
  `SD="\${XDG_DATA_HOME:-$HOME/.local/share}/${BRAND.id}"`,
  'p state_dir "$SD"',
  '[ -d "$SD" ] && p state yes',
  '',
  'systemctl --user is-system-running >/dev/null 2>&1 && p systemd_user yes',
  '# The unit *file*, not just `is-active`. Measured on a real box: asking',
  '# `is-active` about a unit that does not exist answers "inactive" — so a',
  '# server with no unit of ours and a server whose unit is stopped were',
  '# indistinguishable, and `reachLine` would have claimed the first one starts',
  '# with the machine.',
  `if [ -f "$HOME/.config/systemd/user/${BRAND.id}.service" ]; then`,
  `  p unit "$(systemctl --user is-active ${BRAND.id}.service 2>/dev/null)"`,
  'fi',
  '[ "$(loginctl show-user "$(id -u)" -p Linger --value 2>/dev/null)" = yes ] && p linger yes',
  '',
  `B=$(PATH="$AW" command -v ${BRAND.id} 2>/dev/null)`,
  'p command "$B"',
  'if [ -n "$B" ]; then',
  '  p version "$(PATH="$AW" "$B" --version 2>/dev/null | head -n 1)"',
  '  # The whole answer, verbatim. The running/not-running verdict is decided on',
  '  # the other side rather than grepped here — see readHostProbe.',
  '  printf "%s\\n" "--- status ---"',
  '  PATH="$AW" "$B" status 2>&1 | head -n 60',
  'fi',
  'exit 0',
].join('\n')

/** The line that separates the tab-separated facts from the host's own words. */
const STATUS_MARK = '--- status ---'

/**
 * The one sentence `renderNotRunning` prints, which is the only reliable way to
 * tell the two states apart.
 *
 * Not a guess at wording: `cli.ts` has exactly two shapes for `status` and both
 * exit 0 — deliberately, because *"a non-zero exit would make a health check
 * report a failure for a machine that is simply switched off."* So the exit
 * status says nothing and the first line says everything. Matched on the part
 * that carries no product name, so renaming the product is not a silent
 * behaviour change here.
 */
const NOT_RUNNING = /host:\s*not running/i

/** Turn one probe's answer into the two records above. */
export function readHostProbe(out: string): HostLook {
  const marked = out.indexOf(`${STATUS_MARK}\n`)
  const head = marked === -1 ? out : out.slice(0, marked)
  const status = marked === -1 ? '' : out.slice(marked + STATUS_MARK.length + 1).trim()

  const said = new Map<string, string>()
  for (const line of head.split('\n')) {
    const tab = line.indexOf('\t')
    if (tab > 0) said.set(line.slice(0, tab), line.slice(tab + 1).trim())
  }
  const value = (key: string): string => said.get(key) ?? ''
  const number = (key: string): number | null => {
    const raw = value(key)
    if (raw === '') return null
    const parsed = Number(raw)
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : null
  }

  const command = value('command')
  const running: HostRunning =
    command === '' || status === '' ? 'unknown' : NOT_RUNNING.test(status) ? 'no' : 'yes'

  return {
    host: {
      command,
      version: value('version'),
      running,
      status,
      unit: value('unit'),
      linger: value('linger') === 'yes',
      data: value('state') === 'yes',
      dataDir: value('state_dir'),
    },
    room: {
      os: value('os').toLowerCase(),
      arch: value('arch'),
      libc: value('libc') === 'musl' ? 'musl' : 'gnu',
      node: value('node'),
      npm: value('npm'),
      missingTools: value('tools')
        .split(' ')
        .filter((word) => word !== ''),
      downloader: value('fetch'),
      canHash: value('hash') !== '',
      canUnpack: value('tar') === 'yes',
      homeFreeKb: number('home_free_kb'),
      systemdUser: value('systemd_user') === 'yes',
    },
  }
}

/* ------------------------------------------------- what a person is told -- */

/**
 * Measured: the tarball is a couple of megabytes, its dependencies unpack to
 * about 40 MB, and a private Node runtime is another 120 MB when one is fetched.
 * Rounded up; the refusal names the real figure the server reported.
 */
const ROOM_NEEDED_KB = 400 * 1024

/**
 * Why there is no Install button, in the server's own terms — or null when
 * nothing is in the way.
 *
 * ## Why these checks exist twice
 *
 * `install-headless.sh` refuses on musl, on an architecture Node does not build
 * for, and on a Linux box with no C++ toolchain, and it does all three before it
 * writes anything. That script is the **authority**: it re-checks every one of
 * these on the machine itself, in the same run that would do the work.
 *
 * This copy exists for a different job — deciding whether to *offer* the button
 * at all. §4.1: *"a control that cannot act is removed, or disabled with a
 * stated reason. Never drawn hopefully."* A button that uploaded a package to
 * somebody's server and then printed the installer's refusal would be exactly
 * the hopeful control that rule forbids.
 *
 * The two must not drift, and what keeps them together is that both are about
 * facts a machine reports rather than about wording: `libc`, `uname -m`, four
 * command names, free kilobytes.
 */
export function whyNotHost(room: HostRoom): string | null {
  if (room.os !== 'linux' && room.os !== 'darwin') {
    return (
      `The headless host runs on Linux and macOS, and this server answered “${room.os || 'nothing'}”. ` +
      'On Windows people install the desktop app instead.'
    )
  }
  if (room.libc === 'musl') {
    return (
      'This server uses musl (Alpine or similar), and the Node project publishes no musl build — so ' +
      'there is no runtime to fetch for it. Install Node 22 or newer from the distribution ' +
      '(apk add --no-cache nodejs npm) and this becomes available.'
    )
  }
  if (room.os === 'linux' && room.missingTools.length > 0) {
    return (
      'This server is missing the build tools a session’s pseudo terminal needs: ' +
      `${room.missingTools.join(', ')}. node-pty ships no Linux binary, so it compiles during the ` +
      'install, and without a compiler that fails a minute in. Someone will need to add them first: ' +
      `sudo apt-get install -y ${room.missingTools.join(' ')}`
    )
  }
  if (!usableNode(room)) {
    if (room.downloader === '') {
      return (
        'This server has no Node 22 or newer, and no curl or wget to fetch one with. Someone will ' +
        'need to add one of those first.'
      )
    }
    if (!room.canHash) {
      return (
        'This server has no sha256 tool (sha256sum, shasum or openssl), and a Node runtime will not ' +
        'be unpacked here unverified. Install coreutils, or install Node 22 or newer yourself.'
      )
    }
    if (!room.canUnpack) {
      return 'This server has no tar, so a Node runtime could not be unpacked here.'
    }
  }
  if (room.homeFreeKb !== null && room.homeFreeKb < ROOM_NEEDED_KB) {
    return (
      `There is ${Math.round(room.homeFreeKb / 1024)} MB free in your home folder on this server ` +
      `and this needs about ${Math.round(ROOM_NEEDED_KB / 1024)} MB.`
    )
  }
  return null
}

/** Node 22 or newer **with npm**, which is one question rather than two. */
export function usableNode(room: Pick<HostRoom, 'node' | 'npm'>): boolean {
  if (room.npm === '') return false
  const major = Number(/^v?(\d+)/.exec(room.node)?.[1])
  return Number.isInteger(major) && major >= 22
}

/**
 * The sentence shown before the Install button, written where the work is —
 * §4.3, and every clause of it is something this file then actually does.
 */
export function hostConsequence(serverName: string, room: HostRoom): string {
  const runtime = usableNode(room)
    ? `It uses the Node ${room.node} that is already there.`
    : 'This server has no Node 22 or newer, so an official Node build is fetched, checked against the ' +
      `checksum Node published for it, and unpacked into ~/.${BRAND.id}/runtime, where nothing else ` +
      'on this server uses it.'
  return (
    `This puts the host into your own home folder on ${serverName} and starts it, so this server ` +
    `becomes a machine you can open a session on from here or from your phone. ${runtime} It does not ` +
    'need administrator access, it writes nothing outside your home folder, and you can remove it ' +
    'again from here.'
  )
}

/**
 * The one standing line for the section, and it is written here rather than in
 * the renderer for the reason §4.3 gives: a screen that composed its own would
 * be describing work it does not do, and the two would drift.
 *
 * Four states and no fifth, and the fourth is the one that matters — a host that
 * would not say whether it is running is reported as not having said, never as
 * running. `readHostProbe` produces that third state whenever `status` printed
 * nothing at all, which is what a half-installed host does.
 */
export function hostLine(host: HostOnServer): string {
  if (host.command === '') return 'Nothing on this server can run a session for you yet.'
  if (host.version === '') return 'The host is on this server and will not start.'
  if (host.running === 'no') return `The host ${host.version} is here and is not running.`
  if (host.running === 'unknown') {
    return `The host ${host.version} is here. It would not say whether it is running.`
  }
  return `The host ${host.version} is here and running.`
}

/**
 * Whether it will still be there tomorrow, which is a different question from
 * whether it is running now — and the one nobody thinks to ask until a phone in
 * another country finds nothing.
 *
 * Three answers and each names what would change it. Null only when there is no
 * host to say anything about.
 */
export function reachLine(host: HostOnServer): string | null {
  if (host.command === '') return null
  if (host.unit === '') {
    return (
      'It was not set up to start on its own, so it will not come back after this server reboots. ' +
      'Removing it and installing it again from here sets that up.'
    )
  }
  if (!host.linger) {
    return (
      'It starts with this server, and stops when your last login on this server ends — running ' +
      '`sudo loginctl enable-linger $(id -un)` once on that server is what stops that.'
    )
  }
  return 'It starts with this server and keeps running when you log out.'
}

/** The button that puts it back, named the way a person would say it. */
export const REMOVE_HOST_LABEL = 'Remove it from this server'

/**
 * What removing it leaves behind, said before the press rather than discovered
 * after it.
 *
 * The data folder is the interesting one and it is deliberately **not** removed
 * by default: it holds the devices paired to this host and the folders each of
 * them may use, and somebody removing the program to install a newer one does
 * not expect to have to pair their phone again. `setup.ts` makes the same
 * argument about `~/.claude` — *"those folders are the person's own … removing
 * one would be deleting somebody's work under the heading of undoing our own."*
 */
export function removeConsequence(look: HostOnServer, alsoData: boolean): string {
  const service = look.unit === '' ? '' : ' Its service is stopped and its unit file removed.'
  const data = alsoData
    ? ` Everything it stored on that server goes too — ${look.dataDir}, which is the devices paired to ` +
      'it and the folders each of them may use. Any phone paired to this host will need pairing again.'
    : ` What it stored stays: ${look.dataDir} holds the devices paired to it and the folders each of ` +
      'them may use, so a later install finds them again. Tick the box to remove that as well.'
  return (
    'This removes the host program and, if this app fetched one, the private Node runtime beside it.' +
    `${service}${data} This app’s own record of the machine is separate — forget it under Machines if ` +
    'you want that gone too.'
  )
}

/* --------------------------------------------------------- the sentinel -- */

/** What is appended to a typed line so this side knows when it ended. */
const DONE = `__${BRAND.id}_host`

/** The echoed command ends in `$?`; only the shell's answer ends in digits. */
const DONE_PATTERN = new RegExp(`${DONE} (\\d+)`)

/** Ctrl-C in the terminal the person is watching, which is what stops a run. */
const INTERRUPT = '\u0003'

/**
 * The pairing code, as the host prints it.
 *
 * `renderPairCode` writes `  Pairing code   123456` and nothing else on that
 * line. Anchored on the two words rather than on the shape of the code, because
 * the shape has already changed once — *"the format has since become six digits
 * with no grouping at all"* — and a regexp that knew the shape would have
 * silently stopped matching that day.
 */
const CODE_PATTERN = /Pairing code[^\S\n]+(\S+)/

/**
 * A whole install, measured on a bare Hetzner box with no Node and no npm:
 * about 40 s to fetch and verify a Node runtime, and a minute or two for
 * `npm install` to compile node-pty. Twelve minutes is a very slow link
 * finishing; past that something is wrong in a way this app cannot see.
 */
const INSTALL_CEILING_MS = 12 * 60 * 1000

/** The host mints a code and prints it at once; thirty seconds is a slow box. */
const CODE_CEILING_MS = 30 * 1000

/** Not an exit status any shell reports, so it cannot be mistaken for one. */
const NEVER_ANSWERED = -1

/* ------------------------------------------------------------ the units -- */

/**
 * A systemd **user** unit, and why it is a user unit.
 *
 * A system unit lives in `/etc/systemd/system` and needs root to write, enable
 * and start — which §7 does not allow this feature to ask for. A user unit lives
 * in the account's own home and `systemctl --user` starts it with no privilege
 * at all.
 *
 * What that costs is stated rather than hidden: without lingering, the account's
 * systemd manager stops when the last login ends, **taking the host with it**.
 * That is the failure `HEADLESS.md` describes for WSL wearing different clothes
 * — *"a phone that was paired to it then finds nothing there, which looks
 * exactly like the app being broken"* — so the install asks for lingering, and
 * when it cannot have it, names the one command that grants it.
 *
 * `ExecStart` is `terminaldeck-host` and not `terminaldeck`, because they are two
 * programs: the second is the CLI and the first is the daemon. Measured trap:
 * when the installer supplies its own Node it writes a launcher for
 * `terminaldeck` **only**, so the daemon has to be named by its real path with
 * the private runtime on PATH — a unit pointing at `~/.local/bin/terminaldeck-host`
 * would name a file that is not there.
 */
export function serviceScript(command: string): string {
  return [
    `b=${shellQuote(command)}`,
    // Which of the two shapes this install is. The launcher names itself in a
    // comment on its second line, which is the installer's own marker.
    `if grep -q ${BRAND.id}-launcher "$b" 2>/dev/null; then`,
    `  rt="$HOME/.${BRAND.id}/runtime"`,
    `  host="$rt/bin/${BRAND.id}-host"`,
    '  bin="$rt/bin"',
    'else',
    '  bin=$(dirname "$b")',
    `  host="$bin/${BRAND.id}-host"`,
    'fi',
    '[ -x "$host" ] || { echo "no host daemon beside $b" >&2; exit 1; }',
    'mkdir -p "$HOME/.config/systemd/user" || exit 1',
    `cat > "$HOME/.config/systemd/user/${BRAND.id}.service" <<UNIT`,
    '[Unit]',
    `Description=${BRAND.name} host`,
    'After=network-online.target',
    '',
    '[Service]',
    'Type=simple',
    'ExecStart=$host',
    'Environment=PATH=$bin:/usr/local/bin:/usr/bin:/bin',
    'Restart=on-failure',
    'RestartSec=5',
    '',
    '[Install]',
    'WantedBy=default.target',
    'UNIT',
    'systemctl --user daemon-reload || exit 1',
    `systemctl --user enable --now ${BRAND.id}.service || exit 1`,
    // Lingering needs root. Asked for without sudo, so it succeeds on a box
    // whose policy allows it and fails harmlessly everywhere else — the caller
    // reads the answer back rather than assuming either way.
    'loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true',
    'printf "linger %s\\n" "$(loginctl show-user "$(id -u)" -p Linger --value 2>/dev/null)"',
    'exit 0',
  ].join('\n')
}

/**
 * The way back, and it removes exactly what was added.
 *
 * Never the data folder unless it was asked for, and never anything outside
 * `$HOME` — the guard `setup.ts` puts in front of its own remove, for the same
 * reason: every path this can be handed came from a `command -v` on the server,
 * and a machine whose PATH turns up a system copy is a machine where the honest
 * answer is to refuse.
 */
export function removeScript(command: string, dataDir: string, alsoData: boolean): string {
  return [
    `b=${shellQuote(command)}`,
    'case "$b" in "$HOME"/*) ;; *) echo "not ours to remove" >&2; exit 1 ;; esac',
    // The service first: stopping it is what releases the files below, and a
    // unit left enabled would keep trying to start a program that has gone.
    `if [ -f "$HOME/.config/systemd/user/${BRAND.id}.service" ]; then`,
    `  systemctl --user disable --now ${BRAND.id}.service >/dev/null 2>&1 || true`,
    `  rm -f "$HOME/.config/systemd/user/${BRAND.id}.service"`,
    '  systemctl --user daemon-reload >/dev/null 2>&1 || true',
    'fi',
    // Then the daemon itself, in case it was started by hand rather than by the
    // unit. Its own command is the one thing that knows how to stop it cleanly.
    '"$b" stop >/dev/null 2>&1 || true',
    `if grep -q ${BRAND.id}-launcher "$b" 2>/dev/null; then`,
    `  rm -rf "$HOME/.${BRAND.id}/runtime"`,
    '  rm -f "$b"',
    `  rmdir "$HOME/.${BRAND.id}" 2>/dev/null || true`,
    'else',
    '  d=$(dirname "$b")',
    `  rm -f "$d/${BRAND.id}" "$d/${BRAND.id}-host"`,
    `  rm -rf "$d/../lib/node_modules/${BRAND.id}"`,
    'fi',
    ...(alsoData
      ? [
          `dd=${shellQuote(dataDir)}`,
          'case "$dd" in "$HOME"/*) rm -rf "$dd" ;; *) echo "not ours to remove" >&2 ;; esac',
        ]
      : []),
    'exit 0',
  ].join('\n')
}

/**
 * One argument, safe inside single quotes.
 *
 * Every path this quotes came off the server itself — `command -v`, and the XDG
 * folder the host reads — so it is not attacker-controlled in any ordinary
 * sense. It is quoted anyway, because "not ordinarily attacker-controlled" is
 * the assumption every shell injection was built on, and because a home
 * directory with a space in it is not exotic.
 */
export function shellQuote(value: string): string {
  return `'${value.split("'").join(`'\\''`)}'`
}

/* ---------------------------------------------------------- the sessions -- */

interface Attempt {
  serverId: string
  /** Stop whatever this app started in the terminal. Null when nothing is. */
  stopRunning: (() => void) | null
}

/**
 * One host install per server at a time, and each one reports every step.
 *
 * Keyed by server rather than globally: two servers can be set up at once from
 * two pages and neither is the other's business. Keyed by server rather than
 * finer, because there is one terminal per page and the flow uses it end to end.
 */
export class ServerHosts {
  private readonly attempts = new Map<string, Attempt>()
  private readonly states = new Map<string, HostState>()

  constructor(private readonly deps: HostDeps) {}

  /** What the window last heard about one server. */
  stateOf(serverId: string): HostState {
    return this.states.get(serverId) ?? state(serverId, 'idle', '')
  }

  /** One round trip: what is on that server, and what it would take to change it. */
  async look(serverId: string): Promise<HostLook> {
    const result = await this.deps.runScript(serverId, HOST_PROBE)
    return readHostProbe(result.stdout)
  }

  private say(next: HostState): HostState {
    this.states.set(next.serverId, next)
    this.deps.broadcast(next)
    return next
  }

  /**
   * The whole install, as five steps somebody watches happen.
   *
   * Check, copy, install, start, pair — and the person is told which one is
   * running and what each finished one did. The order is not arrangeable: the
   * check decides whether to copy anything at all, and pairing needs a host that
   * is already running.
   */
  async install(
    serverId: string,
    shell: HostShell,
    look: HostLook,
    serverName: string,
  ): Promise<HostState> {
    await this.cancel(serverId)
    const attempt: Attempt = { serverId, stopRunning: null }
    this.attempts.set(serverId, attempt)

    const done: string[] = []
    const step = (which: HostStep, line: string, over: Partial<HostState> = {}): HostState =>
      this.say(state(serverId, which, line, { done: [...done], weInstalled: true, ...over }))
    const failed = (line: string, detail = ''): HostState => {
      this.attempts.delete(serverId)
      return this.say(
        state(serverId, 'failed', line, { done: [...done], detail, weInstalled: false }),
      )
    }

    /* ------------------------------------------------------------ check -- */

    step('checking', `Checking what ${serverName} has.`)
    const refusal = whyNotHost(look.room)
    if (refusal !== null) return failed(refusal)

    const pack = this.deps.hostPackage()
    if (pack === null) {
      // Guarded before the button is drawn as well. Reaching here means the
      // package went away between the look and the press, which is a real thing
      // on a developer's tree and a sentence rather than a crash.
      return failed('This copy of the app does not carry the host package any more.')
    }
    const putFile = this.deps.putFile
    if (putFile === undefined) {
      return failed('This build cannot put a file on a server, so it cannot install one from here.')
    }
    done.push(
      usableNode(look.room)
        ? `${serverName} has Node ${look.room.node} and npm, so no runtime is needed.`
        : `${serverName} has no Node 22 or newer, so the installer will fetch one and check it.`,
    )

    /* ------------------------------------------------------------- copy -- */

    step('uploading', `Copying the host package to ${serverName}.`)
    let installer: string
    let tarball: string
    try {
      // The installer first: it is small, so a server that refuses a write says
      // so in a second rather than after several megabytes.
      installer = await putFile(serverId, pack.installer, 'install.sh')
      tarball = await putFile(serverId, pack.tarball, `${BRAND.id}-${pack.version}.tgz`)
    } catch (error) {
      return failed(
        'The host package could not be copied to this server.',
        error instanceof Error ? error.message : '',
      )
    }
    done.push(`Copied the package to ${tarball}.`)

    /* ---------------------------------------------------------- install -- */

    step('installing', `Installing on ${serverName}. This takes a minute or two.`)
    const line = `TERMINALDECK_PACKAGE=${shellQuote(tarball)} sh ${shellQuote(installer)}; echo ${DONE} $?`
    attempt.stopRunning = () => shell.write(INTERRUPT)
    const code = await this.typeAndWait(shell, line, INSTALL_CEILING_MS)
    attempt.stopRunning = null
    if (code !== 0) {
      return failed(
        `The host could not be installed on ${serverName}.`,
        code === NEVER_ANSWERED
          ? 'It was still running after twelve minutes, so this stopped waiting for it.'
          : `The installer ended with ${code}. Its own output is in the terminal above.`,
      )
    }

    const after = await this.look(serverId)
    if (after.host.command === '') {
      return failed(`The install finished and there is no ${BRAND.id} command on this server.`)
    }
    done.push(`Installed ${after.host.version || 'the host'} at ${after.host.command}.`)

    /* ------------------------------------------------------------ start -- */

    step('service', 'Setting it to start on its own.')
    done.push(await this.startIt(serverId, after.host.command, look.room))

    /* ------------------------------------------------------------- pair -- */

    return this.pair(serverId, shell, after.host.command, done)
  }

  /**
   * Make it start on its own, and say what was actually arranged.
   *
   * Three outcomes and all three are said out loud, because the difference
   * between them is the difference between a machine that is there tomorrow and
   * one that is not:
   *
   *  - a user unit, with lingering — it survives a reboot and a logout;
   *  - a user unit, without lingering — it survives a reboot and **not** the end
   *    of your last login, and the command that fixes that is named;
   *  - no systemd at all — it is running now and will not survive a reboot.
   *
   * The third is not a failure of the install and is not reported as one. A
   * container has no init by design, and a host running now is what somebody
   * pressed the button for.
   */
  private async startIt(serverId: string, command: string, room: HostRoom): Promise<string> {
    if (room.systemdUser) {
      const result = await this.deps.runScript(serverId, serviceScript(command))
      if (result.code === 0) {
        return /linger yes/.test(result.stdout)
          ? 'It runs as a systemd user service and keeps running when you log out.'
          : 'It runs as a systemd user service. It will stop when your last login on this server ends — ' +
              'running `sudo loginctl enable-linger $(id -un)` once on that server is what stops that.'
      }
      // Fall through rather than fail: a unit that would not install is a reason
      // to start it another way, not a reason to leave a working install off.
    }
    const started = await this.deps.runScript(
      serverId,
      [
        `b=${shellQuote(command)}`,
        `if grep -q ${BRAND.id}-launcher "$b" 2>/dev/null; then`,
        `  h="$HOME/.${BRAND.id}/runtime/bin/${BRAND.id}-host"`,
        'else',
        `  h="$(dirname "$b")/${BRAND.id}-host"`,
        'fi',
        '[ -x "$h" ] || exit 1',
        'nohup "$h" >/dev/null 2>&1 &',
        'exit 0',
      ].join('\n'),
    )
    return started.code === 0
      ? 'This server has no systemd user manager, so it was started directly. It is running now and ' +
          'will not come back on its own after a reboot.'
      : `It is installed and not running. Start it on that server with \`${BRAND.id} pair\`.`
  }

  /**
   * Show a pairing code, in the terminal that is on screen.
   *
   * The code is read out of the terminal rather than out of an exec channel
   * because `pair` refuses to finish without a tty — see the header. What is
   * deliberately **not** done here is answering the `Approve it? [y/N]` question:
   * the fingerprint printed above it is the only part of pairing a person can
   * actually check, and an app that answered for them would have deleted the
   * check while appearing to perform it.
   */
  async pair(
    serverId: string,
    shell: HostShell,
    command: string,
    done: readonly string[] = [],
  ): Promise<HostState> {
    const attempt = this.attempts.get(serverId) ?? { serverId, stopRunning: null }
    this.attempts.set(serverId, attempt)

    this.say(
      state(serverId, 'pairing', 'Asking it for a pairing code.', {
        done: [...done],
        weInstalled: true,
      }),
    )
    attempt.stopRunning = () => shell.write(INTERRUPT)
    const code = await this.watchFor(shell, `${shellQuote(command)} pair --kind mine\n`, CODE_CEILING_MS)
    if (code === null) {
      this.attempts.delete(serverId)
      return this.say(
        state(serverId, 'failed', 'It did not print a pairing code.', {
          done: [...done],
          detail: 'Whatever it did print is in the terminal above.',
          weInstalled: true,
        }),
      )
    }

    return this.say(
      state(serverId, 'done', 'It is running and waiting to be linked.', {
        done: [...done, 'It printed a pairing code.'],
        code,
        weInstalled: true,
      }),
    )
  }

  /**
   * Take it off again, and say what is left.
   *
   * The confirmation this needs is the caller's — `removeConsequence` is the
   * sentence shown before the press. By the time this runs the answer has been
   * given, so it does the work and reports it rather than asking again.
   */
  async uninstall(serverId: string, look: HostOnServer, alsoData: boolean): Promise<HostState> {
    await this.cancel(serverId)
    if (look.command === '') {
      return this.say(state(serverId, 'failed', 'There is nothing here for this app to remove.'))
    }
    this.say(state(serverId, 'removing', 'Stopping it and taking it off this server.'))
    const result = await this.deps.runScript(
      serverId,
      removeScript(look.command, look.dataDir, alsoData),
    )
    if (result.code !== 0) {
      return this.say(
        state(serverId, 'failed', 'That could not be removed from this server.', {
          detail: result.stderr.trim(),
        }),
      )
    }
    const done = [
      'The host program is gone, and its service with it.',
      alsoData
        ? `${look.dataDir} is gone too, so any device paired to it will need pairing again.`
        : `${look.dataDir} was left alone — the devices paired to it and the folders each of them may ` +
          'use are still there for a later install.',
    ]
    return this.say(state(serverId, 'idle', 'It was removed from this server.', { done }))
  }

  /** Stop whatever this app started in that server's terminal. */
  async cancel(serverId: string): Promise<void> {
    const attempt = this.attempts.get(serverId)
    if (attempt === undefined) return
    this.attempts.delete(serverId)
    try {
      attempt.stopRunning?.()
    } catch {
      /* The terminal has already gone, which is the ordinary way this ends. */
    }
    await Promise.resolve()
  }

  /** Every server at once. For shutdown, and for the connection going away. */
  async cancelAll(): Promise<void> {
    for (const serverId of [...this.attempts.keys()]) await this.cancel(serverId)
  }

  /** Forget what was said about one server, so a fresh look starts clean. */
  forget(serverId: string): void {
    this.states.delete(serverId)
  }

  /* ------------------------------------------------------------ privates -- */

  /**
   * Type a line and answer the exit status the far end reported for it.
   *
   * The ceiling is a stated outcome rather than a safety net, exactly as in
   * `setup.ts`: a wait with no ceiling leaves the line under the terminal
   * reading *Installing…* forever, which is the one thing worse than saying it
   * did not work.
   */
  private typeAndWait(shell: HostShell, line: string, ceilingMs: number): Promise<number> {
    return new Promise<number>((resolve) => {
      let seen = ''
      let settled = false
      const done = (code: number): void => {
        if (settled) return
        settled = true
        clearTimeout(ceiling)
        stop()
        resolve(code)
      }
      const ceiling = setTimeout(() => done(NEVER_ANSWERED), ceilingMs)
      ceiling.unref?.()
      const stop = shell.onData((chunk) => {
        seen += chunk
        const match = DONE_PATTERN.exec(seen)
        if (match !== null) done(Number(match[1]))
      })
      shell.write(`${line}\n`)
    })
  }

  /**
   * Type a line and answer the first pairing code it prints, or null.
   *
   * No sentinel here, and that is the difference from {@link typeAndWait}: the
   * command being typed is *meant* to keep running — it ends up sitting on the
   * `Approve it? [y/N]` prompt the person is about to answer — so waiting for it
   * to exit would be waiting for the person to finish, with the code they need
   * to do that held back until they had.
   */
  private watchFor(shell: HostShell, line: string, ceilingMs: number): Promise<string | null> {
    return new Promise<string | null>((resolve) => {
      let seen = ''
      let settled = false
      const done = (code: string | null): void => {
        if (settled) return
        settled = true
        clearTimeout(ceiling)
        stop()
        resolve(code)
      }
      const ceiling = setTimeout(() => done(null), ceilingMs)
      ceiling.unref?.()
      const stop = shell.onData((chunk) => {
        seen += chunk
        const match = CODE_PATTERN.exec(seen)
        if (match !== null) done(match[1])
      })
      shell.write(line)
    })
  }
}
