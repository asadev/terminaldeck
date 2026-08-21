/**
 * What a person can do to a server from this app, and the rails that make each
 * one safe to press.
 *
 * `SERVERS-DESIGN.md` §4 is the contract and this file is its implementation.
 * The rule it exists to keep is Asad's, in his words: **every action is a
 * sentence with a consequence, and nothing destructive happens without a way
 * back.** *"Restart your website — it'll be offline about five seconds."*
 *
 * ## The three classes, and why there is no fourth
 *
 * | Class | Meaning | Confirmation |
 * |---|---|---|
 * | `safe` | Changes nothing. Reading, opening, listing. | none |
 * | `reversible` | One press puts it back exactly as it was, and the button that does it is named in the sentence. | one sentence, one button |
 * | `kept` | We record what it takes to go back *before* we change anything, and refuse to proceed if we could not. | one sentence, one button, plus what was recorded |
 *
 * Anything genuinely irreversible is **absent**, not guarded. That is the whole
 * mechanism: the second half of his rule is kept by construction rather than by
 * dialogs. The alternative — shipping a destructive action behind a scarier
 * dialog — is the thing that fails in practice, and this repository already
 * wrote down why in `deck-control/catalogue.ts`: a refusal that arrives after a
 * run of harmless confirmations *"has already trained them to click yes."*
 * Deleting a site, removing a database and anything that runs `rm` are
 * therefore not in this list. {@link ACTION_CLASSES} is closed and
 * `no-action-without-a-way-back.test.ts` fails if anything grows a fourth.
 *
 * ## The sentence is written here, and only here
 *
 * §4.3, and it is the same constraint the copilot's consent path already lives
 * under. `remote/copilot-consent.ts` gives the reason: a client that wrote its
 * own sentence *"would be describing an action it did not implement, and the
 * first time the two drifted somebody would approve one thing having read
 * another."* So {@link ServerAction.summary} is rendered by three surfaces —
 * the confirmation dialog, the action log, and the copilot's consent question —
 * and composed by none of them. `summary-is-server-side.test.ts` scans the
 * renderer for any of these sentences and fails if one has been copied there.
 *
 * ## Timings are honest or absent
 *
 * §4.4. *"About five seconds"* is a claim. Where it is a reasonable claim for a
 * restart, it is made. Where it is not — a container pulling a new image over a
 * link whose speed we have never measured — the sentence says *"this can take a
 * minute or two"* rather than inventing a number, because a consequence
 * sentence that is confidently wrong is worse than a vague one: the person
 * planned around it.
 *
 * ## Nothing here guesses which command to run
 *
 * §4.2: *"Restart is one command, chosen from the detected `init` fact, and
 * there is no fallback chain."* If the facts cannot say how this server starts
 * and stops things, the card carries no Start, Stop or Restart and says why.
 * Trying `systemctl`, then `service`, then `rc-service` until one exits zero is
 * running commands on a machine we do not understand, which is precisely what
 * rule 4 forbids.
 */

import type { RunResult, ServerShell, TerminalSize } from './connection'
import { valueOf, type ServerFacts } from './facts'
import {
  isSafeName,
  isSafePath,
  type ComposeRef,
  type DatabaseEngine,
  type KnownEngine,
  type ManagedBy,
  type ServerCard,
} from './classify'

/* ------------------------------------------------------------- the transport -- */

/**
 * What one command on the far end produced. The A→B seam of §8.2.
 *
 * `connection.ts`'s own type, aliased rather than restated. Its `code` is
 * `number | null` — null meaning the far end was killed by a signal rather than
 * exiting — and that third value is the reason this is not re-declared here:
 * a local copy typed `code: number` would compile happily and treat every
 * signalled command as a success.
 */
export type CommandResult = RunResult

/**
 * Run one command on a server. `connection.ts` provides it; nothing in this
 * file constructs an `ssh2` client, per §8.2.
 *
 * The argument is an argv rather than a command line, and that is not a
 * stylistic preference. A command line built here would have to be quoted here,
 * and quoting is a thing you can get subtly wrong against a name that came off
 * a stranger's server. Every name that reaches this function has additionally
 * been through {@link isSafeName} or {@link isSafePath} first — belt and braces,
 * because the consequence of getting it wrong is arbitrary code on somebody's
 * production machine.
 */
export type RunOnServer = (serverId: string, argv: readonly string[]) => Promise<CommandResult>

/**
 * Copy a file off the server onto this computer.
 *
 * Optional on {@link ActionDeps}, and its absence is a real answer rather than
 * a gap: **Backup is the one action in v1 that moves a file** (§7 — "it only
 * reads and goes one way"), and without a way to move it there is no Backup
 * button. A button that produced a zero-byte file would be the exact failure
 * §4.2 describes, where something that looks like a backup is not one.
 *
 * `ssh2` provides `sftp` for this. Whether `connection.ts` exposes it is A's
 * decision; this is the shape the action layer needs if it does.
 */
export type DownloadFromServer = (
  serverId: string,
  remotePath: string,
  localPath: string,
) => Promise<{ bytes: number }>

/**
 * An interactive shell on the server, as the third zone drives it.
 *
 * §4.6: the terminal is the honest floor, the answer to *"we can see everything
 * exists in the server"* for every case the cards do not cover, and what makes
 * the empty state of §3.5 acceptable rather than a dead end.
 *
 * > **`shell()` takes `{ cols, rows }`; `setWindow()` takes `(rows, cols,
 * > height, width)`.** The order is reversed between the two, in the same
 * > library, on the same channel — `ssh2/lib/Channel.js`. Getting it wrong
 * > produces a terminal that works until the window is resized and then wraps
 * > every line at the wrong column, which reads as a rendering bug rather than
 * > as a swapped pair of arguments.
 *
 * `connection.ts` owns that flip and keeps it in one place, which is why its
 * `resize` takes a **named** {@link TerminalSize} rather than two numbers.
 * Nothing in this layer or above it ever passes a bare pair.
 */
export type { ServerShell, TerminalSize }

/**
 * `startIn` is the folder the terminal should open in, or nothing at all for
 * wherever the account's own sign-in lands — which is what every terminal this
 * app opened before the folder picker existed did, and still the default.
 * `connection.ts` decides how a shell is made to start somewhere, and says
 * there why it types the `cd` rather than execing a login shell.
 */
export type OpenServerShell = (
  serverId: string,
  size: TerminalSize,
  startIn?: string,
) => Promise<ServerShell>

/**
 * List one folder on a server, so somebody can choose where a session starts.
 *
 * The counterpart of {@link DownloadFromServer}'s note above: `ssh2` provides
 * `sftp`, whether `connection.ts` exposes it was left open, and this is the
 * first thing that needed it. It **is** exposed now, and the argument for
 * asking the subsystem rather than running `ls` lives beside the
 * implementation — the short version being that `ls` answers with a picture of
 * a listing, and a folder called `my project` comes back as two rows.
 *
 * `''` means the account's login directory. The answer carries the absolute
 * path the *server* resolved, never one assembled here, because assembling
 * `/home/<username>` is wrong for `root`, wrong on macOS, and wrong on any
 * account whose home has been moved.
 */
