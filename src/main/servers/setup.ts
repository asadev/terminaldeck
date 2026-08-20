/**
 * Putting Claude Code on somebody's server, and signing it in, in two presses.
 *
 * ## What he asked for
 *
 * > *"when we connect a server it should check if there is already a Claude CLI
 * > installed or not if not then it will give us some maybe steps or it will
 * > start a installation in that server … all the AI connection installation
 * > should be like very few simple seamless steps so anyone can easily install
 * > without any hard efforts and he can log in and all that stuff"*
 *
 * Two presses is the whole target: **Set it up**, then **Install**. The sign-in
 * follows the install without a third press, because a wizard that stops
 * halfway and waits to be prodded is the thing he was complaining about.
 *
 * ## The one narrow exception to §7, stated rather than smuggled
 *
 * `SERVERS-DESIGN.md` §7 lists *"installing software"* as a non-goal —
 * *"provisioning, not control"* — and that is still the rule. This is the
 * exception it now names: **one program, into the account's own home, with no
 * administrator access, with a way back, driven by a person pressing a button.**
 * It is not a package manager and it cannot become one: there is no name field,
 * no version field, and nothing here reads a string from anywhere but this file.
 *
 * ## Why the sign-in never touches this app
 *
 * `ACCOUNT-MODEL.md` is binding — *"this app never holds the credential, so
 * there is nothing here for DPAPI to protect"* — and it rejects by name the
 * three obvious routes: reading the keychain back, running our own flow against
 * Claude Code's client id, and asking somebody to paste a token in.
 *
 * This does none of them. `claude` on the server runs **its own** flow, with its
 * own client id, and writes **its own** credential. All this app contributes is
 * a browser on this Mac and a socket carrying the redirect back down to the
 * server's own waiting listener — see `setup-tunnel.ts`. The authorization code
 * is never parsed, stored, logged or typed here; it is bytes on a socket for the
 * few milliseconds it is in flight.
 *
 * The browser used is the person's own, through the host's `openInBrowser`,
 * rather than this app's bound browser. That is a deliberate narrowing of what
 * was specified: the bound browser reports every navigation to the main process
 * as `BoundWindow.url`, so the redirect — which *is* the code — would land in an
 * in-memory field and a navigation history. Single-use and thirty seconds old is
 * still held, and the rule has no exception for brief. The person's own browser
 * is where this flow already happens on every desktop machine, and it is not
 * ours to record.
 *
 * ## Why the install runs in the terminal that is already on screen
 *
 * Because `connection.ts` already argues for exactly this, about landing a
 * session in a folder: the two ways to do something in somebody's shell are to
 * exec it invisibly or to *type the line the person would have typed*, and the
 * second is the honest one — *"the line is echoed by the far end, so it is
 * visible in the scrollback rather than hidden."* Sixty seconds of a real
 * installer's real output scrolling past is the most truthful progress bar
 * available.
 *
 * ## No copilot, ever
 *
 * There is no entry for any of this in `tools.ts` and there must not be.
 * §6.1: *"There is no `servers.run`, and there will not be one in v1."* This is
 * a person pressing a button in zone three, and `no-run-tool.test.ts` pins the
 * tool list at three names.
 */

import type { AgentFact, AgentId, AgentInstallRoom, ServerFacts } from './facts'
import type { ForwardingConnection } from './forward'
import { forwardOn } from './forward'
import { openSetupTunnel, type SetupTunnel } from './setup-tunnel'

/* --------------------------------------------------------- what it needs -- */

/** What one command on the server answered. The shape `connection.ts` returns. */
export interface SetupRunResult {
  /** Null when a signal stopped it, which is a failure like any non-zero. */
  code: number | null
  stdout: string
  stderr: string
}

/**
 * The terminal on screen, as this file needs it.
 *
 * Named structurally rather than imported so that the whole flow can be
 * exercised against a plain object with no `ssh2` within reach — the same
 * argument `ipc.ts` makes for taking its transport as a dependency, and the
 * same one `forward.ts` makes for not naming the client class.
 */
export interface SetupShell {
  onData(listener: (chunk: string) => void): () => void
  write(data: string): void
}

export interface SetupDeps {
  /** One script, one round trip. `ServerConnections.runScript`. */
  runScript(serverId: string, script: string): Promise<SetupRunResult>
  /**
   * Borrow the live connection for as long as a sign-in is being attempted.
   *
   * The same seam `reach.ts` takes, for the same reason: the pool
   * reference-counts, so holding one open here is a hold the page's own
   * connection joins rather than a second socket to the same machine.
   */
  withConnection<T>(
    serverId: string,
    fn: (client: ForwardingConnection) => Promise<T>,
  ): Promise<T>
  /** Open a web address in the person's own browser. Absent means no seamless sign-in. */
  openInBrowser?(url: string): Promise<void>
  /** Push the state to every window. */
  broadcast(state: SetupState): void
}

/* ------------------------------------------------------------ the state -- */

/**
 * Where one server's setup has got to.
 *
 * Six steps and no seventh. `failed` carries the server's own last words rather
 * than a rewrite of them, because the installer's own final line — no space
 * left, checksum mismatch, connection refused — is more useful than any sentence
 * this file could compose about it.
 */
export type SetupStep =
  | 'idle'
  | 'installing'
  | 'installed'
  | 'signing-in'
  | 'done'
  | 'failed'

