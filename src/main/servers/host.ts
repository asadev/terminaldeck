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
 * So pairing happens in the same real terminal the install ran in, and the code
 * is read out of its output.
 *
 * ## Two endings, and only one of them shows anybody a code
 *
 * {@link ServerHosts.link} is what an install ends with: it reads the code out
 * of the terminal, redeems it here in the same second, checks the fingerprint
 * the host prints against the key this desktop actually dialled with, and
 * answers the approval question itself. Nothing is drawn, nothing is typed, and
 * the server is linked when the install says it finished. The security argument
 * for that — what is skipped, what is not, and why it cannot become a general
 * door — is written out in full above that method, because that is the point
 * where it is spent.
 *
 * {@link ServerHosts.pairDevice} is the other ending and it is the unchanged
 * one: a code, minted when somebody presses for one, for a phone to type. A
 * phone has no SSH channel to this app, so it keeps the code and it keeps the
 * fingerprint question — which is, for that path, the one part of pairing a
 * person can actually check and the one part this app must not answer for them.
 */

import { BRAND } from '../../shared/brand'
import { SERVER_ADDRESS_PREFIX, parseServerAddress } from '../../shared/server-address'
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

/** What linking this computer to a freshly installed host came to. */
export type LinkOutcome =
  | {
      ok: true
      /** That machine's id here, which is its host id. For {@link HostDeps.whenReaching}. */
      machineId: string
      /** What this app now calls that machine in its Machines list. */
      machineName: string
      /**
       * The fingerprint of the guest key **this** desktop dialled with.
       *
       * The whole point of carrying it back: the host is about to print the
       * fingerprint of whichever device redeemed the code, and these two being
       * the same string is what says it was this one. See
       * {@link ServerHosts.link}.
       */
      deviceFingerprint: string
    }
  | { ok: false; message: string }