export type ListServerFolder = (
  serverId: string,
  path: string,
) => Promise<{ path: string; entries: readonly { name: string; kind: 'folder' | 'link' | 'file' }[] }>

/**
 * Put a file from this computer onto a server, and answer the path it got there.
 *
 * The counterpart of {@link ListServerFolder}, over the same SFTP subsystem on
 * the same already-open connection, and it exists for the rule
 * `renderer/session-transfer.ts` states: whatever a session is handed must exist
 * on the machine that session runs on, named by that machine's path. A terminal
 * on a server is a session, and until this existed the only path the app could
 * hand one was a path on this laptop.
 *
 * `name` is a suggestion, not a path. The server decides what the file is
 * actually called — the same bargain the phone's upload makes with this desktop
 * — so a second capture lands beside the first rather than on top of it, and
 * nothing here can be talked into writing outside the one folder it makes.
 */
export type PutFileOnServer = (
  serverId: string,
  localPath: string,
  name: string,
) => Promise<string>

/* ------------------------------------------------------------------- facts -- */

/**
 * The slice of A's `ServerFacts` the action layer reads.
 *
 * Three measurements decide every button on every card: how the server starts
 * and stops things, whether it has a container runtime this sign-in can reach,
 * and what this sign-in is allowed to do. Naming them as an interface rather
 * than importing the whole record keeps the coupling to three fields and makes
 * the dependency legible.
 */
export type ActionFacts = Pick<ServerFacts, 'privilege' | 'init' | 'containerRuntime'>

/**
 * Put `sudo` in front, or do not, from the measured privilege.
 *
 * The measurement that decides this has a trap in it, recorded in §3.4 and
 * worth restating where the decision is made: **`sudo-password` and "not
 * permitted to use `sudo` at all" are indistinguishable without trying.** An
 * ordinary account with the binary present and no entry in the sudoers file
 * answers `sudo-password`, identically to an account that merely needs to type
 * one. There is no offline check that separates them.
 *
 * So this never *promises* anything. `sudo -n` is non-interactive by design: it
 * fails immediately rather than hanging on a password prompt that nobody can
 * see, the failure is caught, and the sentence the person reads is *"this
 * sign-in isn't allowed to do that on this server"* — which is true in both
 * cases.
 */
export function elevate(facts: ActionFacts, argv: readonly string[]): string[] {
  if (valueOf(facts.privilege) === 'yes') return [...argv]
  return ['sudo', '-n', ...argv]
}

/**
 * Can this sign-in plausibly administer services at all?
 *
 * `no` means the probe found no way to become an administrator — not "we would
 * have to ask for a password", which §3.4 says we may try and catch. This is
 * the one case where offering the button would be certain to fail, so the
 * button is absent and the card says so.
 */
export function canAdminister(facts: ActionFacts): boolean {
  const privilege = valueOf(facts.privilege)
  return privilege === 'yes' || privilege === 'sudo-nopasswd' || privilege === 'sudo-password'
}

/* --------------------------------------------------------------- failures -- */

/**
 * An action that did not happen, with the sentence a person reads.
 *
 * Two fields, and the split matters. `sentence` is the person's answer, in the
 * vocabulary of §1.4 — no `sudo`, no exit codes, no unit names. `detail` is
 * what the server actually said, kept verbatim behind the disclosure, because
 * an agent debugging a wrong card on a stranger's box has nothing else to go on
 * and a person who wants to know is entitled to it.
 */
export class ActionFailed extends Error {
  constructor(
    readonly sentence: string,
    readonly detail: string,
  ) {
    super(sentence)
    this.name = 'ActionFailed'
  }
}

/**
 * An action this app will not start, because a rule says so.
 *
 * Distinct from {@link ActionFailed} in the same way `Refused` is distinct from
 * an error in `deck-control/surface.ts`: one is a rule, the other is a fault,
 * and collapsing them means the action log cannot tell "we would not" from "it
 * broke". Every use of this is a way-back that could not be recorded.
 */
export class ActionRefused extends Error {
  constructor(readonly sentence: string) {
    super(sentence)
    this.name = 'ActionRefused'
  }
}

/**
 * Stderr that means "you are not allowed", across the tools this file drives.
 *
 * §4.5's last row maps a non-zero exit to *"this sign-in isn't allowed to do
 * that on this server"* — and that row is titled *"action refused by the
 * server"*, so it is about refusal specifically. A non-zero exit has many other
 * causes, and answering "you are not allowed" to a unit that does not exist
 * would send somebody to fix a permission that was never the problem. So the
 * permission sentence is used when the server's own words say permission, and
 * everything else gets a sentence that admits we are relaying what it said.
 *
 * Each pattern here is a real message from a real tool: `sudo -n` when a
 * password is required, `systemctl` under polkit, the Docker socket, and
 * `mysqldump`.
 */
const PERMISSION_PATTERNS: readonly RegExp[] = [
  /\bpermission denied\b/i,
  /\bmust be root\b/i,
  /\boperation not permitted\b/i,
  /a (?:password|terminal) is required/i,
  /sudo: .*(?:no tty|askpass|not allowed|not in the sudoers)/i,
  /interactive authentication required/i,
  /\baccess denied\b/i,
  /\bnot authori[sz]ed\b/i,
  /got permission denied while trying to connect to the docker daemon/i,
]

const MISSING_PATTERNS: readonly RegExp[] = [
  /\bcould not be found\b/i,
  /\bnot found\b/i,
  /\bno such (?:file|directory|container|object|service|unit)\b/i,
  /\bunit .* not loaded\b/i,
]

/**
 * Turn a non-zero exit into the sentence a person reads.
 *
 * `what` is the person's own name for the thing, never an internal id, so the
 * sentence reads *"The server couldn't find your website"* rather than naming a
 * unit file.
 */
export function failureSentence(result: CommandResult, what: string): ActionFailed {
  const said = `${result.stderr}\n${result.stdout}`.trim()
  const ending =
    result.code === null
      ? `The command was stopped by ${result.signal ?? 'a signal'}.`
      : `The command ended with code ${result.code}.`
  const detail = said === '' ? ending : said.split('\n').slice(0, 20).join('\n')
  if (PERMISSION_PATTERNS.some((pattern) => pattern.test(said))) {
    return new ActionFailed('This sign-in isn’t allowed to do that on this server.', detail)
  }
  if (MISSING_PATTERNS.some((pattern) => pattern.test(said))) {
    return new ActionFailed(`The server couldn’t find ${what} any more.`, detail)
  }
  return new ActionFailed(`The server refused to do that to ${what}.`, detail)
}

/**
 * Throw {@link failureSentence} unless the command succeeded.
 *
 * `code === null` means the far end was killed by a signal, and it is treated
 * as a failure rather than passed over. A `docker compose up` that the kernel
 * stopped part-way has not updated anything, and a caller that read only
 * `code !== 0` would report success for it.
 */
function ok(result: CommandResult, what: string): CommandResult {
  if (result.code !== 0 || result.code === null) throw failureSentence(result, what)
  return result
}

/** Did it succeed? The same rule as {@link ok}, without the throw. */
function succeeded(result: CommandResult): boolean {
  return result.code === 0
}