export interface SetupState {
  serverId: string
  /**
   * Which of the three rows this is about.
   *
   * On the state rather than only on the call because the state is *pushed*:
   * three rows are on screen, any of them can be mid-install, and a push with
   * no name on it would light up whichever row happened to be listening.
   */
  agentId: AgentId
  step: SetupStep
  /** The one line under the terminal. Written here, never in the renderer. */
  line: string
  /** The server's own words, when something failed. Shown behind a disclosure. */
  detail: string
  /**
   * True when the sign-in has fallen back to being finished by hand.
   *
   * Never silently substituted: the line above says which of the two paths they
   * are on, because a sign-in that quietly became a copy-and-paste job is a
   * sign-in that appears to have hung.
   *
   * There is deliberately no address on this. The address that works for a
   * person doing it themselves is the *other* one — `claude` prints a
   * `platform.claude.com` address on the terminal under "If the browser didn't
   * open, visit:", and it is a different address from the one handed to
   * `$BROWSER`, which redirects to a listener on the server and reaches nothing
   * from here. That printed address is already on screen, three lines above the
   * prompt it goes with, so the honest thing is to point at the terminal rather
   * than to put a second, non-working address beside it.
   */
  byHand: boolean
  /** True once this app put it here, which is what makes a way back honest. */
  weInstalled: boolean
  /** The version now on the server, once we know it. */
  version: string | null
}

function state(
  serverId: string,
  agentId: AgentId,
  step: SetupStep,
  line: string,
  over: Partial<SetupState> = {},
): SetupState {
  return {
    serverId,
    agentId,
    step,
    line,
    detail: '',
    byHand: false,
    weInstalled: false,
    version: null,
    ...over,
  }
}

/* ------------------------------------------------------- the three rows -- */

/**
 * How one agent is put on a server and signed in there.
 *
 * ## Why this is a table and not three files
 *
 * Because the three differ in exactly four places — what installs them, what
 * that needs, where the binary lands, and how their sign-in works — and are
 * identical everywhere else. Written as three flows they would drift, and the
 * one that got the attention would be Claude Code, which is the failure he
 * named on 2026-08-19:
 *
 *   > *"where we can have an option between Claude, Codex, Gemini, in those
 *   > places don't name only Claude. Give all the options, so they don't feel
 *   > like it is all about Claude. Maybe some users are only using Codex, they
 *   > never use Claude."*
 *
 * The first version of this file shipped Claude-only. This is that overruled.
 *
 * ## Everything in it was measured on a real machine
 *
 * Ubuntu 24.04 WSL2, Node 22.23.1, on 2026-08-19 and again on 2026-08-20 for
 * the two new rows. Every number below — the seconds, the megabytes, the port,
 * the shape of each sign-in — came off that box rather than out of a vendor's
 * README, and the `verified` note on each row says what was run and what it
 * answered. Nothing here is a flow somebody hoped would work.
 */
interface AgentSetup {
  id: AgentId
  /** The agent's own name. Part 1 of the naming rule: this row *is* that agent. */
  label: string
  /** The command typed into the terminal, or null when this server cannot run it. */
  install(room: AgentInstallRoom): string | null
  /** Why there is no button, in the server's own terms. Null when nothing is in the way. */
  whyNot(room: AgentInstallRoom): string | null
  /** The sentence shown before the button, with this server's name in it. */
  consequence(serverName: string): string
  /** How its sign-in behaves on a headless machine. See {@link SignInShape}. */
  signIn: SignInShape
  /** What `remove` deletes besides the binary itself, relative to `$HOME`. */
  leaves: readonly string[]
  /** What a device-code sign-in opens on this Mac. Only for `device-code`. */
  deviceUrl: string | null
  /** What was run on the real box, and what it said. Kept beside the claim it supports. */
  verified: string
}

/**
 * The three shapes a headless sign-in can take, and all three were measured.
 *
 *  - **`browser-shim-tunnel`** — the agent opens a listener on a *random*
 *    loopback port and hands the address to `$BROWSER`, printing a different
 *    address on the terminal. The port cannot be read off the screen, so a
 *    scratch script captures it and this app forwards that port down to the
 *    server. Fully seamless: the person presses nothing after the browser
 *    opens. Claude Code, and only Claude Code.
 *  - **`device-code`** — the agent prints a fixed address and a short code and
 *    opens no listener at all. This app opens the address on this Mac; the
 *    person types the code that is already on the terminal in front of them.
 *    One typed code, no socket. Codex, which recommends this itself on a remote
 *    machine in as many words.
 *  - **`in-terminal`** — the agent has no login command, prints its address
 *    inside its own full-screen interface, and asks for the code back at a
 *    prompt. There is nothing to forward and nothing to capture, so this app
 *    starts it and says plainly what to do. Gemini CLI.
 *
 * The third is not a stub and it is not a degraded version of the first. It is
 * what that CLI actually offers on a machine with no browser, and a wizard that
 * pretended otherwise would strand somebody halfway — which is the first thing
 * he would hit.
 */
export type SignInShape = 'browser-shim-tunnel' | 'device-code' | 'in-terminal'

/**
 * Measured: exit 137 is the kernel killing the Claude installer, and the
 * installer names this figure itself.
 */
const MEMORY_NEEDED_KB = 512 * 1024

/**
 * What each install writes, a little above what it actually wrote.
 *
 * Measured into a scratch prefix and removed after: 316 MB for Claude Code,
 * 296 MB for Codex, 100 MB for Gemini.
 */
const DISK_NEEDED_KB = { claude: 350 * 1024, codex: 330 * 1024, gemini: 130 * 1024 } as const

/** Free space in the account's own home, or null when the server would not say. */
function roomOnDisk(room: AgentInstallRoom, neededKb: number): string | null {
  if (room.homeFreeKb === null || room.homeFreeKb >= neededKb) return null
  return (
    `There is ${Math.round(room.homeFreeKb / 1024)} MB free in your home folder on this server ` +
    `and this needs about ${Math.round(neededKb / 1024)} MB.`
  )
}

/**
 * The npm install line, and why it carries a prefix.
 *
 * Measured on the real box: `npm prefix -g` there is `/usr`, and both `/usr/bin`
 * and `/usr/lib/node_modules` are root-owned — so a bare `npm install -g` would
 * need administrator access, which `SERVERS-DESIGN.md` §7 does not allow this
 * feature to ask for. `--prefix "$HOME/.local"` puts the package under the
 * account's own home instead and the binary in `~/.local/bin`, which is the
 * same folder Claude Code's own installer uses and is already on the widened
 * path this app searches. Both installs were run that way as an ordinary user
 * and both exited 0.
 */