export interface HostDeps {
  /** One script, one round trip. `ServerConnections.runScript`. */
  runScript(serverId: string, script: string): Promise<HostRunResult>
  /**
   * Redeem a pairing code this app just read out of that server's own terminal,
   * and keep the machine it names.
   *
   * `MachinesIpc.linkWithCode`, injected rather than imported for the reason
   * every other dependency here is: this module is exercised against a plain
   * object with no relay, no sockets and no Electron anywhere near it.
   *
   * Optional, and its absence is an honest fallback rather than a failure: a
   * build with no machine channels cannot redeem anything, so an install there
   * ends by *showing* a code with the sentence saying where to type it, exactly
   * as {@link ServerHosts.pairDevice} does. Never a link step that pretends.
   */
  linkThisComputer?(code: string): Promise<LinkOutcome>
  /**
   * Wait until this computer's link to a machine it has just paired with is
   * actually carrying, and answer whether it got there. `MachinesIpc.whenReaching`.
   *
   * The last unfinished sentence in this flow. Pairing ends at the far end's
   * `y`; the channel comes up a beat later, because the first dial happens while
   * that device is still **pending** over there and is refused — the flow's own
   * header says so. Returning at the `y` therefore reports a link that is,
   * for the next second or two, still nothing.
   *
   * That was harmless while nothing looked, and it stopped being harmless the
   * moment the panel started asking whether anything was connected: an install
   * that finished perfectly would have answered "nothing is reaching it" for a
   * second and a half, which is a false alarm and a control that lies in the
   * other direction.
   *
   * Optional, and absent means *do not wait*: a build with no machine channels
   * never got here at all — {@link ServerHosts.link} falls back to showing the
   * code — and a test that does not care about the channel should not sit out a
   * ceiling for one.
   */
  whenReaching?(machineId: string, ceilingMs: number): Promise<boolean>
  /**
   * How long to give a host to reach the relay, in milliseconds.
   *
   * A seam for the tests and nothing else. Every other ceiling in this file is a
   * constant, for the reason `setup.ts` gives about its own; this one is
   * overridable because a test that exercised {@link RELAY_CEILING_MS} honestly
   * would *be* twenty seconds long, and a suite nobody runs catches nothing.
   */
  relayWaitMs?: number
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
   * The code the host printed, once it has printed one **and somebody is meant
   * to read it**.
   *
   * Exactly as it was printed. `cli.ts` states the rule and the bug that made it
   * one: *"an earlier version regrouped an already-grouped code into
   * `CSPA--0EC-H`, which nobody can type."* Nothing here reformats it.
   *
   * Null for the whole of {@link ServerHosts.link}, and that is a rule rather
   * than an omission: the code that path reads is spent within the second, by
   * this app, and putting it on a state that is broadcast to every window would
   * put a live secret on a screen — and then leave a dead one there, which is
   * the exact failure that flow exists to remove.
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
  /**
   * The pasteable **server address** that host printed, or `''`.
   *
   * The one string a phone that has never met that machine can act on, and the
   * reason this field exists at all: a host id is `BASE32(SHA-256(secret))` and
   * a fingerprint is a digest of the public key, so neither can start the Noise
   * IK handshake a first connection is. Everything this panel could show before
   * was one of those two.
   *
   * Read out of the status this screen already fetches rather than asked for
   * separately — one round trip already carries it, and a second command over
   * SSH to re-derive a value that is on screen is a second thing to be out of
   * date. Empty when that host is not on a relay, which is a state the panel
   * says out loud rather than a blank.
   */
  address: string
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

/**
 * What the host's own `status` says about the relay.
 *
 * The one fact that decides whether a code that host minted could be answered
 * by anything at all: a rendezvous is published *through* the relay, so a host
 * that is not connected to one mints a code nobody can look up. Read rather
 * than assumed, because the failure it explains — an install finishing seconds
 * before the host's first relay connection completes — looks identical to an
 * expired code from this side.
 *
 * Read out of the block `renderStatus` writes rather than by grepping the whole
 * output: that block is headed `Relay` and its next line is one of exactly
 * three shapes, all three of them written in one place in `cli.ts`. A pattern
 * loose enough to find `connected` anywhere in the output would also find it in
 * the host's own first line.
 */
export type HostRelay = 'connected' | 'not-connected' | 'off' | 'unknown'

export function relayState(status: string): HostRelay {
  const lines = status.split('\n')
  const at = lines.findIndex((line) => line.trim() === 'Relay')
  if (at === -1) return 'unknown'
  const said = (lines[at + 1] ?? '').trim()
  if (said.startsWith('connected')) return 'connected'
  if (said.startsWith('not connected')) return 'not-connected'
  if (said.startsWith('off')) return 'off'
  return 'unknown'
}

/**
 * That host's public name at the relay, out of its own `status`, or `''`.
 *
 * The only thing that lets this app ask "am I already linked to *that* one" —
 * a machine's row here is keyed by host id, so the id printed on that server is
 * the join between the two. Printed only when the relay is connected, which is
 * also the only state in which the answer is worth anything.
 */
const HOST_ID_PATTERN = /^[^\S\n]*host id[^\S\n]+(\S+)/m

export function hostIdOf(status: string): string {
  return HOST_ID_PATTERN.exec(status)?.[1] ?? ''
}

/**
 * The pasteable server address out of that host's own `status`, or `''`.
 *
 * Anchored on the block `renderStatus` writes — heading `Server address`, then
 * the token on a line of its own — rather than scanning the whole output for
 * anything beginning `srv1.`. The scan would very probably be correct, because
 * the format is strict enough that a false positive is not really available; the
 * anchor is here for the same reason {@link relayState} has one, which is that
 * "very probably correct" over somebody else's machine's output is how a panel
 * ends up displaying a line from a session transcript.
 *
 * Validated with the real parser before it is returned, so what crosses to the
 * renderer either works when it is pasted or is empty. A host running a build
 * older than the address prints no such block and answers `''`, which the panel
 * draws as the sentence about upgrading rather than as a missing control.
 */
const ADDRESS_HEADING = 'Server address'

export function serverAddressOf(status: string): string {
  const lines = status.split('\n')
  const at = lines.findIndex((line) => line.trim() === ADDRESS_HEADING)
  if (at === -1) return ''
  const said = (lines[at + 1] ?? '').trim()
  if (!said.startsWith(SERVER_ADDRESS_PREFIX)) return ''
  return parseServerAddress(said) === null ? '' : said
}

/**
 * How many clients that host has open on the relay right now, or null when it
 * will not say.
 *
 * The one fact on this screen that comes from the *far* side of the question
 * "is this computer linked to it". Everything else about a link is read out of
 * this desktop's own machine rows, and a row is a claim about the past: it says
 * this computer paired, not that anything is connected. `renderStatus` prints
 * this line only inside a connected `Relay` block, so a number here is that
 * host counting its own live channels a second ago.
 *
 * Measured, and the reason this exists: his office PC, healthy, on the relay,
 * with a device of his approved in its own list — and `channels 0`. The panel
 * said *"This computer is linked to it"* over a host nothing was connected to,
 * because nothing on this side had ever asked the host. Zero is the one answer
 * that settles it in a direction worth acting on: if **nothing at all** is
 * connected there, this computer certainly is not.
 *
 * Null rather than zero when the line is missing, and the difference matters —
 * a host whose relay is off prints no channel count at all, and reading that
 * absence as "nothing is connected" would turn a host that is deliberately not
 * dialling out into a broken link.
 */
const CHANNELS_PATTERN = /^[^\S\n]*channels[^\S\n]+(\d+)/m

export function channelsOf(status: string): number | null {
  const said = CHANNELS_PATTERN.exec(status)?.[1]
  return said === undefined ? null : Number(said)
}

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
      address: serverAddressOf(status),
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
  /*
   * Said as a difference, because the old sentence sold something he already
   * had. It claimed installing this makes the server "a machine you can open a
   * session on from here" — he has been opening sessions on it from here all
   * along. What changes is what a session *is*, and that is worth stating in
   * terms of what ends today: an SSH shell lives inside the connection this app
   * holds, so it dies when the app quits, and nothing but this Mac can reach it.
   */
  return (
    `Today a session on ${serverName} is an SSH shell this app holds open. It lives inside that ` +
    'connection: it ends when this app quits or the link drops, and only this computer can reach it.\n\n' +
    `Installing the host makes ${serverName} a machine in its own right. Its sessions keep running ` +
    'when this computer is closed, you can open them from your phone, and it joins the machines list ' +
    `instead of sitting apart as a server. ${runtime} It needs no administrator access, writes only ` +
    'inside your home folder, and can be removed again from here.\n\n' +
    // The promise the install now keeps, said before the press rather than
    // discovered afterwards. It used to end holding a code somebody had to
    // spend within a minute, and this sentence would have been a lie.
    'This computer is linked to it as part of the install, so there is nothing to type in ' +
    'afterwards. A code is only for a phone, and only when you ask for one.\n\n' +
    'It has no Copilot. That part of the app needs a window, and this host has none.'
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
  // Not "nothing can run a session here" — that was false and he caught it.
  // Every session he has ever opened on a server is an SSH shell this app
  // holds, and he had been using them for weeks. What is missing is the host,
  // which is a different and smaller claim.
  if (host.command === '') return 'Sessions here run over SSH. This server is not a machine of its own yet.'
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

/**
 * The device's fingerprint, as the host prints it when something redeems a code.
 *
 * `renderNewDevice` writes `  Fingerprint    ABCD-EFGH-…` and nothing else on
 * that line. Anchored on the word rather than on the shape of a fingerprint, for
 * the same reason as {@link CODE_PATTERN} — and capital `F`, because the only
 * other place this word is printed at all is the lower-case `fingerprint` in
 * `renderStatus`'s relay block, which `pair` never prints.
 */
const FINGERPRINT_PATTERN = /Fingerprint[^\S\n]+(\S+)/

/**
 * What the host says after the approval question is answered, either way.
 *
 * Both halves are `cli.ts`'s own words — `renderApproved` for a device of kind
 * `mine`, and `renderNotApproved`, which exists because *"a CLI that reports an
 * outcome it did not read is worse than one that reports a failure"*. Read as
 * one pattern rather than two waits, because two waits racing for one line is a
 * flow that hangs whenever the wrong one is asked first.
 */
const VERDICT_PATTERN = /(Approved as your own device|was NOT approved)/

/**
 * How long the far end is given to notice a device, and to answer once it has.
 *
 * `pairWithCode` spends at most twelve seconds looking a machine up and fifteen
 * pairing with it, so the fingerprint cannot appear before the redemption
 * returns and should be on screen within a breath of it. The approval that
 * follows is one round trip to a daemon on the same box.
 */
const LINK_CEILING_MS = 45 * 1000
const VERDICT_CEILING_MS = 30 * 1000

/**
 * How long a host is given to reach the relay before a code is asked of it, and
 * how often it is asked.
 *
 * The one wait in this file that asks the same question twice, and it is here
 * for a race the install creates: the step before this starts the daemon, this
 * step asks it for a code, and **a host that has not finished dialling the relay
 * mints a code that was never published** — unfindable from the moment it was
 * printed, because a rendezvous is published through the relay. `machines:code`
 * refuses outright in that state and `pair` falls back to a code with no
 * rendezvous behind it, which is a code this app cannot look up at all.
 *
 * Measured, one layer over: `remote/server.ts` records the public demo host
 * failing in exactly this way — *"the container announced itself the moment its
 * control socket was listening and the relay dial had not finished."*
 *
 * There is nothing to subscribe to here. The host is on the far side of an SSH
 * connection and says what it is doing only when asked, so this asks, a few
 * times, and then gives up and lets the link step report what it found. Twenty
 * seconds is far longer than a datacentre handshake and far shorter than the
 * two minutes the install before it took.
 */
const RELAY_CEILING_MS = 20 * 1000
const RELAY_ASK_MS = 2 * 1000

/**
 * How many fresh codes one press of **Link this computer** is allowed to spend.
 *
 * The wait above removes the race it can see; this covers the one it cannot.
 * `waitForRelay` asks the host whether it has reached the relay, and a host
 * that says yes has still only said so about the instant it was asked — the
 * rendezvous behind a code is published when the code is minted, a beat later,
 * and on a datacentre link that beat is where an install's very first code goes
 * missing. Measured on his office PC: the host came up, the relay said
 * connected, and nothing was ever linked to it.
 *
 * Three, and each one mints its own code, because a code cannot be re-offered:
 * `pair` prints one per run and the run that printed the last one is
 * interrupted before the next is asked for. Three tries cost about a second
 * each on a healthy box and turn the commonest failure of this flow — one
 * unlucky code — into something nobody ever sees. A *fourth* would not: past
 * three, the failure is not timing, and the sentence at the end says so and
 * names the button.
 */
const LINK_TRIES = 3

/**
 * How long the channel is given to come up after that host approves this
 * computer.
 *
 * Measured on a real box: the first dial goes out while this device is still
 * pending over there and is refused, and the guest link then waits a flat one to
 * two seconds before trying again — flat, because that wait is for a person's
 * finger and not for a machine that is off. So the honest number is a couple of
 * seconds, and this is ten times that.
 *
 * What is on the other side of the ceiling is not a failure. The pairing
 * happened, the device is approved, and the panel has a sentence and a press for
 * a machine it holds a row for and cannot reach. Waiting here only makes sure
 * that whichever of the two the panel draws, it draws the true one.
 */
const REACH_CEILING_MS = 20 * 1000

/** Not an exit status any shell reports, so it cannot be mistaken for one. */
const NEVER_ANSWERED = -1

/** Nor is this, and it means somebody pressed Stop rather than the server failing. */
const STOPPED = -2

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
  /**
   * End the wait this attempt is sitting in, now.
   *
   * Kept apart from `stopRunning` because the two are about different ends of
   * the same rope. Ctrl-C stops the command on the server; this stops *this
   * side* believing the command is still running. Without it, pressing Stop
   * during an install took the terminal away and left the line underneath
   * reading "Installing on box." for the twelve minutes the ceiling allows —
   * which is a page describing work that has stopped, and the exact failure
   * every ceiling in this file exists to prevent.
   */
  giveUp: (() => void) | null
}

/**
 * Everything one terminal has said since a run started, and a way to wait for
 * the next thing it says.
 *
 * One subscription for a whole flow, rather than {@link ServerHosts.watchFor}'s
 * one subscription per wait — and the difference is not tidiness. The linking
 * flow reads three things out of this terminal in order, and the second of them
 * is printed the instant a device redeems the first. A wait that attached its
 * listener only after the redemption had been asked for would miss that line by
 * however long a handshake takes, which is the shape of race that passes on a
 * fast box and hangs on a slow one.
 *
 * Bounded by the flow that owns it: it is created for one run and closed in that
 * run's `finally`, so nothing here accumulates a terminal's output for longer
 * than the couple of minutes an install takes.
 */
class Tape {
  private seen = ''
  private readonly waiters: Array<() => void> = []
  private readonly stop: () => void