/* ------------------------------------------------------------- the way back -- */

/**
 * What was recorded before a `kept` action changed anything.
 *
 * A discriminated union rather than a bag of optional fields, because the two
 * ways back are genuinely different operations and a rollback that read the
 * wrong half of a shared record would be a rollback that did nothing while
 * reporting success.
 */
export type WayBack =
  | {
      kind: 'container-image'
      at: number
      /** The container as the runtime names it. */
      container: string
      /** The image *id* — a content digest, not a tag, because tags move. */
      imageId: string
      /** The tag the compose project asks for, which is what we re-point. */
      imageRef: string
      compose: ComposeRef
      /** Where the automatic backup went, when the card was a database. */
      backupPath: string | null
    }
  | {
      kind: 'repo-commit'
      at: number
      dir: string
      /** The exact commit that was checked out. */
      commit: string
      /** What to restart afterwards, when the card said. */
      managedBy: ManagedBy | null
      backupPath: string | null
    }

/**
 * Where the way back is kept — on **this** computer, never on the server.
 *
 * The point of a way back is that it survives the thing it is a way back from.
 * A record stored on the server would be a record that is gone in exactly the
 * situation it exists for.
 *
 * The interface is a port so that `perform` can be exercised without a
 * filesystem, and — more importantly — so that the *ordering* around it can be:
 * record, read back, then change. A test can make {@link put} fail and assert
 * that nothing was run.
 */
export interface WayBackJournal {
  put(serverId: string, cardId: string, record: WayBack): Promise<void>
  get(serverId: string, cardId: string): Promise<WayBack | null>
  clear(serverId: string, cardId: string): Promise<void>
}

/** A journal in memory. Real behaviour, no disk — for tests and for the headless host. */
export class MemoryJournal implements WayBackJournal {
  private readonly rows = new Map<string, WayBack>()

  private key(serverId: string, cardId: string): string {
    return `${serverId} ${cardId}`
  }

  async put(serverId: string, cardId: string, record: WayBack): Promise<void> {
    this.rows.set(this.key(serverId, cardId), record)
  }

  async get(serverId: string, cardId: string): Promise<WayBack | null> {
    return this.rows.get(this.key(serverId, cardId)) ?? null
  }

  async clear(serverId: string, cardId: string): Promise<void> {
    this.rows.delete(this.key(serverId, cardId))
  }
}

/* ---------------------------------------------------------------- the actions -- */

export const ACTION_CLASSES = ['safe', 'reversible', 'kept'] as const
export type ActionClass = (typeof ACTION_CLASSES)[number]

export const ACTION_IDS = [
  'open',
  'copy-address',
  'logs',
  'start',
  'restart',
  'stop',
  'update',
  'go-back',
  'backup',
] as const
export type ActionId = (typeof ACTION_IDS)[number]

/** What one action is about to be done to. */
export interface ActionTarget {
  serverId: string
  card: ServerCard
  facts: ActionFacts
}

export interface ActionDeps {
  run: RunOnServer
  journal: WayBackJournal
  /** Absent means no Backup button anywhere. See {@link DownloadFromServer}. */
  download?: DownloadFromServer
  /** Where a backup lands on this computer. Required when `download` is present. */
  backupDir?: string
  now?: () => number
  /** How many lines of log to fetch. Bounded by the caller, defaulted here. */
  logLines?: number
}

/** What happened, in the person's words, plus what the next press should offer. */
export interface ActionOutcome {
  /** One sentence past-tense: *"Restarted your website."* */
  done: string
  /** Structured facts for the action log. Never a payload. */
  detail: Record<string, unknown>
  /** The button that undoes this, when there is one. */
  wayBack: { actionId: ActionId; label: string } | null
  /** For Logs: the lines, newest last. For Backup: where the file went. */
  value?: unknown
}

/**
 * One thing a person can do, with everything three surfaces need to draw it.
 *
 * `summary` and `run` are the whole of the contract. `keep` exists only on the
 * `kept` class and {@link perform} enforces that: a `kept` action with no `keep`
 * is a lie about having a way back, and the test suite treats it as one.
 */
export interface ServerAction {
  id: ActionId
  klass: ActionClass
  /** Does the work happen on the server, or here on this computer? */
  where: 'server' | 'here'
  /** The button's own words. Short, imperative, no jargon. */
  label: string
  /** The consequence sentence. §4.3 — written here, rendered everywhere. */
  summary(target: ActionTarget): string
  /** Record the way back. Only on `kept`. Throws {@link ActionRefused} if it cannot. */
  keep?(deps: ActionDeps, target: ActionTarget): Promise<WayBack>
  run(deps: ActionDeps, target: ActionTarget, kept: WayBack | null): Promise<ActionOutcome>
}

/* ------------------------------------------------------------------ commands -- */

/**
 * The one command that starts, stops or restarts this thing.
 *
 * Chosen from {@link ManagedBy}, which was itself decided by the measured
 * `init` fact — never by trying things until one works. Returns null when the
 * thing is managed by something we did not detect, and a null here is what
 * removes the button rather than producing a guess.
 */
export function serviceCommand(managedBy: ManagedBy, verb: 'start' | 'stop' | 'restart', facts: ActionFacts): string[] | null {
  if (managedBy.kind === 'systemd') {
    if (!isSafeName(managedBy.unit)) return null
    return elevate(facts, ['systemctl', verb, managedBy.unit])
  }
  if (managedBy.kind === 'openrc') {
    if (!isSafeName(managedBy.service)) return null
    return elevate(facts, ['rc-service', managedBy.service, verb])
  }
  if (!isSafeName(managedBy.name)) return null
  // A container runtime this sign-in can already reach needs no elevation — the
  // facts probe proved that by running `docker info` successfully as this user.
  return [managedBy.runtime, verb, managedBy.name]
}

/** The one command that reads this thing's recent output. Null when there is none to read. */
export function logCommand(managedBy: ManagedBy, lines: number, facts: ActionFacts): string[] | null {
  const n = String(Math.min(Math.max(Math.trunc(lines), 1), MAX_LOG_LINES))
  if (managedBy.kind === 'systemd') {
    if (!isSafeName(managedBy.unit)) return null
    return elevate(facts, ['journalctl', '-u', managedBy.unit, '-n', n, '--no-pager', '-o', 'short-iso'])
  }
  if (managedBy.kind === 'container') {
    if (!isSafeName(managedBy.name)) return null
    return [managedBy.runtime, 'logs', '--tail', n, '--timestamps', managedBy.name]
  }
  /*
   * OpenRC has no journal, and there is no file whose location we could know
   * without assuming one. §4.2's rule about Backup applies identically: a Logs
   * button that shows the wrong file is worse than no Logs button.
   */
  return null
}

/** Longest window of log this app will fetch in one press. §4.2 — bounded, never followed. */
export const DEFAULT_LOG_LINES = 200
export const MAX_LOG_LINES = 2000

/* ------------------------------------------------------------ the catalogue -- */

function nameOf(target: ActionTarget): string {
  return target.card.name
}