function npmInstall(pkg: string): string {
  return `npm install -g --prefix "$HOME/.local" ${pkg}`
}

const AGENTS: Readonly<Record<AgentId, AgentSetup>> = {
  claude: {
    id: 'claude',
    label: 'Claude Code',
    /*
     * `wget` is not a nicety. The script accepts either and plenty of minimal
     * server images ship exactly one of them, so an app that only knew `curl`
     * would report "no way to download files" about a machine that has one.
     */
    install: (room) =>
      room.downloader === 'curl'
        ? 'curl -fsSL https://claude.ai/install.sh | bash'
        : room.downloader === 'wget'
          ? 'wget -qO- https://claude.ai/install.sh | bash'
          : null,
    whyNot: (room) => {
      if (room.downloader === '') {
        return 'This server has no way to download files. Someone will need to add one first.'
      }
      if (room.memoryAvailableKb !== null && room.memoryAvailableKb < MEMORY_NEEDED_KB) {
        return (
          `This server has ${Math.round(room.memoryAvailableKb / 1024)} MB of memory free and the ` +
          'download needs about 512 MB. It would be stopped part-way.'
        )
      }
      return roomOnDisk(room, DISK_NEEDED_KB.claude)
    },
    consequence: (serverName) =>
      `This downloads Claude Code (about 320 MB) into your own home folder on ${serverName}. ` +
      'It takes about a minute. It does not need administrator access and does not change anything ' +
      'else on the server. You can remove it again from here.',
    signIn: 'browser-shim-tunnel',
    leaves: ['.local/share/claude/versions'],
    deviceUrl: null,
    verified:
      '`curl -fsSL https://claude.ai/install.sh | bash` into a scratch home: exit 0, 62 s, 316 MB, no Node, ' +
      'no root — the installer refuses to run under sudo. Landed at `~/.local/bin/claude` and edited no shell ' +
      'rc file. `auth login --claudeai` opened a listener on a random loopback port, and a request forwarded ' +
      'to it from this Mac was answered 302.',
  },
  codex: {
    id: 'codex',
    label: 'Codex CLI',
    install: (room) => (room.npm === '' ? null : npmInstall('@openai/codex')),
    whyNot: (room) => {
      if (room.npm === '') {
        return 'This server has no npm, which is what installs Codex CLI. Someone will need to add Node first.'
      }
      return roomOnDisk(room, DISK_NEEDED_KB.codex)
    },
    consequence: (serverName) =>
      `This installs Codex CLI (about 300 MB) into your own home folder on ${serverName}, using the npm ` +
      'that is already there. It takes a few seconds. It does not need administrator access and does not ' +
      'change anything else on the server. You can remove it again from here.',
    signIn: 'device-code',
    leaves: ['.local/lib/node_modules/@openai/codex'],
    deviceUrl: 'https://auth.openai.com/codex/device',
    verified:
      '`npm install -g --prefix "$HOME/.local" @openai/codex` as an ordinary user: exit 0, 6 s, 296 MB, ' +
      'landed at `~/.local/bin/codex`, version `codex-cli 0.148.0`. `codex login` opened `127.0.0.1:1455` ' +
      'and printed its own advice — *"On a remote or headless machine? Use `codex login --device-auth` ' +
      'instead."* `--device-auth` printed a fixed address and a ten-character code expiring in 15 minutes, ' +
      'and opened no listener at all.',
  },
  gemini: {
    id: 'gemini',
    label: 'Gemini CLI',
    install: (room) => (room.npm === '' ? null : npmInstall('@google/gemini-cli')),
    whyNot: (room) => {
      if (room.npm === '') {
        return 'This server has no npm, which is what installs Gemini CLI. Someone will need to add Node first.'
      }
      return roomOnDisk(room, DISK_NEEDED_KB.gemini)
    },
    consequence: (serverName) =>
      `This installs Gemini CLI (about 100 MB) into your own home folder on ${serverName}, using the npm ` +
      'that is already there. It takes a few seconds. It does not need administrator access and does not ' +
      'change anything else on the server. You can remove it again from here.',
    signIn: 'in-terminal',
    leaves: ['.local/lib/node_modules/@google/gemini-cli'],
    deviceUrl: null,
    verified:
      '`npm install -g --prefix "$HOME/.local" @google/gemini-cli` as an ordinary user: exit 0, 6 s, 100 MB, ' +
      'landed at `~/.local/bin/gemini`, version 0.56.0. It has no login command — its subcommands are mcp, ' +
      'extensions, skills, hooks and gemma. Asked to work without a signed-in account it answers *"Manual ' +
      'authorization is required but the current session is non-interactive"* and stops. Started properly on ' +
      'a pty it prints *"Please visit the following URL to authorize the application"* and then *"Enter the ' +
      'authorization code:"*, with the address pointing at a Google page rather than at the machine — so ' +
      'there is no listener on that server to forward anything to.',
  },
}

/** The agent a row is about, by id. */
export function agentSetup(id: AgentId): AgentSetup {
  return AGENTS[id]
}

/** The three, in the order they are drawn. */
export const SETUP_AGENTS: readonly AgentId[] = ['claude', 'codex', 'gemini']

/* ------------------------------------------------- what a person is told -- */

/**
 * The sentence shown before the Install button, written where the work is.
 *
 * §4.3 — *"the consequence sentence is written where the action is implemented.
 * Not in the renderer."* Every number in each of the three was measured rather
 * than guessed; see each row's `verified` note for what was run.
 */
export function installConsequence(id: AgentId, serverName: string): string {
  return AGENTS[id].consequence(serverName)
}

/** The button that puts it back, named the way a person would say it. */
export const REMOVE_LABEL = 'Remove what was installed'