  constructor(shell: HostShell) {
    this.stop = shell.onData((chunk) => {
      this.seen += chunk
      // A copy, because a waiter that matches removes itself from this array.
      for (const look of [...this.waiters]) look()
    })
  }

  /** Stop listening. Anything still waiting is left to its own ceiling. */
  close(): void {
    this.stop()
  }

  /**
   * Throw away everything said so far, keeping the subscription.
   *
   * For the one flow that runs the same command twice. {@link Tape.next} scans
   * the whole tape from the start — which is the point of it — so a second
   * `pair` would match the *first* code and hand back a number that has already
   * been spent and refused. The listener is deliberately not re-attached: the
   * next run's output starts arriving before this side has finished asking for
   * it, and that is the race the tape exists for.
   */
  forget(): void {
    this.seen = ''
  }

  /**
   * The first capture of `pattern`, or the whole match when it has no group.
   *
   * Looks at what has already been said *before* waiting for more — that is the
   * whole point of the tape — and answers null on the ceiling or when somebody
   * presses Stop. The patterns handed to this carry no `g` flag on purpose: a
   * global regexp keeps `lastIndex` between calls and would start reading the
   * tape from wherever the previous match ended.
   */
  next(pattern: RegExp, ceilingMs: number, attempt: Attempt): Promise<string | null> {
    return new Promise<string | null>((resolve) => {
      let settled = false
      const done = (value: string | null): void => {
        if (settled) return
        settled = true
        attempt.giveUp = null
        clearTimeout(ceiling)
        const at = this.waiters.indexOf(look)
        if (at >= 0) this.waiters.splice(at, 1)
        resolve(value)
      }
      const look = (): void => {
        const match = pattern.exec(this.seen)
        if (match !== null) done(match[1] ?? match[0])
      }
      const ceiling = setTimeout(() => done(null), ceilingMs)
      ceiling.unref?.()
      attempt.giveUp = () => done(null)
      this.waiters.push(look)
      look()
    })
  }
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
    const attempt: Attempt = { serverId, stopRunning: null, giveUp: null }
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
    const code = await this.typeAndWait(shell, line, INSTALL_CEILING_MS, attempt)
    attempt.stopRunning = null
    if (code === STOPPED) return failed(`Stopped before ${serverName} had finished installing it.`)
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