/** `docker compose` in the project's own directory, for the recorded service. */
function composeArgv(runtime: 'docker' | 'podman', compose: ComposeRef, rest: readonly string[]): string[] {
  const argv = [runtime, 'compose']
  if (compose.workingDir !== '') argv.push('--project-directory', compose.workingDir)
  argv.push('-p', compose.project, ...rest)
  return argv
}

const openAction: ServerAction = {
  id: 'open',
  klass: 'safe',
  where: 'here',
  label: 'Open',
  // No consequence sentence: §4.2 leaves this row's sentence as "—" because
  // opening a web page in a browser changes nothing anywhere. A confirmation
  // here would be one of the harmless yeses that trains somebody to click yes.
  summary: (target) => `Open ${nameOf(target)} in a browser`,
  run: async (_deps, target) => {
    const url = target.card.url
    if (url === null || !/^https?:\/\//i.test(url)) {
      throw new ActionRefused('There isn’t an address we can open for this.')
    }
    return { done: `Opened ${nameOf(target)}.`, detail: { url }, wayBack: null, value: { url } }
  },
}

const copyAddressAction: ServerAction = {
  id: 'copy-address',
  klass: 'safe',
  where: 'here',
  label: 'Copy address',
  summary: (target) => `Copy the address of ${nameOf(target)}`,
  run: async (_deps, target) => {
    const url = target.card.url
    if (url === null) throw new ActionRefused('There isn’t an address to copy for this.')
    return { done: 'Copied.', detail: { url }, wayBack: null, value: { url } }
  },
}

const logsAction: ServerAction = {
  id: 'logs',
  klass: 'safe',
  where: 'server',
  label: 'Logs',
  summary: (target) => `Show what ${nameOf(target)} has been saying`,
  run: async (deps, target) => {
    const managedBy = target.card.managedBy
    if (managedBy === null) throw new ActionRefused('There’s nothing here we can read a log from.')
    const argv = logCommand(managedBy, deps.logLines ?? DEFAULT_LOG_LINES, target.facts)
    if (argv === null) throw new ActionRefused('This server doesn’t keep a log we can read for this.')
    const result = await deps.run(target.serverId, argv)
    /*
     * A log tool that exits non-zero and still prints is ordinary — `docker
     * logs` on a stopped container is the common case — so output wins over the
     * exit code, and an empty result with a non-zero code is the only failure.
     */
    if (!succeeded(result) && result.stdout.trim() === '') throw failureSentence(result, nameOf(target))
    const lines = result.stdout.split('\n').filter((line) => line !== '')
    return {
      done: `Read the last ${lines.length} lines from ${nameOf(target)}.`,
      detail: { lines: lines.length },
      wayBack: null,
      value: { lines },
    }
  },
}

function serviceAction(
  id: 'start' | 'restart' | 'stop',
  label: string,
  sentence: (name: string) => string,
  done: (name: string) => string,
  wayBack: { actionId: ActionId; label: string } | null,
): ServerAction {
  return {
    id,
    klass: 'reversible',
    where: 'server',
    label,
    summary: (target) => sentence(nameOf(target)),
    run: async (deps, target) => {
      const managedBy = target.card.managedBy
      if (managedBy === null) {
        throw new ActionRefused(
          'We can’t tell how this server starts and stops things, so we’re not going to guess.',
        )
      }
      const argv = serviceCommand(managedBy, id, target.facts)
      if (argv === null) {
        throw new ActionRefused('We can’t tell how this server starts and stops things, so we’re not going to guess.')
      }
      ok(await deps.run(target.serverId, argv), nameOf(target))
      return { done: done(nameOf(target)), detail: { action: id }, wayBack }
    },
  }
}

const startAction = serviceAction(
  'start',
  'Start',
  (name) => `Start ${name}. It’ll be running again in a few seconds.`,
  (name) => `Started ${name}.`,
  { actionId: 'stop', label: 'Stop' },
)

const restartAction = serviceAction(
  'restart',
  'Restart',
  (name) => `Restart ${name}. It’ll be offline for about five seconds while it starts again.`,
  (name) => `Restarted ${name}.`,
  // It comes back on its own; Start is the way back only if it does not.
  { actionId: 'start', label: 'Start' },
)

const stopAction = serviceAction(
  'stop',
  'Stop',
  (name) => `Stop ${name}. It’ll be off until you start it again — anyone visiting will see an error.`,
  (name) => `Stopped ${name}.`,
  { actionId: 'start', label: 'Start' },
)

/* ------------------------------------------------------------------- update -- */

/**
 * The dump command for one engine, and null for every engine we do not know.
 *
 * §4.2's rule, restated because it is the one that decides whether a *whole
 * feature* is offered: *"an unrecognised engine dumped with the wrong tool
 * produces a file that looks like a backup and is not one, which is worse than
 * no button by a wide margin."*
 *
 * Credentials come out of the container's **own environment** rather than from
 * anything this app holds, which is why only containerised databases are
 * covered: the official images set `POSTGRES_USER`, `MYSQL_ROOT_PASSWORD` and
 * `MARIADB_ROOT_PASSWORD`, so the dump runs as the database's own owner without
 * this app ever seeing a password. `MYSQL_PWD` is used rather than `-p` on the
 * command line so the password does not appear in the container's process list.
 *
 * A database installed on the host is deliberately **not** covered. Postgres
 * would work through peer authentication and MySQL would not, and shipping a
 * Backup button that succeeds on one engine and fails on another — for a reason
 * about authentication that nothing on the card could explain — is the kind of
 * half-answer this document keeps refusing.
 */
export function dumpCommand(engine: KnownEngine, managedBy: ManagedBy): { probe: string[]; dump: string[] } | null {
  if (managedBy.kind !== 'container') return null
  if (!isSafeName(managedBy.name)) return null
  const exec = [managedBy.runtime, 'exec', managedBy.name, 'sh', '-c']
  if (engine === 'postgres') {
    return {
      probe: [...exec, 'command -v pg_dumpall'],
      dump: [...exec, 'exec pg_dumpall -U "${POSTGRES_USER:-postgres}"'],
    }
  }
  if (engine === 'mysql' || engine === 'mariadb') {
    const tool = engine === 'mariadb' ? 'mariadb-dump' : 'mysqldump'
    return {
      probe: [...exec, `command -v ${tool} || command -v mysqldump`],
      dump: [
        ...exec,
        `export MYSQL_PWD="${'${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}'}"; ` +
          `exec ${tool} -u root --all-databases 2>/dev/null || exec mysqldump -u root --all-databases`,
      ],
    }
  }
  return null
}

/** Engines this app has a real dump command for. Derived, so it cannot drift. */
export function canBackUp(engine: KnownEngine | null, managedBy: ManagedBy | null): engine is DatabaseEngine {
  if (engine === null || managedBy === null) return false
  return dumpCommand(engine, managedBy) !== null
}