/**
 * What the installer needs, checked before anybody is offered a button.
 *
 * Each of these turns a failure that would otherwise arrive part-way through a
 * download into a sentence said beforehand. A `null` room is not a refusal with
 * a reason — it is not knowing, which is the third state, and the caller draws
 * no button at all for it rather than a hopeful one.
 */
export function whyNotInstall(id: AgentId, room: AgentInstallRoom): string | null {
  return AGENTS[id].whyNot(room)
}

/** The line typed into the terminal, and it is the one the person would type. */
export function installCommand(id: AgentId, room: AgentInstallRoom): string | null {
  return AGENTS[id].install(room)
}

/* ------------------------------------------------------- reading the URL -- */

/**
 * The number baked into the address the sign-in will be redirected to.
 *
 * It cannot be read off the screen, and that was measured rather than assumed:
 * `claude` hands one address to `$BROWSER` and prints a **different** one on the
 * terminal — the printed one redirects to `platform.claude.com` and is the
 * copy-a-code path. The number is only ever in the first, which is why there is
 * a scratch script on the server whose whole job is to write it to a file.
 */
export function authPortOf(url: string): number | null {
  const match = /[?&]redirect_uri=([^&\s]+)/.exec(url)
  if (match === null) return null
  let target: URL
  try {
    target = new URL(decodeURIComponent(match[1]))
  } catch {
    return null
  }
  if (target.hostname !== 'localhost' && target.hostname !== '127.0.0.1') return null
  const port = Number(target.port)
  return Number.isInteger(port) && port > 0 && port < 65_536 ? port : null
}

/**
 * One agent's row on this server, or null when it is not there.
 *
 * Was `claudeOn` until 2026-08-20, when the pane stopped being about one agent.
 * The probe has always found all three — that came free with the widened path —
 * so this is a narrowing of what was already measured rather than a new
 * question asked of the server.
 */
export function agentOn(facts: Pick<ServerFacts, 'agents'>, id: AgentId): AgentFact | null {
  if (facts.agents.known !== 'yes') return null
  return facts.agents.value.find((agent) => agent.id === id) ?? null
}

/* --------------------------------------------------- the scripts it runs -- */

/**
 * Make a private scratch folder with a stand-in browser in it, and say where.
 *
 * `$BROWSER` is honoured by `claude` and no shim needs to be placed on the
 * server's PATH — that was tried and the shim never ran. But the child's output
 * is swallowed, so the address has to be written to a file rather than printed.
 *
 * `mktemp` rather than a fixed name, `0700` on both, and `umask 077` inside, so
 * that on a machine with three home folders on it — which the test box is — the
 * address a sign-in is in the middle of is not readable by the other two
 * accounts.
 */
const SCRATCH_SCRIPT = [
  'd=$(mktemp -d /tmp/td-signin-XXXXXX) || exit 1',
  'chmod 700 "$d" || exit 1',
  "echo '#!/bin/sh' > \"$d/open\"",
  "echo 'umask 077' >> \"$d/open\"",
  'echo \'echo "$1" > "$0.url"\' >> "$d/open"',
  "echo 'exit 0' >> \"$d/open\"",
  'chmod 700 "$d/open" || exit 1',
  'printf %s "$d"',
].join('\n')

/**
 * Wait for the address to appear, once, with a stated ceiling.
 *
 * A one-shot wait inside an action somebody pressed, not a background timer —
 * which is the line his *events, not polling* rule actually draws. Measured at
 * 400 ms on a real box; the twenty seconds is for a slow machine, and running
 * out of it is a real outcome with its own sentence rather than a hang.
 *
 * The deadline is computed from the clock rather than counted in iterations
 * because `sleep` takes fractions on GNU and whole seconds on busybox, and a
 * loop counted in iterations is a twenty-second wait on one and a hundred-second
 * one on the other.
 */
function waitScript(dir: string): string {
  return [
    `f="${dir}/open.url"`,
    'end=$(( $(date +%s) + 20 ))',
    'while [ "$(date +%s)" -lt "$end" ]; do',
    '  if [ -s "$f" ]; then cat "$f"; exit 0; fi',
    '  sleep 0.2 2>/dev/null || sleep 1',
    'done',
    'exit 1',
  ].join('\n')
}

/**
 * The way back, and it removes exactly what was added.
 *
 * Never `~/.claude`, `~/.codex` or `~/.gemini`. Those folders are the person's
 * own transcripts, settings and logins and they may well predate this app
 * entirely; removing one would be deleting somebody's work under the heading of
 * undoing our own. What each row *may* remove is declared on its own entry in
 * the table — the versions directory the native installer unpacks into, or the
 * one package an npm install wrote — and nothing else.
 *
 * The `$HOME` guard stays in front of all of it. Every path this can be handed
 * came from a `command -v` on the server, and a machine whose PATH turns up a
 * system copy is a machine where the honest answer is to refuse.
 */
function removeScript(path: string, leaves: readonly string[]): string {
  return [
    `p="${path}"`,
    'case "$p" in "$HOME"/*) ;; *) echo "not ours to remove" >&2; exit 1 ;; esac',
    'rm -f "$p"',
    ...leaves.map((leaf) => `rm -rf "$HOME/${leaf}"`),
    'exit 0',
  ].join('\n')
}

/* ---------------------------------------------------------- the sentinel -- */

/**
 * What is appended to the install line so that the app knows when it ended.
 *
 * Visible in the scrollback, like everything else typed into that terminal, and
 * that is the point: nothing about this run is hidden from the person watching
 * it. Reading the installer's own last line instead was the alternative and it
 * is guesswork — its wording is not a contract, and a wizard that decides an
 * install failed because a message was reworded is worse than one that reads an
 * exit status.
 */
const DONE = '__terminaldeck_setup'

/** The echoed command ends in `$?`; only the shell's answer ends in digits. */
const DONE_PATTERN = new RegExp(`${DONE} (\\d+)`)