    /* ------------------------------------------------------------- link -- */

    /*
     * The install ends linked, not holding a code.
     *
     * This is the last step because it is the one that makes the four before it
     * worth anything: a host nothing is paired to is a program running on
     * somebody's server that no screen in this app can reach. It used to end by
     * printing a code and a button, and the code was dead by the time anybody
     * read the panel. See {@link ServerHosts.link}.
     */
    return this.link(serverId, shell, after.host.command, done)
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
   * Show a pairing code, in the terminal that is on screen — **for a phone**.
   *
   * The unchanged half of this feature, and it is a press of its own because a
   * phone is the only thing left that needs one. Somebody who wants to reach
   * this server from their pocket asks for a code, gets a fresh one with its own
   * minute in front of it, and types it in. Nothing is left on screen from an
   * earlier step, because nothing but this press mints one.
   *
   * The code is read out of the terminal rather than out of an exec channel
   * because `pair` refuses to finish without a tty — see the header. What is
   * deliberately **not** done here is answering the `Approve it? [y/N]`
   * question: the device on the other end of this code is one this app has
   * never met and holds no channel to, so the fingerprint printed above that
   * prompt is the only part of pairing a person can actually check, and an app
   * that answered for them would have deleted the check while appearing to
   * perform it. {@link ServerHosts.link} is a different case for a stated
   * reason, and its argument does not reach across to here.
   */
  async pairDevice(
    serverId: string,
    shell: HostShell,
    command: string,
    done: readonly string[] = [],
  ): Promise<HostState> {
    const attempt = this.attempts.get(serverId) ?? { serverId, stopRunning: null, giveUp: null }
    this.attempts.set(serverId, attempt)

    this.say(
      state(serverId, 'pairing', 'Asking it for a pairing code.', {
        done: [...done],
        weInstalled: true,
      }),
    )
    attempt.stopRunning = () => shell.write(INTERRUPT)
    const code = await this.watchFor(
      shell,
      `${shellQuote(command)} pair --kind mine\n`,
      CODE_CEILING_MS,
      attempt,
    )
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
      state(serverId, 'done', 'It is running and showing a code for a phone.', {
        done: [...done, 'It printed a pairing code.'],
        code,
        weInstalled: true,
      }),
    )
  }