/**
 * Copy a database onto this computer, without being asked.
 *
 * Called two ways, and the second is the point. A person can press Backup, and
 * — because updating a database's image is the one `kept` action in this list
 * whose way back is **not** enough on its own — {@link updateAction} calls it
 * itself before it changes anything. Rolling a container's image back restores
 * the *program*; it does nothing about a migration the new version ran over the
 * data on its way up. So a database is copied first, automatically, and if the
 * copy cannot be taken the update does not happen.
 *
 * Three steps, in this order, and the order is what makes it honest:
 *  1. ask whether the dump tool is even in the image — a failure here costs
 *     nothing and produces no file;
 *  2. dump to a temporary file *on the server* and check it is not empty;
 *  3. copy it here, then remove the temporary file whatever happened.
 *
 * Dumping straight down the wire would be fewer steps and would put an
 * unbounded database in this process's memory, which is the same mistake
 * `sessions.transcript` records having had to fix against a 154 MB file.
 */
async function backUpDatabase(deps: ActionDeps, target: ActionTarget): Promise<{ path: string; bytes: number }> {
  const { download, backupDir } = deps
  const managedBy = target.card.managedBy
  const engine = target.card.engine
  if (download === undefined || backupDir === undefined) {
    throw new ActionRefused('This app can’t copy files off a server yet, so there’s no safe way to do this.')
  }
  if (engine === null || managedBy === null || !canBackUp(engine, managedBy)) {
    throw new ActionRefused('We can’t tell what kind of database this is, so we don’t know how to copy it safely.')
  }
  const commands = dumpCommand(engine, managedBy)
  if (commands === null) {
    throw new ActionRefused('We can’t tell what kind of database this is, so we don’t know how to copy it safely.')
  }
  const probe = await deps.run(target.serverId, commands.probe)
  if (!succeeded(probe)) {
    throw new ActionFailed(
      `This database doesn’t come with the tool we’d use to copy it, so we can’t make a copy you could trust.`,
      probe.stderr.trim() === '' ? 'The copy tool was not found on the server.' : probe.stderr.trim(),
    )
  }
  const stamp = new Date((deps.now ?? Date.now)()).toISOString().replace(/[:.]/g, '-')
  const remote = `/tmp/td-backup-${stamp}.sql`
  const local = `${backupDir}/${target.card.name}-${stamp}.sql`
  if (!isSafePath(remote) || !isSafePath(local)) {
    throw new ActionRefused('We couldn’t pick a safe place to put the copy.')
  }
  try {
    ok(
      await deps.run(target.serverId, ['sh', '-c', `${shellJoin(commands.dump)} > ${remote}`]),
      nameOf(target),
    )
    const size = await deps.run(target.serverId, ['sh', '-c', `wc -c < ${remote}`])
    const bytes = Number.parseInt(size.stdout.trim(), 10)
    if (!Number.isFinite(bytes) || bytes <= 0) {
      throw new ActionFailed(
        'The copy came out empty, so we threw it away rather than leave you with a backup that isn’t one.',
        size.stderr.trim() || 'The dump produced zero bytes.',
      )
    }
    const moved = await download(target.serverId, remote, local)
    return { path: local, bytes: moved.bytes }
  } finally {
    // Best effort, and deliberately not checked: a temporary file we could not
    // remove is untidy, and reporting it as a failed backup after the file has
    // already arrived here would be false.
    await deps.run(target.serverId, ['rm', '-f', remote]).catch(() => undefined)
  }
}

/**
 * Quote an argv into one command line.
 *
 * Needed in exactly two places, both of which redirect output into a file on
 * the far end, which a bare argv cannot express. Single quotes with the
 * `'\''` escape is the only POSIX-correct form, and every string that reaches
 * it has already been through {@link isSafeName} or {@link isSafePath}.
 */