/** Measured at 62 seconds. Ten minutes is a very slow link, and past that something is wrong. */
const INSTALL_CEILING_MS = 10 * 60 * 1000

/**
 * How long a one-time code is worth waiting on.
 *
 * Sixteen minutes because the code itself is stated to expire in fifteen — *"Enter
 * this one-time code (expires in 15 minutes)"*, measured on the real box. Waiting
 * past the moment the code stops working would be waiting for something that
 * cannot now happen.
 */
const DEVICE_CEILING_MS = 16 * 60 * 1000

/** Not an exit status any shell reports, so it cannot be mistaken for one. */
const NEVER_ANSWERED = -1

/** One row on one server. The key `states` is kept under. */
function rowKey(serverId: string, agentId: AgentId): string {
  return `${serverId}\t${agentId}`
}

/* ---------------------------------------------------------- the sessions -- */

interface Attempt {
  serverId: string
  agentId: AgentId
  /** Everything that has to be undone on this server, undone newest first. */
  undo: Array<() => void | Promise<void>>
  /**
   * Stop the login that is running in the terminal.
   *
   * Kept apart from the list above because there is exactly one path — the
   * by-hand one — where everything else must be cleaned up and this must **not**
   * run: the person has just been asked to finish the sign-in at the prompt that
   * login is sitting on, and stopping it would take the prompt away.
   */
  stopLogin: (() => void) | null
}

/**
 * One setup per server at a time, and every one of them cleans up after itself.
 *
 * The rule that shapes this class, and there is no polite version of it: **never
 * leave a half-open listener or a scratch folder on somebody else's machine.**
 * Every path out of a sign-in — success, refusal, running out of time, the
 * person closing the browser, the connection dropping — runs the same `finish`,
 * which stops the remote login, removes the scratch folder, and closes the
 * listener on this Mac.
 */
export class ServerSetups {
  /**
   * One attempt per server, keyed by server alone — not by row.
   *
   * There are three rows and only one terminal in the panel below them, so two
   * installs on one server cannot be running at once whatever the buttons
   * suggest. Keying this by server is what makes that true rather than hoped
   * for: starting a second one calls `cancel`, which tears the first one down
   * before anything is typed.
   */
  private readonly attempts = new Map<string, Attempt>()
  /** The last line each row was given, keyed by server *and* row. */
  private readonly states = new Map<string, SetupState>()

  constructor(private readonly deps: SetupDeps) {}

  /** What the window last heard about one row on one server. */
  stateOf(serverId: string, agentId: AgentId): SetupState {
    return this.states.get(rowKey(serverId, agentId)) ?? state(serverId, agentId, 'idle', '')
  }

  private say(next: SetupState): void {
    this.states.set(rowKey(next.serverId, next.agentId), next)
    this.deps.broadcast(next)
  }

  /**
   * Type the install into the terminal on screen, watch it end, and go straight
   * on to signing in.
   *
   * The straight-on is deliberate and it is the answer to *"very few simple
   * steps"*: an install that finishes and then sits there with a second button
   * is two wizards pretending to be one.
   */
  async install(
    serverId: string,
    agentId: AgentId,
    shell: SetupShell,
    room: AgentInstallRoom,
    serverName: string,
  ): Promise<SetupState> {
    const agent = AGENTS[agentId]
    const refusal = whyNotInstall(agentId, room)
    if (refusal !== null) {
      const failed = state(serverId, agentId, 'failed', refusal)
      this.say(failed)
      return failed
    }
    const command = installCommand(agentId, room)
    if (command === null) {
      // Belt and braces: `whyNot` already covers both reasons a command cannot
      // be composed, so reaching here means the two disagreed, and the honest
      // answer to that is to stop rather than to type something.
      const failed = state(serverId, agentId, 'failed', `This server cannot install ${agent.label}.`)
      this.say(failed)
      return failed
    }

    this.say(
      state(serverId, agentId, 'installing', `Installing ${agent.label} on ${serverName}.`),
    )

    const code = await this.typeAndWait(shell, `${command}; echo ${DONE} $?`)
    if (code !== 0) {
      const failed = state(serverId, agentId, 'failed', `${agent.label} could not be installed on this server.`, {
        detail: `The install ended with ${code}.`,
      })
      this.say(failed)
      return failed
    }

    const found = await this.lookForAgent(serverId, agentId)
    if (found === null) {
      const failed = state(serverId, agentId, 'failed', `The install finished but ${agent.label} will not start.`, {
        weInstalled: true,
      })
      this.say(failed)
      return failed
    }

    this.say(
      state(serverId, agentId, 'installed', `${agent.label} ${found.version} is installed. Signing in…`, {
        weInstalled: true,
        version: found.version,
      }),
    )
    return this.signIn(serverId, agentId, shell, found.path, true)
  }

  /**
   * Sign one agent in on the server, by whichever of the three routes that
   * agent actually offers.
   *
   * The branch is on measured behaviour, not on preference — see
   * {@link SignInShape}. None of the three is a fallback for another: a CLI that
   * opens no listener has nothing to forward, and pretending otherwise would
   * produce a browser hanging on an address that answers nothing.
   */
  async signIn(
    serverId: string,
    agentId: AgentId,
    shell: SetupShell,
    binary: string,
    weInstalled = false,
  ): Promise<SetupState> {
    const shape = AGENTS[agentId].signIn
    if (shape === 'device-code') return this.signInByDeviceCode(serverId, agentId, shell, binary, weInstalled)
    if (shape === 'in-terminal') return this.signInInTheTerminal(serverId, agentId, shell, binary, weInstalled)
    return this.signInThroughATunnel(serverId, agentId, shell, binary, weInstalled)
  }