  /**
   * Link **this computer** to that host, with no code on any screen.
   *
   * ## Why no code is shown, and what is still checked
   *
   * A pairing code exists for one reason: two machines that have never met need
   * a shared secret a person can carry between them. The fingerprint question
   * exists for the matching reason — the peer is unknown, so somebody has to
   * look at it.
   *
   * Neither is true here. **This app installed that host itself, minutes ago,
   * over an SSH connection the person configured and this app authenticated.**
   * It uploaded the package over that connection's SFTP channel, ran the
   * installer down that connection's shell, and read the version back off the
   * machine. Then the host prints the code into *that same connection's own
   * terminal*, and this reads it there. A six-digit secret carried over a
   * channel this app has already authenticated is not made stronger by being
   * displayed to a person and typed back in — it is only made a minute older.
   * That minute is the whole of the bug this replaces: the code was printed
   * during the install, the panel went on drawing it after it had died, and the
   * press that spent it asked the relay for a machine that had stopped showing
   * it. The round trip through a person's eyes bought nothing and cost that.
   *
   * So what is skipped is a person's eyes. Every check the protocol makes still
   * happens, in the same order and in the same code — `machines/pair.ts`, the
   * same function the typed path calls:
   *
   *  - the rendezvous lookup at the relay, keyed on the code, which answers with
   *    an address and nothing else;
   *  - the Noise IK handshake against that machine's real static key, which is
   *    what proves the peer is the machine the rendezvous named rather than the
   *    relay answering for it;
   *  - the one-shot token, redeemed at the far end and spendable once;
   *  - the device left **pending** at that host until the approval below, which
   *    is why a `welcome` here is followed by a refused connection.
   *
   * And the fingerprint is not skipped either — it is checked *harder*. The
   * host prints the fingerprint of whichever device redeemed the code; this
   * compares it character for character against the fingerprint of the guest key
   * this desktop dialled with, which came back from the redemption. A person
   * holding two screens is performing the same comparison with worse equipment
   * and more ways to give up half way. When the two differ, something other than
   * this computer redeemed the code: this answers **n**, and says so.
   *
   * ## Why this cannot become a general "link without a code" door
   *
   * Because there is no door — there is a shell. The authority is not a flag on
   * a request that some other caller could set; it is possession of a terminal
   * on that machine. The code is minted by that host, printed on that
   * connection, and read back off that connection, so this can only ever link
   * the one machine whose terminal a run started by this app is holding. There
   * is no argument to it naming a machine, and nothing here can be aimed at a
   * server somebody did not just open a connection to.
   *
   * ## What one press is responsible for, and where that line moved to
   *
   * Twice now, and both times for the same measured failure — his office PC on
   * 2026-08-22: the host installed, running, connected to the relay, up two
   * hours, and **nothing linked to it**.
   *
   *  - **A missed code is not an answer.** The rendezvous behind a code is
   *    published a beat after the code is minted, and a host that has just
   *    started is exactly where that beat goes missing. One press now spends up
   *    to {@link LINK_TRIES} fresh codes; only when all of them go unanswered
   *    does a sentence come back, and it names the button rather than describing
   *    it. Everything else the far end can say is an *answer* and is still final
   *    on the first try.
   *  - **Approved is not connected.** This used to return at the far end's `y`,
   *    which is a second or two before the channel exists — the first dial goes
   *    out while this device is still pending over there and is refused. So it
   *    waits, through {@link HostDeps.whenReaching}, and the last sentence on
   *    screen says which of the two actually happened.
   *
   * ## What is deliberately unchanged
   *
   * The phone path, entirely. A phone has no SSH channel to this app, so none of
   * the argument above applies to it: it keeps the code, it keeps the minute,
   * and it keeps the fingerprint question — {@link ServerHosts.pairDevice}.
   */
  async link(
    serverId: string,
    shell: HostShell,
    command: string,
    done: readonly string[] = [],
  ): Promise<HostState> {
    const linkThisComputer = this.deps.linkThisComputer
    /*
     * A build with no machine channels cannot redeem anything, so it does the
     * honest thing instead of a half-step: it shows the code and says where to
     * type it. Never a link that reports success it did not perform.
     */
    if (linkThisComputer === undefined) return this.pairDevice(serverId, shell, command, done)

    const attempt = this.attempts.get(serverId) ?? { serverId, stopRunning: null, giveUp: null }
    this.attempts.set(serverId, attempt)
    const failed = (line: string, detail = ''): HostState => {
      this.attempts.delete(serverId)
      return this.say(
        state(serverId, 'failed', line, { done: [...done], detail, weInstalled: true }),
      )
    }

    this.say(
      state(serverId, 'pairing', 'Linking it to this computer.', {
        done: [...done],
        weInstalled: true,
      }),
    )
    attempt.stopRunning = () => shell.write(INTERRUPT)

    /**
     * Somebody pressed Stop, rather than the far end going quiet.
     *
     * {@link ServerHosts.cancel} drops the attempt from the map *before* it
     * wakes whatever is waiting, so an attempt that is no longer the registered
     * one is the one signal that tells the two apart. They need telling apart:
     * "it did not print a pairing code" is a sentence about the server, and
     * somebody who pressed Stop would read it as a fault they had caused.
     */
    const stopped = (): boolean => this.attempts.get(serverId) !== attempt

    /*
     * One tape for the whole flow, attached before anything is typed.
     *
     * Three things are read out of this terminal in order — a code, a
     * fingerprint, a verdict — and the second is printed the instant a device
     * redeems the first. A wait that attached its listener only once the
     * redemption had been asked for would miss that line by however long a
     * handshake takes: a race that passes on a fast box and hangs on a slow one.
     */
    const tape = new Tape(shell)
    try {
      /*
       * One code is an attempt; three is the press doing its job.
       *
       * What changed and why: this used to mint one code, and a code that
       * nothing answered ended the whole thing with a sentence asking the
       * person to press the button again. That is the app handing back its own
       * retry — and it is the failure that was measured on his office PC, where
       * a healthy host sat on the relay for two hours with nothing linked to it.
       * A miss at the relay is a timing accident, not an answer, so this spends
       * {@link LINK_TRIES} fresh codes before it accepts one.
       *
       * Every other way this can end is still final on the first try, and that
       * is deliberate: a host that shows somebody else's fingerprint, or refuses
       * the approval, has said something, and repeating a question that has been
       * answered is how a retry loop turns into a machine hammering a stranger's
       * server.
       */
      let linked: Extract<LinkOutcome, { ok: true }>
      for (let go = 1; ; go += 1) {
        /*
         * Give it a moment to reach the relay before asking it for a code. See
         * {@link RELAY_CEILING_MS}: a code minted before the dial finishes was
         * never published, so nothing could ever answer it — and an install
         * reaches this line seconds after starting the daemon.
         *
         * Asked again before every try rather than once before the first,
         * because a host that was still dialling when the last code was minted
         * is exactly the host worth waiting for now — and because the round trip
         * is also the pause between tries, which keeps this from spending three
         * codes inside one second on a box that has genuinely gone.
         */
        await this.waitForRelay(serverId, stopped)
        if (stopped()) return failed('Stopped before it had asked for a pairing code.')

        // Everything the last try said, thrown away before this one types. The
        // tape is scanned from the start, so without this a second `pair` would
        // hand back the first code — already spent, already refused.
        tape.forget()
        shell.write(`${shellQuote(command)} pair --kind mine\n`)
        const code = await tape.next(CODE_PATTERN, CODE_CEILING_MS, attempt)
        if (code === null) {
          return stopped()
            ? failed('Stopped before it had printed a pairing code.')
            : failed('It did not print a pairing code.', 'Whatever it did print is in the terminal above.')
        }

        const outcome = await linkThisComputer(code)
        /*
         * Pressed while the redemption was in flight, which is the one gap no
         * `giveUp` reaches — nothing is waiting on the terminal for those few
         * seconds, so a Stop lands with no wait to wake. Answered here instead,
         * because the alternative is sitting out a forty-five second ceiling for
         * a prompt in a terminal the person has already taken away, and then
         * blaming the server for not printing it.
         */
        if (stopped()) {
          return failed(
            'Stopped while linking.',
            outcome.ok
              ? `This computer paired with that host as ${outcome.machineName}, and nothing approved it, ` +
                'so it can reach nothing yet. Link this computer again to finish it with a fresh code.'
              : '',
          )
        }
        if (outcome.ok) {
          linked = outcome
          break
        }

        // The command is still sitting there waiting for a device that is not
        // coming. Stopped rather than left, or the panel would say this failed
        // while a live code went on standing at the relay — and the next try
        // needs this terminal back to type into.
        shell.write(INTERRUPT)
        if (go < LINK_TRIES) continue

        // Two sentences from two places, and both are wanted: the first is why
        // the redemption failed, the second is which of that refusal's two
        // causes this actually was. Either can be empty, and neither is padded.
        //
        // Asked again rather than reusing what the wait above settled on,
        // because the interesting minute is the one that has just passed: a host
        // that came up on the relay while the code was in flight is a different
        // story from one that never did, and only a fresh answer tells them
        // apart.
        const why = await this.whyNothingAnswered(serverId)
        // Named as the *linking* failing rather than the install, because by
        // this point the host is installed and running on that server and a
        // line that read like a failed install would send somebody to undo work
        // that is fine. The finished steps above it stay on screen for the same
        // reason, and the button is named rather than described — it is on this
        // panel, under this sentence, and it says exactly this.
        return failed(
          'The host is installed and running, and could not be linked to this computer.',
          [
            outcome.message,
            why,
            `A fresh code was minted and offered ${LINK_TRIES} times. Press Link this computer to try again.`,
          ]
            .filter((part) => part !== '')
            .join(' '),
        )
      }

      const shown = await tape.next(FINGERPRINT_PATTERN, LINK_CEILING_MS, attempt)
      if (shown === null) {
        if (stopped()) return failed('Stopped before that host had shown the new device.')
        shell.write(INTERRUPT)
        return failed(
          'This computer paired with that host, and the host never said so.',
          'The terminal printed no new device, so there was no fingerprint to check and nothing to ' +
            'approve. This computer is left paired and unapproved over there, which can reach ' +
            'nothing. Link this computer again to try with a fresh code.',
        )
      }
      /*
       * The check the person is no longer making, made properly.
       *
       * Not a formality: what this rules out is another device having redeemed
       * the code in the moment it was live. Answered `n` rather than simply
       * abandoned, because that is the answer to the question actually on
       * screen, and it leaves the intruder paired-and-locked-out rather than
       * waiting on a prompt nobody is going to answer.
       */
      if (shown !== linked.deviceFingerprint) {
        shell.write('n\n')
        return failed(
          'Something other than this computer answered that pairing code.',
          `That host is showing ${shown}, and this computer paired as ${linked.deviceFingerprint}. ` +
            'It was refused rather than approved, so nothing was let in: whatever did answer is left ' +
            'over there paired and unapproved, which can reach nothing, and so is this computer. ' +
            'Link this computer again to try with a fresh code.',
        )
      }

      shell.write('y\n')
      const verdict = await tape.next(VERDICT_PATTERN, VERDICT_CEILING_MS, attempt)
      if (verdict !== 'Approved as your own device') {
        if (stopped()) return failed('Stopped before that host had answered the approval.')
        return failed(
          'That host did not approve this computer.',
          verdict === null
            ? 'It never answered the approval. Its own output is in the terminal above.'
            : 'It said so itself; its words are in the terminal above.',
        )
      }

      /*
       * Approved is not connected, and this is where the two used to be the same
       * word.
       *
       * The first dial went out while this device was still pending over there
       * and was refused; the approval has only just landed. So this waits for
       * the channel rather than announcing one — see {@link REACH_CEILING_MS} —
       * and the difference is not pedantry: the panel behind this now asks that
       * host how many channels it has open, and an install that returned at the
       * `y` would have made a perfectly good one accuse itself for a second and
       * a half.
       */
      this.say(
        state(serverId, 'pairing', 'Approved. Waiting for this computer to reach it.', {
          done: [...done],
          weInstalled: true,
        }),
      )
      const reaching = (await this.deps.whenReaching?.(linked.machineId, REACH_CEILING_MS)) ?? true

      this.attempts.delete(serverId)
      return this.say(
        state(
          serverId,
          'done',
          reaching
            ? 'It is running, and linked to this computer.'
            : 'It is running and linked to this computer, and this computer has not reached it yet.',
          {
            done: [
              ...done,
              `It is linked to this computer as ${linked.machineName}, approved as your own device.`,
            ],
            // Said here rather than left to the panel, because this is the one
            // moment somebody is actually watching. The panel says it too, from
            // the host's own channel count, every time the page is opened.
            detail: reaching
              ? ''
              : 'That host approved this computer, and no connection to it has come up since. It ' +
                'usually takes a second or two. If the section above still says nothing is reaching ' +
                'it, press Link this computer to pair again with a fresh code.',
            weInstalled: true,
          },
        ),
      )
    } finally {
      tape.close()
    }
  }