export function shellJoin(argv: readonly string[]): string {
  return argv.map((part) => `'${part.replace(/'/g, `'\\''`)}'`).join(' ')
}

const backupAction: ServerAction = {
  id: 'backup',
  klass: 'safe',
  where: 'server',
  label: 'Backup',
  summary: (target) => `Copy everything in ${nameOf(target)} to your computer. Nothing on the server changes.`,
  run: async (deps, target) => {
    const copy = await backUpDatabase(deps, target)
    return {
      done: `Copied ${nameOf(target)} to your computer.`,
      detail: { bytes: copy.bytes },
      wayBack: null,
      value: { path: copy.path, bytes: copy.bytes },
    }
  },
}

/**
 * Which of the two updates this card supports, or null when it supports
 * neither.
 *
 * Deliberately **not** a fallback chain. A container is updated by pulling its
 * image; a checkout is updated by fetching its commits; a card that is both is
 * updated as a container, because that is the thing the server actually
 * restarts. A card that is neither has no Update button and the card says why.
 *
 * `composeAvailable` is a fact rather than an assumption, and it was measured
 * the hard way. The test box runs Docker from Ubuntu's own repository, and that
 * package **does not ship `docker compose`** — measured: `docker: unknown
 * command: docker compose`. Without it there is no proven way to recreate a
 * container from its own definition, so there is no way back, so there is no
 * Update. Offering it anyway would fail *after* the pull, half-way through, on
 * a machine somebody depends on.
 */
export function updateKind(card: ServerCard, composeAvailable: boolean): 'container' | 'repository' | null {
  const managedBy = card.managedBy
  if (managedBy !== null && managedBy.kind === 'container') {
    return managedBy.compose !== null && composeAvailable ? 'container' : null
  }
  if (card.repoDir !== null) return 'repository'
  return null
}

const updateAction: ServerAction = {
  id: 'update',
  klass: 'kept',
  where: 'server',
  label: 'Update',
  summary: (target) => {
    const name = nameOf(target)
    if (target.card.repoDir !== null && target.card.managedBy?.kind !== 'container') {
      return (
        `Update ${name} to the latest code. It’ll restart, and be offline for about five seconds. ` +
        'We’ll remember where it is now so you can go back.'
      )
    }
    if (target.card.engine !== null) {
      /*
       * A database gets a different sentence because it gets a different
       * promise. §4.4: the timing is honest or absent, and a copy of somebody's
       * whole database is not a thing that takes a known number of seconds.
       */
      return (
        `Update ${name} to the newest version. We’ll copy everything in it to your computer first, ` +
        'and keep the current version so you can go back. This can take a minute or two.'
      )
    }
    return (
      `Update ${name} to the newest version. It’ll be offline for about ten seconds. ` +
      'We’ll keep the current version so you can go back.'
    )
  },
  keep: async (deps, target) => {
    const at = (deps.now ?? Date.now)()
    /*
     * `composeAvailable` is true here because `availableActions` is what put
     * the button on the card, and it refuses to when compose is missing. `keep`
     * re-derives the *kind* rather than the availability: which of the two
     * updates this is depends only on the card's own shape.
     */
    const kind = updateKind(target.card, true)
    if (kind === null) {
      throw new ActionRefused('We can’t tell how this was set up, so we don’t know how to put it back.')
    }
    /*
     * Checked first, before a single command is sent. Updating a database whose
     * contents cannot be copied first is the one case in §4.2 where the way
     * back does not lead all the way back — rolling the image back restores the
     * program and nothing about a migration the new version ran over the data.
     * Refusing here rather than after the first `inspect` means the server is
     * not even asked a question we already know we cannot act on.
     */
    if (target.card.engine !== null && (deps.download === undefined || deps.backupDir === undefined)) {
      throw new ActionRefused('This app can’t copy files off a server yet, so there’s no safe way to do this.')
    }
    if (kind === 'repository') {
      const dir = target.card.repoDir
      if (dir === null || !isSafePath(dir)) {
        throw new ActionRefused('We can’t tell where this is kept on the server, so we don’t know how to put it back.')
      }
      /*
       * A dirty checkout is refused rather than stashed. Uncommitted work on a
       * server is somebody's hand-edit, and `git reset --hard` back to the
       * recorded commit would destroy it — which would make this a `kept`
       * action that is not actually reversible, the one thing §4.1 says cannot
       * ship.
       */
      const dirty = await deps.run(target.serverId, ['git', '-C', dir, 'status', '--porcelain'])
      if (!succeeded(dirty)) throw failureSentence(dirty, nameOf(target))
      if (dirty.stdout.trim() !== '') {
        throw new ActionRefused(
          'Someone has changed this on the server itself. We won’t update it, because we couldn’t put those ' +
            'changes back afterwards.',
        )
      }
      const head = await deps.run(target.serverId, ['git', '-C', dir, 'rev-parse', 'HEAD'])
      if (!succeeded(head)) throw failureSentence(head, nameOf(target))
      const commit = head.stdout.trim()
      if (!/^[0-9a-f]{7,64}$/.test(commit)) {
        throw new ActionRefused('We couldn’t work out which version is on the server, so we didn’t change anything.')
      }
      return { kind: 'repo-commit', at, dir, commit, managedBy: target.card.managedBy, backupPath: null }
    }

    const managedBy = target.card.managedBy
    if (managedBy === null || managedBy.kind !== 'container' || managedBy.compose === null) {
      throw new ActionRefused('We can’t tell how this was set up, so we don’t know how to put it back.')
    }
    const inspect = await deps.run(target.serverId, [
      managedBy.runtime,
      'inspect',
      '--format',
      '{{.Image}}\t{{.Config.Image}}',
      managedBy.name,
    ])
    if (!succeeded(inspect)) throw failureSentence(inspect, nameOf(target))
    const [imageId, imageRef] = inspect.stdout.trim().split('\t')
    if (imageId === undefined || imageRef === undefined || imageId === '' || imageRef === '') {
      throw new ActionRefused('We couldn’t work out which version is running, so we didn’t change anything.')
    }
    /*
     * Rolling back re-points the tag at the recorded image, so the image has to
     * still be on the server for the way back to exist at all. Docker keeps the
     * old one after a pull — it becomes untagged rather than deleted — but a
     * machine that prunes on a timer will not have it, and finding that out
     * *after* the update is finding it out too late.
     */
    if (!isSafeName(imageRef)) {
      throw new ActionRefused('We can’t tell which version this uses, so we don’t know how to put it back.')
    }
    const backup =
      target.card.engine !== null ? await backUpDatabase(deps, target) : null
    return {
      kind: 'container-image',
      at,
      container: managedBy.name,
      imageId: imageId.trim(),
      imageRef: imageRef.trim(),
      compose: managedBy.compose,
      backupPath: backup?.path ?? null,
    }
  },
  run: async (deps, target, kept) => {
    if (kept === null) {
      // Unreachable through `perform`, which is the only supported caller. Kept
      // as a throw rather than an assertion because the whole class guarantee
      // rests on it: an Update that ran with nothing recorded would be an
      // irreversible action wearing a reversible label.
      throw new ActionRefused('We didn’t manage to record a way back, so we haven’t changed anything.')
    }
    const name = nameOf(target)
    if (kept.kind === 'repo-commit') {
      ok(await deps.run(target.serverId, ['git', '-C', kept.dir, 'fetch', '--quiet']), name)
      ok(await deps.run(target.serverId, ['git', '-C', kept.dir, 'merge', '--ff-only']), name)
      if (kept.managedBy !== null) {
        const argv = serviceCommand(kept.managedBy, 'restart', target.facts)
        if (argv !== null) ok(await deps.run(target.serverId, argv), name)
      }
      const head = await deps.run(target.serverId, ['git', '-C', kept.dir, 'rev-parse', 'HEAD'])
      return {
        done:
          head.stdout.trim() === kept.commit
            ? `${name} was already up to date.`
            : `Updated ${name}. You can still go back to the version it was on.`,
        detail: { from: kept.commit.slice(0, 12), to: head.stdout.trim().slice(0, 12) },
        wayBack: { actionId: 'go-back', label: 'Go back' },
      }
    }
    const runtime = containerRuntimeOf(target.card)
    if (runtime === null) throw new ActionRefused('We can’t reach the container this runs in any more.')
    ok(await deps.run(target.serverId, composeArgv(runtime, kept.compose, ['pull', kept.compose.service])), name)
    ok(await deps.run(target.serverId, composeArgv(runtime, kept.compose, ['up', '-d', kept.compose.service])), name)
    return {
      done: `Updated ${name}. You can still go back to the previous version.`,
      detail: { from: kept.imageId.slice(0, 19), backedUp: kept.backupPath !== null },
      wayBack: { actionId: 'go-back', label: 'Go back to the previous version' },
    }
  },
}

const goBackAction: ServerAction = {
  id: 'go-back',
  klass: 'reversible',
  where: 'server',
  label: 'Go back',
  summary: (target) =>
    `Put ${nameOf(target)} back on the version it was on before the last update. It’ll be offline for ` +
    'about ten seconds. Update will bring it forward again.',
  run: async (deps, target) => {
    const kept = await deps.journal.get(target.serverId, target.card.id)
    if (kept === null) {
      throw new ActionRefused('We don’t have a previous version recorded for this, so there’s nothing to go back to.')
    }
    const name = nameOf(target)
    if (kept.kind === 'repo-commit') {
      ok(await deps.run(target.serverId, ['git', '-C', kept.dir, 'reset', '--hard', kept.commit]), name)
      if (kept.managedBy !== null) {
        const argv = serviceCommand(kept.managedBy, 'restart', target.facts)
        if (argv !== null) ok(await deps.run(target.serverId, argv), name)
      }
      await deps.journal.clear(target.serverId, target.card.id)
      return {
        done: `Put ${name} back.`,
        detail: { commit: kept.commit.slice(0, 12) },
        wayBack: { actionId: 'update', label: 'Update' },
      }
    }
    const runtime = containerRuntimeOf(target.card)
    if (runtime === null) throw new ActionRefused('We can’t reach the container this runs in any more.')
    /*
     * The check that makes this honest. The way back is a *tag being pointed
     * back* at an image that is still on the server; a machine that pruned it
     * has no way back, and the person needs to be told that rather than watch
     * a rollback report success while pulling the new version again.
     */
    const present = await deps.run(target.serverId, [runtime, 'image', 'inspect', kept.imageId])
    if (!succeeded(present)) {
      throw new ActionFailed(
        'The previous version isn’t on this server any more, so we can’t put it back.',
        present.stderr.trim() || 'The recorded image is no longer present.',
      )
    }
    ok(await deps.run(target.serverId, [runtime, 'tag', kept.imageId, kept.imageRef]), name)
    ok(
      await deps.run(
        target.serverId,
        composeArgv(runtime, kept.compose, ['up', '-d', '--force-recreate', kept.compose.service]),
      ),
      name,
    )
    await deps.journal.clear(target.serverId, target.card.id)
    return {
      done: `Put ${name} back on the previous version.`,
      detail: { imageId: kept.imageId.slice(0, 19) },
      wayBack: { actionId: 'update', label: 'Update' },
    }
  },
}

function containerRuntimeOf(card: ServerCard): 'docker' | 'podman' | null {
  const managedBy = card.managedBy
  return managedBy !== null && managedBy.kind === 'container' ? managedBy.runtime : null
}

/** Every action, by id. The catalogue the tests and the tools both read. */
export const SERVER_ACTIONS: Readonly<Record<ActionId, ServerAction>> = Object.freeze({
  open: openAction,
  'copy-address': copyAddressAction,
  logs: logsAction,
  start: startAction,
  restart: restartAction,
  stop: stopAction,
  update: updateAction,
  'go-back': goBackAction,
  backup: backupAction,
})

/* ------------------------------------------------------------- availability -- */

/** An action that is not offered, and the sentence the card carries instead. */
export interface AbsentAction {
  actionId: ActionId
  because: string
}

export interface Availability {
  /** Actions this card's facts support, in the order a card draws them. */
  offered: ActionId[]
  /**
   * Actions a person might expect and will not find, each with its reason.
   *
   * §5.2: *"every button on a card is either a real action or absent"* — but an
   * absence with no explanation reads as a missing feature. The one permitted
   * disabled-with-a-reason case is Backup, and this is the list the card draws
   * that reason from.
   */
  absent: AbsentAction[]
}

/**
 * Which actions this card's *facts* support, and why each of the others is not
 * there.
 *
 * The whole of §4.1's *"a control that cannot act is removed, or disabled with
 * a stated reason — never drawn hopefully."* Nothing in here is optimistic: an
 * action appears only when every fact it needs came back `yes`.
 */
export interface AvailabilityDeps {
  /** Can this build copy a file off a server at all? Decides every Backup button. */
  canDownload: boolean
  /** Did the way-back survey find the tool that recreates a container? */
  composeAvailable: boolean
}

/**
 * What the remainder heading gets instead of Start, Stop and Restart.
 *
 * Exported because three surfaces have to say the same thing: the card draws
 * it, `ipc.ts` refuses with it when something asks anyway, and the copilot gets
 * it as the reason its call was turned down.
 */
export const NOT_YOURS_TO_STOP =
  'We can’t tell whether you set this up, so this app doesn’t offer to start or stop it. ' +
  'The terminal under Advanced can, if you know you need to.'

export function availableActions(card: ServerCard, facts: ActionFacts, deps: AvailabilityDeps): Availability {
  const offered: ActionId[] = []
  const absent: AbsentAction[] = []
  const managedBy = card.managedBy

  if (card.url !== null) {
    offered.push('open', 'copy-address')
  }

  /*
   * *Other things running* is read-only, and this is the one place that decides
   * it — `ipc.ts` re-checks availability before it performs anything, so
   * withholding here withholds the capability and not merely the button.
   *
   * Measured on a real box: the remainder was **fifty-odd** rows of the
   * operating system talking to itself — `apparmor`, `apport`, `atd`,
   * `systemd-udevd`, `ufw`, `user@0` — and every one carried Restart and Stop.
   * **Sixty-four of them on one page.** Half will take the machine, or our own
   * connection, down with them, and the audience §1.2 names for this screen is
   * a person who does not know which half.
   *
   * The discriminator is not a guess about danger, which would be exactly the
   * assumption rule 4 bans. It is the same fact that put the card in this group
   * at all: `ServiceFact.addedHere` said nobody here set this up. We do not
   * know what it is, so we do not offer to change it — and we say so, and we
   * point at the terminal, which is unbounded on purpose and one door further
   * in.
   *
   * Reading stays. Logs answer "what is this and is it unhappy", which is the
   * question somebody opening this group actually has, and reading changes
   * nothing.
   */
  if (card.kind === 'other') {
    if (managedBy !== null && logCommand(managedBy, DEFAULT_LOG_LINES, facts) !== null) offered.push('logs')
    absent.push({ actionId: 'restart', because: NOT_YOURS_TO_STOP })
    return { offered, absent }
  }

  if (managedBy === null) {
    absent.push({
      actionId: 'restart',
      because: 'We can’t tell how this server starts and stops things, so we’re not going to guess.',
    })
  } else if (managedBy.kind !== 'container' && !canAdminister(facts)) {
    // The privilege fact said there is no way to become an administrator at
    // all — not "we would have to ask for a password", which §3.4 says we may
    // try. This is the one case where offering the button would be certain to
    // fail.
    absent.push({ actionId: 'restart', because: 'This sign-in can’t start or stop things on this server.' })
  } else {
    if (logCommand(managedBy, DEFAULT_LOG_LINES, facts) !== null) offered.push('logs')
    else absent.push({ actionId: 'logs', because: 'This server doesn’t keep a log we can read for this.' })
    if (card.running === false) offered.push('start')
    if (card.running !== false) offered.push('restart', 'stop')
  }

  if (card.engine !== null) {
    if (canBackUp(card.engine, managedBy) && deps.canDownload) offered.push('backup')
    else if (!deps.canDownload) {
      absent.push({ actionId: 'backup', because: 'This app can’t copy files off a server yet.' })
    } else {
      absent.push({
        actionId: 'backup',
        because: 'We can’t tell what kind of database this is, so we don’t know how to copy it safely.',
      })
    }
  }

  const kind = updateKind(card, deps.composeAvailable)
  if (kind === null) {
    absent.push({
      actionId: 'update',
      because:
        managedBy !== null && managedBy.kind === 'container' && managedBy.compose !== null && !deps.composeAvailable
          ? 'This server doesn’t have the tool we’d use to put a container back, so we won’t change one.'
          : 'We can’t tell how this was set up, so we don’t know how to put it back.',
    })
  } else if (card.engine !== null && !(canBackUp(card.engine, managedBy) && deps.canDownload)) {
    /*
     * A database whose contents we cannot copy first gets no Update button at
     * all. Rolling the image back restores the program and not the data, so
     * without the copy this would be a `kept` action with a way back that does
     * not actually lead all the way back — which §4.1 says must not ship.
     */
    absent.push({
      actionId: 'update',
      because:
        'We can’t make a copy of what’s in here first, and updating a database without one isn’t something ' +
        'we can undo.',
    })
  } else {
    offered.push('update')
  }

  return { offered, absent }
}

/* ------------------------------------------------------------------ perform -- */

/**
 * Run one action, with the class's discipline around it.
 *
 * This is the only supported way to run anything in {@link SERVER_ACTIONS}, and
 * the reason it exists rather than being folded into each `run` is the ordering
 * it enforces for the `kept` class:
 *
 *   1. **record** the way back;
 *   2. **write it down**, on this computer;
 *   3. **read it back**, because a write that silently did nothing is
 *      indistinguishable from a write that worked until the moment somebody
 *      needs it;
 *   4. only then **change** anything.
 *
 * A failure at any of the first three throws {@link ActionRefused} and the
 * server is untouched. That is the difference between a promise and a
 * mechanism, and it is why `no-action-without-a-way-back.test.ts` drives this
 * function with a journal that refuses to write.
 */
export async function perform(deps: ActionDeps, actionId: ActionId, target: ActionTarget): Promise<ActionOutcome> {
  const action = SERVER_ACTIONS[actionId]
  if (action === undefined) throw new ActionRefused('That isn’t something this app can do.')

  if (action.klass !== 'kept') return action.run(deps, target, null)

  if (action.keep === undefined) {
    throw new ActionRefused('We didn’t manage to record a way back, so we haven’t changed anything.')
  }
  const kept = await action.keep(deps, target)
  try {
    await deps.journal.put(target.serverId, target.card.id, kept)
  } catch {
    throw new ActionRefused('We couldn’t save a way back on this computer, so we haven’t changed anything.')
  }
  const readBack = await deps.journal.get(target.serverId, target.card.id).catch(() => null)
  if (readBack === null) {
    throw new ActionRefused('We couldn’t save a way back on this computer, so we haven’t changed anything.')
  }
  return action.run(deps, target, readBack)
}

/* -------------------------------------------------------------- the room -- */

/**
 * One server as the list draws it. Never a credential — §3.7.
 *
 * The last two fields are *about* the sign-in and the identity without being
 * either, and the distinction is the one §3.7 draws: *"the renderer learns that
 * a server has a saved sign-in, and never what it is."*
 *
 *  - `credential` is the **kind** — a password, a key, or nothing kept. It is
 *    what lets the sign-in section say "kept on this computer" instead of "this
 *    build did not say", and knowing that a password exists gets nobody in.
 *  - `hostKey` is **public by construction**. The fingerprint is the same
 *    string `ssh-keyscan` prints and the same one the server hands every client
 *    that dials it, and showing it is the entire point of §3.6: the identity
 *    screen says *"you can compare what is below against the server itself"*,
 *    which is worth nothing if the app will not say what it saw.
 *
 * Both are optional because a host that does not store servers — a test, the
 * headless build — has nothing to say about either, and an absent field draws
 * "we have not asked" rather than a confident blank.
 *
 * `hostKey` keeps the **nested** shape the store writes rather than being
 * flattened to a bare string on the way past. One shape from the file to the
 * screen is one shape to be wrong about: this exact field was flat on this side
 * and nested in the window's narrower for a while, which typechecked perfectly
 * and drew *"It has not told us one yet"* on a server whose fingerprint was
 * sitting in `servers.json`. The algorithm travels with it because a
 * fingerprint without the algorithm that produced it is half of a comparison.
 */
export interface ServerSummary {
  id: string
  name: string
  address: string
  username: string
  credential?: 'password' | 'key' | 'none'
  hostKey?: { algorithm: string; fingerprint: string }
}

/**
 * Everything the copilot's tools and the window both go through.
 *
 * `ipc.ts` implements it over A's connection layer; `tools.ts` closes over it.
 * The interface exists so that the permission decisions in `tools.ts` are
 * exercisable against a plain object — the same argument `deck-control/surface.ts`
 * makes at length: *"the piece that must be exercisable is the piece that
 * decides whether a dangerous call happens."*
 */
export interface ServerRoom {
  list(): ServerSummary[]
  knows(serverId: string): boolean
  /** Facts and cards for one server, connecting if the page is not already open. */
  look(serverId: string): Promise<ServerView>
  /**
   * The last view of this server, without asking it anything.
   *
   * Synchronous and possibly stale, and both are on purpose. §5.4: *"a server
   * page can be showing stale facts, and that is correct behaviour"* — the age
   * is on screen, and making it live would mean a timer per server, which is
   * the thing his standing **events, not polling** rule bans. Null means this
   * app has never looked, which `tools.ts` treats as a reason to refuse rather
   * than as a reason to guess.
   */
  cached(serverId: string): ServerView | null
  /** The sentence an action would show, without running it. */
  preview(serverId: string, cardId: string, actionId: ActionId): Promise<ActionPreview>
  act(serverId: string, cardId: string, actionId: ActionId): Promise<ActionOutcome>
  logs(serverId: string, cardId: string, lines: number): Promise<{ lines: string[] }>
}

/**
 * One server, as the page and the copilot both see it.
 *
 * `offered` and `absent` are keyed by card id rather than folded into the card,
 * so `ServerCard` stays what `classify.ts` measured and this stays what
 * `actions.ts` decided. The two answer different questions and mixing them is
 * how a card ends up carrying a button that its own facts do not support.
 */
export interface ServerView {
  cards: ServerCard[]
  facts: ActionFacts
  /**
   * Did the way-back survey find the tool that recreates a container?
   *
   * On the view rather than derived on demand because three surfaces need the
   * same answer — the card that draws Update, the preview that describes it,
   * and the copilot's precheck — and a third of them working it out separately
   * is how the button and the sentence end up disagreeing.
   */
  composeAvailable: boolean
  /** cardId → the actions its facts support, in the order a card draws them. */
  offered: Record<string, ActionId[]>
  /** cardId → the actions that are not there, each with its sentence. */
  absent: Record<string, AbsentAction[]>
  /** The checks that ran, in plain words. §3.1's `how`, at the level of a page. */
  how: string[]
  /** Questions that could not be asked, with the reason. Never drawn as a zero. */
  cannot: Array<{ what: string; why: string }>
  measuredAt: number
}

/**
 * What a person is shown before they press: what will happen, to what, and for
 * how long.
 *
 * Assembled from the action itself, never from the caller, so the dialog and
 * the copilot's consent question are looking at the same object. `duration` is
 * absent rather than guessed where §4.4 says a number would be dishonest.
 */
export interface ActionPreview {
  actionId: ActionId
  klass: ActionClass
  label: string
  /** The person's name for the thing this happens to. */
  target: string
  /** The consequence sentence. The one string all three surfaces render. */
  sentence: string
  /** The button that puts it back, when the class has one. */
  wayBack: string | null
  /** What we will write down first, for the `kept` class. Null otherwise. */
  keeps: string | null
}

/** Build the preview for one action against one card. */
export function previewOf(actionId: ActionId, target: ActionTarget, composeAvailable = true): ActionPreview {
  const action = SERVER_ACTIONS[actionId]
  const kind = updateKind(target.card, composeAvailable)
  return {
    actionId,
    klass: action.klass,
    label: action.label,
    target: target.card.name,
    sentence: action.summary(target),
    wayBack:
      actionId === 'stop' || actionId === 'start'
        ? actionId === 'stop'
          ? 'Start'
          : 'Stop'
        : actionId === 'restart'
          ? 'Start'
          : actionId === 'update'
            ? kind === 'repository'
              ? 'Go back'
              : 'Go back to the previous version'
            : actionId === 'go-back'
              ? 'Update'
              : null,
    keeps:
      action.klass !== 'kept'
        ? null
        : kind === 'repository'
          ? 'the exact version of the code that is on the server right now'
          : target.card.engine !== null
            ? 'a copy of everything in this database, on your computer, and the version that is running now'
            : 'the version that is running now',
  }
}

/** Re-exported so `ipc.ts` and `tools.ts` have one import site for the card shape. */
export type { ServerCard, ManagedBy, ComposeRef }
export { isSafeName, isSafePath }