  /**
   * The one-time-code route: open the page here, and the code is already on
   * their screen.
   *
   * Measured, and it is the CLI's own advice rather than this app's idea — plain
   * `codex login` prints *"On a remote or headless machine? Use `codex login
   * --device-auth` instead"* and this server is exactly that. The address is a
   * constant, so nothing has to be scraped off a terminal, and no listener is
   * opened, so nothing has to be forwarded. What it costs is one short code
   * typed by a person, out of a terminal that is already in front of them.
   *
   * Unlike the tunnel route this one can tell when it is finished: the login
   * command exits, so the sentinel that watches the install works here too, and
   * the row can go to `done` with the account on it instead of being left in a
   * hopeful "signing in…".
   */
  private async signInByDeviceCode(
    serverId: string,
    agentId: AgentId,
    shell: SetupShell,
    binary: string,
    weInstalled: boolean,
  ): Promise<SetupState> {
    await this.cancel(serverId)
    const agent = AGENTS[agentId]
    const attempt: Attempt = { serverId, agentId, undo: [], stopLogin: null }
    this.attempts.set(serverId, attempt)
    const base = (step: SetupStep, line: string, over: Partial<SetupState> = {}): SetupState =>
      state(serverId, agentId, step, line, { weInstalled, ...over })

    try {
      if (this.deps.openInBrowser !== undefined && agent.deviceUrl !== null) {
        await this.deps.openInBrowser(agent.deviceUrl)
        this.say(
          base(
            'signing-in',
            `${agent.label} is showing a one-time code in the terminal below. Enter it on the page ` +
              'that just opened in your browser.',
            { byHand: true },
          ),
        )
      } else {
        // No browser to open one with. The address is printed in the terminal
        // by the CLI itself, so the work is the same minus the convenience —
        // and saying so is better than opening nothing and looking stalled.
        this.say(
          base(
            'signing-in',
            `Open the address ${agent.label} prints below, and enter the code it shows there.`,
            { byHand: true },
          ),
        )
      }

      attempt.stopLogin = () => shell.write('\u0003')
      const code = await this.typeAndWait(shell, `${binary} login --device-auth; echo ${DONE} $?`, DEVICE_CEILING_MS)
      attempt.stopLogin = null
      await this.finish(serverId)

      const after = await this.lookForAgent(serverId, agentId)
      if (code === 0 && after !== null && after.signedIn !== 'no') {
        const done = base('done', accountLine(agentId, after), { version: after.version })
        this.say(done)
        return done
      }
      const failed = base('failed', 'The sign-in was not finished.')
      this.say(failed)
      return failed
    } catch (error) {
      await this.finish(serverId)
      const failed = base('failed', 'The sign-in stopped before it finished.', {
        detail: error instanceof Error ? error.message : '',
      })
      this.say(failed)
      return failed
    }
  }

  /**
   * The route for a CLI that has no login command at all.
   *
   * Measured: this one has no `login` subcommand — its subcommands are mcp,
   * extensions, skills, hooks and gemma — refuses to authorise anything from a
   * non-interactive session in as many words, and, when it is started properly,
   * prints its address inside its own full-screen interface and asks for the
   * code back at a prompt. The address it prints redirects to a page on the
   * vendor's own site rather than to a port on that server, so **there is no
   * listener here to forward**: this is not the tunnel route being declined, it
   * is a route that does not exist for this agent.
   *
   * So the app starts it and stops. No address is put beside the terminal, for
   * the reason the by-hand path gives: the working address is the one already on
   * screen, and a second one that reached nothing would be worse than none.
   */
  private async signInInTheTerminal(
    serverId: string,
    agentId: AgentId,
    shell: SetupShell,
    binary: string,
    weInstalled: boolean,
  ): Promise<SetupState> {
    await this.cancel(serverId)
    const agent = AGENTS[agentId]
    this.attempts.set(serverId, { serverId, agentId, undo: [], stopLogin: null })
    shell.write(`${binary}\n`)
    const next = state(
      serverId,
      agentId,
      'signing-in',
      `${agent.label} signs in inside its own screen. Choose the Google sign-in below, open the address ` +
        'it prints, and paste the code back at its prompt.',
      { weInstalled, byHand: true },
    )
    this.say(next)
    return next
  }


  /**
   * The fully seamless route: this Mac's browser, and a socket carrying the
   * redirect back down to the server's own waiting listener.
   *
   * Every failure below falls through to the same place: the address is put on
   * screen for the person to open themselves, and the terminal is already
   * sitting at its own paste prompt. That is one paste more than the seamless
   * path and it is the same number of presses — it is not a degraded product,
   * it is what a server that will not carry a socket can honestly offer.
   */
  private async signInThroughATunnel(
    serverId: string,
    agentId: AgentId,
    shell: SetupShell,
    binary: string,
    weInstalled: boolean,
  ): Promise<SetupState> {
    await this.cancel(serverId)
    const attempt: Attempt = { serverId, agentId, undo: [], stopLogin: null }
    this.attempts.set(serverId, attempt)

    const base = (step: SetupStep, line: string, over: Partial<SetupState> = {}): SetupState =>
      state(serverId, agentId, step, line, { weInstalled, ...over })

    this.say(base('signing-in', 'Opening the sign-in page in your browser.'))

    try {
      for (let tries = 0; tries < 3; tries += 1) {
        const scratch = await this.deps.runScript(serverId, SCRATCH_SCRIPT)
        const dir = scratch.stdout.trim()
        if (scratch.code !== 0 || !dir.startsWith('/tmp/td-signin-')) {
          const failed = base('failed', 'This server would not let the sign-in start.', {
            detail: scratch.stderr.trim(),
          })
          this.say(failed)
          return failed
        }
        attempt.undo.push(() => {
          void this.deps.runScript(serverId, `rm -rf "${dir}"`).catch(() => undefined)
        })

        // The login itself, in the terminal the person is watching. Ctrl-C in
        // that same terminal is what stops it, which is why the undo below is
        // the honest kill rather than hunting for something to signal.
        shell.write(`BROWSER=${dir}/open ${binary} auth login --claudeai\n`)
        attempt.stopLogin = () => shell.write('\u0003')

        const captured = await this.deps.runScript(serverId, waitScript(dir))
        const url = captured.stdout.trim()
        const port = captured.code === 0 ? authPortOf(url) : null
        if (port === null) {
          return this.byHand(serverId, agentId, attempt, weInstalled)
        }

        const opened = await this.openTunnel(serverId, port, attempt)
        if (opened === 'taken') {
          /*
           * The number is in the `redirect_uri` that has already been sent to
           * Anthropic, so it cannot be changed from this end. Stopping the
           * login and starting it again gets a new random one, which is why
           * this loop exists — and why it is bounded rather than hopeful.
           */
          await this.undoAll(attempt)
          continue
        }
        if (opened === 'refused') {
          return this.byHand(serverId, agentId, attempt, weInstalled)
        }

        if (this.deps.openInBrowser === undefined) {
          return this.byHand(serverId, agentId, attempt, weInstalled)
        }
        await this.deps.openInBrowser(url)

        const carried = await opened.carried
        if (!carried) {
          const failed = base('failed', 'The sign-in was not finished.')
          await this.finish(serverId)
          this.say(failed)
          return failed
        }

        const after = await this.lookForAgent(serverId, agentId)
        await this.finish(serverId)
        if (after !== null && after.signedIn === 'yes') {
          const done = base('done', accountLine(agentId, after), { version: after.version })
          this.say(done)
          return done
        }
        const failed = base('failed', 'The sign-in was not finished.')
        this.say(failed)
        return failed
      }

      // Three attempts, three collisions on this Mac. Rare enough to be worth
      // saying plainly rather than retrying forever.
      return this.byHand(serverId, agentId, attempt, weInstalled)
    } catch (error) {
      await this.finish(serverId)
      const failed = base('failed', 'The sign-in stopped before it finished.', {
        detail: error instanceof Error ? error.message : '',
      })
      this.say(failed)
      return failed
    }
  }