  /**
   * Wait for that host to say it is on the relay, and answer what it settled on.
   *
   * Only `not-connected` is worth waiting on. `connected` is done; `off` means
   * that host is not dialling out at all, which no amount of waiting changes;
   * and `unknown` is a host too old to print the block, so waiting for a
   * sentence it will never write would be twenty seconds spent on nothing.
   *
   * Answers rather than refuses, always: this is a courtesy that removes a race,
   * not a gate. A host that never reaches the relay still gets its code asked
   * for, and the sentence the person reads is written by the step that actually
   * failed rather than by this one guessing ahead of it.
   */
  private async waitForRelay(serverId: string, stopped: () => boolean): Promise<HostRelay> {
    const ceiling = this.deps.relayWaitMs ?? RELAY_CEILING_MS
    const until = Date.now() + ceiling
    for (;;) {
      let seen: HostRelay
      try {
        seen = relayState((await this.look(serverId)).host.status)
      } catch {
        // The connection went with the terminal. The step after this says what
        // it could not do; there is nothing useful to add here.
        return 'unknown'
      }
      if (seen !== 'not-connected' || stopped() || Date.now() >= until) return seen
      await new Promise<void>((wake) => {
        const timer = setTimeout(wake, Math.min(RELAY_ASK_MS, ceiling))
        timer.unref?.()
      })
    }
  }

  /**
   * Why nothing answered a code that host had just minted — in that host's own
   * terms, or `''` when it will not say.
   *
   * Worth the extra round trip because the two causes have nothing in common. A
   * host that is not connected to the relay never published a rendezvous at all,
   * so the code was unfindable from the moment it was printed and trying again
   * will fail the same way; a host that *is* connected minted a code that was
   * simply not answered in time, and another press is the whole remedy. Telling
   * somebody to try again in the first case is telling them to wait for a minute
   * to pass twice.
   */
  private async whyNothingAnswered(serverId: string): Promise<string> {
    let relay: HostRelay = 'unknown'
    try {
      relay = relayState((await this.look(serverId)).host.status)
    } catch {
      // The connection went with the terminal, which is an ordinary way for this
      // to end. The sentence above it already says what happened.
      return ''
    }
    if (relay === 'connected') {
      return 'That host says it is connected to the relay, so the code was published and simply was not answered in time. Linking again mints a fresh one.'
    }
    if (relay === 'not-connected' || relay === 'off') {
      return `That host says its relay is ${relay === 'off' ? 'off' : 'not connected'}, so there was nothing at the relay to answer for the code. It has just started; give it a moment and link again.`
    }
    return ''
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
    // Then this side. The command may or may not have heard the Ctrl-C — the
    // terminal it was typed into is usually already closing — but the line
    // under it must stop claiming the work is still going either way.
    attempt.giveUp?.()
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
  private typeAndWait(
    shell: HostShell,
    line: string,
    ceilingMs: number,
    attempt: Attempt,
  ): Promise<number> {
    return new Promise<number>((resolve) => {
      let seen = ''
      let settled = false
      const done = (code: number): void => {
        if (settled) return
        settled = true
        attempt.giveUp = null
        clearTimeout(ceiling)
        stop()
        resolve(code)
      }
      const ceiling = setTimeout(() => done(NEVER_ANSWERED), ceilingMs)
      ceiling.unref?.()
      attempt.giveUp = () => done(STOPPED)
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
  private watchFor(
    shell: HostShell,
    line: string,
    ceilingMs: number,
    attempt: Attempt,
  ): Promise<string | null> {
    return new Promise<string | null>((resolve) => {
      let seen = ''
      let settled = false
      const done = (code: string | null): void => {
        if (settled) return
        settled = true
        attempt.giveUp = null
        clearTimeout(ceiling)
        stop()
        resolve(code)
      }
      const ceiling = setTimeout(() => done(null), ceilingMs)
      ceiling.unref?.()
      attempt.giveUp = () => done(null)
      const stop = shell.onData((chunk) => {
        seen += chunk
        const match = CODE_PATTERN.exec(seen)
        if (match !== null) done(match[1])
      })
      shell.write(line)
    })
  }
}