  /** Stop whatever is in flight for this server and leave nothing behind. */
  async cancel(serverId: string): Promise<void> {
    await this.finish(serverId)
  }

  /** Every server at once. For shutdown, and for the connection going away. */
  async cancelAll(): Promise<void> {
    for (const serverId of [...this.attempts.keys()]) await this.cancel(serverId)
  }

  /**
   * Take back exactly what this app put there.
   *
   * Offered only when this app did the installing, because the alternative —
   * offering to remove an install somebody else made, possibly years ago,
   * possibly the one their work depends on — is not a way back at all.
   */
  async remove(serverId: string, agentId: AgentId, binary: string): Promise<SetupState> {
    await this.cancel(serverId)
    const agent = AGENTS[agentId]
    const result = await this.deps.runScript(serverId, removeScript(binary, agent.leaves))
    if (result.code !== 0) {
      const failed = state(serverId, agentId, 'failed', 'That could not be removed from this server.', {
        detail: result.stderr.trim(),
      })
      this.say(failed)
      return failed
    }
    const idle = state(serverId, agentId, 'idle', `${agent.label} was removed from this server.`)
    this.say(idle)
    return idle
  }

  /* ------------------------------------------------------------ privates -- */

  /**
   * Type a line and answer the exit status the far end reported for it.
   *
   * The ceiling is a stated outcome, not a safety net. Measured at 62 seconds on
   * a real box; ten minutes is a very slow link finishing, and past that
   * something is wrong in a way this app has no way to see. A wait with no
   * ceiling would leave the line under the terminal reading *Installing…*
   * forever, which is the one thing worse than saying it did not work.
   */
  private typeAndWait(shell: SetupShell, line: string, ceilingMs = INSTALL_CEILING_MS): Promise<number> {
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
   * Ask the server what Claude Code it now has, by absolute path.
   *
   * The same union the probe uses, and for the same measured reason: the
   * installer puts it in `~/.local/bin`, prints advice about the PATH, and edits
   * no file — so a fresh command over this connection still cannot see it by
   * name.
   */
  private async lookForAgent(serverId: string, agentId: AgentId): Promise<AgentFact | null> {
    const result = await this.deps.runScript(serverId, findScript(agentId))
    if (result.code !== 0) return null
    const [path, version, signedIn, account] = result.stdout.trim().split('\t')
    if (path === undefined || path === '' || version === undefined || version === '') return null
    return {
      id: agentId,
      path,
      version,
      signedIn: signedIn === 'yes' ? 'yes' : signedIn === 'no' ? 'no' : 'unknown',
      account: account === undefined || account === '' ? null : account,
    }
  }

  /**
   * Open the listener on this Mac, and hold the connection open while it lives.
   *
   * The promise answers whether anything ever came down it. `client.on('close')`
   * is what ends a sign-in whose connection dropped — the listener would
   * otherwise sit here accepting connections that can reach nothing, which is a
   * browser hanging on an address that answers and then never replies.
   */
  private async openTunnel(
    serverId: string,
    port: number,
    attempt: Attempt,
  ): Promise<'taken' | 'refused' | { carried: Promise<boolean> }> {
    let settleOpen: (value: 'taken' | 'refused' | { carried: Promise<boolean> }) => void
    const opened = new Promise<'taken' | 'refused' | { carried: Promise<boolean> }>((resolve) => {
      settleOpen = resolve
    })

    let letGo: (() => void) | null = null
    let closed = false
    const release = (): void => {
      if (closed) return
      closed = true
      letGo?.()
    }
    attempt.undo.push(release)

    void this.deps
      .withConnection(serverId, async (client) => {
        const result = await openSetupTunnel(port, forwardOn(client))
        if (!result.ok) {
          settleOpen(result.why)
          return
        }
        const tunnel: SetupTunnel = result.tunnel
        let settleCarried: (value: boolean) => void
        const carried = new Promise<boolean>((resolve) => {
          settleCarried = resolve
        })
        tunnel.onCarried(() => settleCarried(true))
        client.on('close', () => {
          settleCarried(false)
          release()
        })
        settleOpen({ carried })
        await new Promise<void>((resolve) => {
          letGo = () => {
            tunnel.close()
            settleCarried(false)
            resolve()
          }
          if (closed) letGo()
        })
      })
      .catch(() => settleOpen('refused'))

    return opened
  }

  /** The path a server that will not carry a socket honestly offers. */
  private async byHand(
    serverId: string,
    agentId: AgentId,
    attempt: Attempt,
    weInstalled: boolean,
  ): Promise<SetupState> {
    /*
     * The login stays running, and this is the one place it does. The terminal
     * is already sitting at its own `Paste code here if prompted >` prompt, and
     * that prompt is what the person has just been asked to use — stopping the
     * login to tidy up would take it away from them. Everything else still goes:
     * the listener on this Mac, and the scratch folder on their server.
     */
    attempt.stopLogin = null
    await this.finish(serverId)
    const next = state(
      serverId,
      agentId,
      'signing-in',
      'Finish signing in in the terminal below — it prints an address to open and waits for the code.',
      { weInstalled, byHand: true },
    )
    this.say(next)
    return next
  }

  private async finish(serverId: string): Promise<void> {
    const attempt = this.attempts.get(serverId)
    if (attempt === undefined) return
    this.attempts.delete(serverId)
    await this.undoAll(attempt)
  }

  private async undoAll(attempt: Attempt): Promise<void> {
    const steps = [...attempt.undo].reverse()
    const stop = attempt.stopLogin
    attempt.undo = []
    attempt.stopLogin = null
    // The login first. It is the thing holding a listener open on somebody
    // else's machine, and it is the one that matters most if a later step
    // throws.
    if (stop !== null) steps.unshift(stop)
    for (const step of steps) {
      try {
        await step()
      } catch {
        /*
         * Deliberately swallowed, one step at a time. A scratch folder that
         * could not be removed because the connection has already gone must not
         * stop the listener on this Mac from being closed — the whole value of
         * this loop is that every step runs whatever the one before it did.
         */
      }
    }
    attempt.undo = []
  }
}

/**
 * The line shown when a row is set up and signed in.
 *
 * It names the agent, and under part 1 of the naming rule that is correct
 * rather than merely tolerated: three rows are on screen, and a line reading
 * *"signed in"* with no name on it would be the one fact this row exists to
 * carry, deleted.
 */
export function accountLine(id: AgentId, agent: AgentFact): string {
  const label = `${AGENTS[id].label} ${agent.version}`
  return agent.account === null ? `${label}, signed in.` : `${label}, signed in as ${agent.account}.`
}

/**
 * Find one agent the same way the probe does, on its own.
 *
 * A near-copy of the `#agents` section, and the duplication is deliberate: this
 * one runs *after* an install, on a connection whose PATH is exactly the one
 * that could not see it, and inlining it here keeps the setup flow from
 * depending on a whole 293 ms probe to answer one question.
 *
 * ## Why the search is this wide for an npm install too
 *
 * Because both of the npm rows land in `~/.local/bin`, which was the blind spot
 * that started all of this: measured on the real box, a non-interactive `sh -s`
 * gets a PATH with no `~/.local/bin` on it, so a bare `command -v` answers "not
 * found" about a binary that is sitting right there. The same widening covers
 * all three, which is the point of there being one script.
 *
 * ## Asking whether it is signed in, per agent, and only where it is cheap
 *
 * Two of the three can be asked and the third cannot, and that was measured
 * rather than assumed:
 *
 *  - Claude Code answers `auth status --json` in 245 ms with a `loggedIn` flag
 *    and the address on the account.
 *  - Codex answers `login status` with *"Logged in using ChatGPT"*, or *"Not
 *    logged in"* against a configuration directory that has never been used. It
 *    prints no address, so the account stays empty rather than being guessed at.
 *  - Gemini has no equivalent at all — it has no login command — so its answer
 *    is `unknown`, which is the third state and draws a Sign in button rather
 *    than a claim in either direction.
 */
function findScript(id: AgentId): string {
  const binary = { claude: 'claude', codex: 'codex', gemini: 'gemini' }[id]
  const signedInCheck =
    id === 'claude'
      ? String.raw`s=$("$b" auth status --json 2>/dev/null | tr -d ' \t\n\r')
case "$s" in
  *'"loggedIn":true'*)  i=yes ;;
  *'"loggedIn":false'*) i=no ;;
esac
e=$(printf '%s' "$s" | sed -n 's/.*"email":"\([^"]*\)".*/\1/p')`
      : id === 'codex'
        ? String.raw`s=$("$b" login status 2>/dev/null)
case "$s" in
  *"Logged in"*)     i=yes ;;
  *"Not logged in"*) i=no ;;
esac`
        : '# This one has no way to be asked, so the answer stays unknown.'

  return String.raw`W="$PATH"
for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.claude/local" "$HOME/.npm-global/bin"          "$HOME/.volta/bin" "$HOME/.bun/bin" "$HOME/.asdf/shims"          "$HOME/.local/share/mise/shims" /usr/local/bin /opt/homebrew/bin /snap/bin; do
  [ -d "$d" ] && W="$W:$d"
done
ND="$NVM_DIR"
[ -n "$ND" ] || ND="$HOME/.nvm"
for d in "$ND"/versions/node/*/bin; do [ -d "$d" ] && W="$W:$d"; done
LS="$SHELL"
[ -n "$LS" ] || LS=/bin/sh
b=$(PATH="$W" command -v ` + binary + String.raw` 2>/dev/null)
[ -n "$b" ] || b=$("$LS" -lc 'command -v ` + binary + String.raw`' 2>/dev/null | grep '/` + binary + String.raw`$' | head -n 1)
[ -n "$b" ] || exit 1
v=$("$b" --version 2>/dev/null | head -n 1 | awk '{print $NF}')
i=unknown
e=
` + signedInCheck + String.raw`
printf '%s	%s	%s	%s
' "$b" "$v" "$i" "$e"
`
}
