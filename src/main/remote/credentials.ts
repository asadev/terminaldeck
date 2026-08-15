/**
 * Their GitHub, from their device, used once and never kept.
 *
 * A person is granted a folder on somebody else's machine and works in it. Two
 * things have to be true at once and neither is true of a plain shell:
 *
 *  1. They never get the owner's GitHub. That is `git-guest.ts`, and it ships on
 *     its own — a session whose credential helper list is empty simply cannot
 *     reach the owner's login, whether or not anything below ever runs.
 *  2. The owner never holds theirs. That is this file. Their token stays on
 *     their device; when git here needs a login, the request is carried over the
 *     encrypted channel that already exists, answered there, and used once, in
 *     memory, on the way into the process that asked.
 *
 * ```
 * git push
 *   -> the helper (git-guest.ts) -> loopback -> this desk
 *      -> the sealed channel -> their device (which holds the token)
 *      <- an answer, for this operation only
 *   -> git uses it; nothing here keeps it
 * ```
 *
 * ## Why git is asked through a *credential helper* and not through GIT_ASKPASS
 *
 * `GIT_ASKPASS` is handed a prompt — `Password for 'https://github.com'` — and
 * that string names a **host**. It does not name the repository, and without the
 * repository there is no honest question to put on somebody's phone: "approve a
 * push to github.com" is consent to push anywhere the account can reach, which
 * is exactly what this feature exists not to ask for. A credential helper with
 * `credential.useHttpPath` set is handed `path=owner/repo.git`, so the prompt can
 * name the repository and an approval can be scoped to it. The same script wears
 * both hats and the askpass hat **refuses**; see `askpassScript`.
 *
 * ## Read or write, and what happens when we cannot tell
 *
 * Git tells a credential helper nothing about what it is doing. A fetch and a
 * push produce byte-identical requests, and that is not an oversight in this
 * code — it is the protocol. The only thing that distinguishes them from inside
 * the helper is the process that started it, so the operation is read out of the
 * ancestry: the helper reports its own pid, and this end walks up to `git push`
 * or `git fetch` and classifies.
 *
 * **When that fails it says `write`**, which means it prompts. The failure
 * direction is chosen rather than accidental: prompting for a fetch is a person
 * tapping a button they did not need to tap, and *not* prompting for a push is
 * the entire feature not working. Windows has no `ps` and gets that answer for
 * every request today; that is a real gap, stated rather than hidden, and it
 * costs a prompt rather than a silent push.
 *
 * ## What an approval is
 *
 * One repository, from one device, for as long as this app is running. Not "this
 * person, everywhere" — a grant to work in one folder is not consent to push to
 * everything an account can reach — and not anything on disk. Revocation is
 * disconnection: the trust store drops the device, its sockets close, and the
 * approvals go with them because they were never anywhere else.
 *
 * Every push still comes back here for the credential itself. What an approval
 * buys is that nobody is asked again; it is a *scope*, not a stored secret, and
 * there is no window in which a later command can ride on an earlier one's
 * unlocked state.
 *
 * ## Never log a credential
 *
 * An answer goes into the HTTP response git is waiting on and nowhere else. It
 * is not logged, not counted, not summarised, and not put in an error — which is
 * a stronger rule than redacting it would be, because a redactor has to be right
 * every time and an absent call site cannot be wrong.
 *
 * The two things that *are* logged are both failures of this module rather than
 * of a request, and both go through `redact.ts` on the way out: a helper request
 * that threw, and a listener that would not bind. Neither has a credential in it
 * today, and neither is a place to find out that one does.
 *
 * The environment carries the same rule. A session's key is named after the
 * brand with `CREDENTIAL` in it, which `redact.ts` already treats as a secret
 * key name — so it is folded out of a support bundle by a rule that exists
 * rather than by one somebody has to remember to add.
 *
 * ## What this is not
 *
 * It is not isolation. A guest has a shell as the owner's account and can do
 * anything that account can do, including reading their `~/.gitconfig` and their
 * ssh keys. What is true, and all that is claimed anywhere, is that their GitHub
 * account stays theirs: the token never touches this machine's disk, and
 * disconnecting ends all access.
 */

import { execFile } from 'node:child_process'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { join } from 'node:path'
import { BRAND } from '../../shared/brand'
import { currentPlatform, isWindows, type Platform } from '../platform/host'
import { parseRemoteUrl } from '../github'
import { redact } from '../redact'
import {
  HELPER_FILE,
  guestGitDir,
  prepareGuestGit,
  type CredentialLink,
  type GuestGitEnv,
} from './git-guest'
import {
  MAX_CREDENTIAL_HOST_LENGTH,
  MAX_CREDENTIAL_REPO_LENGTH,
  type CredentialDenial,
  type CredentialOperation,
  type ServerMessage,
} from './protocol'

/* ------------------------------------------------------------------ shapes -- */

/** What git asked for, once its `key=value` lines have been read. */
export interface GitCredentialQuery {
  /** `https`. Anything else is refused before a device is troubled. */
  protocol: string
  host: string
  /** `owner/name`, or null when git gave nothing to derive one from. */
  repo: string | null
}

/** What the helper is told, which is either a login or a sentence. */
export type CredentialOutcome =
  | { ok: true; username: string; password: string }
  | { ok: false; message: string }

/** The subset of `ClientMessage` this module answers. */
export type CredentialMessage =
  | { t: 'credential.ack'; id: string }
  | { t: 'credential.answer'; id: string; username: string; password: string; remember?: true }
  | { t: 'credential.deny'; id: string; reason?: CredentialDenial }

/**
 * How this desk reaches a device, handed over by the endpoint that owns the
 * sockets.
 *
 * The same shape `RelayLink` gets and for the same reason: the two halves are
 * mutually recursive — the server needs the desk to route answers, the desk needs
 * the server to ask questions — and a function passed in one direction is how
 * that knot is tied without either module importing the other.
 */
export interface DevicePost {
  /**
   * Put a question to every connection of this device that said it can answer.
   * Returns how many heard it, which is zero for a device that is not there.
   */
  ask(deviceId: string, message: ServerMessage): number
  /** Is there a live connection that claimed the `credential` capability? */
  reachable(deviceId: string): boolean
}

/**
 * One session's grant, from before it is spawned until after it exits.
 *
 * The key exists before the session does, which is the whole reason this is a
 * handle rather than two calls keyed by session id: the environment has to carry
 * the key into the PTY, and the PTY's id does not exist until it has been
 * spawned with that environment.
 */
export interface GuestSession {
  /** What to set and unset on the session. */
  readonly env: GuestGitEnv
  /** Tie the grant to the session that was started with it. */
  started(sessionId: string): void
  /** Nothing more may be asked with this key. */
  close(): void
}

export interface CredentialProxy {
  /** Told how to reach devices, once, by the endpoint that holds their sockets. */
  serve(post: DevicePost): void
  /** A device answered. `server.ts` routes these and nothing else may. */
  handle(deviceId: string, message: CredentialMessage): void
  /**
   * One of a device's sockets closed.
   *
   * Not the same as {@link forget}: a phone that dropped wifi mid-push keeps its
   * approvals, because it is the same phone and the same person. What it loses is
   * anything actually in flight, and only once its *last* capable connection has
   * gone — a device with two sockets open has not gone anywhere.
   */
  connectionClosed(deviceId: string): void
  /** The device is gone for good. Approvals and anything in flight go with it. */
  forget(deviceId: string): void
  /** A session is starting for this device. */
  openGuestSession(deviceId: string): Promise<GuestSession>
  /** That session has exited; its key stops working. */
  sessionEnded(sessionId: string): void
  /** Where the helper is answered, for diagnostics. Null when it never bound. */
  address(): string | null
  stop(): Promise<void>
}

/* --------------------------------------------------------------- constants -- */

/** Header carrying a session's key, and the one carrying the helper's own pid. */
export const CREDENTIAL_HEADER = `x-${BRAND.id}-credential`
export const PID_HEADER = `x-${BRAND.id}-pid`

/** The one path the endpoint serves. */
export const CREDENTIAL_PATH = '/credential'

/**
 * How long a device has to say it heard the question.
 *
 * This is the number the whole feature is judged on. A device that is asleep,
 * offline or has quit the app looks exactly like a person who is thinking, and
 * without a deadline of its own the first case would wait out the second — a
 * thirty-second stall on a push with nothing on screen, which is how people stop
 * trusting a feature.
 *
 * Four seconds is generous for a round trip to a woken app over any link this
 * works on at all, and short enough that the failure reads as a failure rather
 * than as a hang.
 */
export const REACH_TIMEOUT_MS = 4_000

/**
 * How long a person has to read a prompt and decide, once their device has
 * answered that it is there.
 *
 * Long, deliberately, and it is not in tension with the deadline above. That one
 * covers "is anybody home", which has to be answered in seconds. This one starts
 * only after the device has said it is, and by then the person is looking at a
 * prompt — waiting for somebody who knows they are being waited for is not a
 * hang.
 */
export const DECIDE_TIMEOUT_MS = 60_000

/**
 * How long a request nobody has to answer may take.
 *
 * A silent request — a fetch, or a push against an already-approved repository —
 * involves no human, so the device replies as fast as it can read its own
 * keychain. Ten seconds is a slow phone on a bad link, not a person.
 */
export const SILENT_TIMEOUT_MS = 10_000

/**
 * How many questions one device may be holding at once, and how many in total.
 *
 * A person pushes one thing at a time; more than a handful at once is a script
 * in a loop, and the cost of that is somebody's phone buzzing forty times. The
 * refusal is immediate and says what it is, so a legitimate burst degrades into
 * "try again" rather than into silence.
 */
const MAX_PENDING_PER_DEVICE = 4
const MAX_PENDING = 16

/**
 * How many repositories one device may have approved.
 *
 * In memory, so this is only a bound on a runaway rather than a policy anyone
 * will meet: sixty-four repositories in one run of the app is far past what a
 * person does, and the oldest is dropped rather than the newest refused, because
 * a cap that starts refusing approvals is a cap that reads as the feature being
 * broken.
 */
const MAX_APPROVALS_PER_DEVICE = 64

/** Largest credential request the helper may post. Git's are a few hundred bytes. */
const MAX_REQUEST_BYTES = 16 * 1024

/** How far up the process tree to look for the git command that is asking. */
const MAX_ANCESTRY_DEPTH = 8

/** Loopback only, and the Host header has to say so — see `hook-server.ts`. */
const HOST = '127.0.0.1'
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]', '::1'])

/* --------------------------------------------------------- the git protocol -- */

/**
 * Read git's credential request.
 *
 * The format is `key=value` lines, terminated by a blank line or by end of
 * input. Unknown keys are ignored rather than refused: git adds them over time —
 * `wwwauth[]` arrived in 2.46 and `capability[]` after it — and a helper that
 * fell over on a key it had not been taught would break on a git upgrade, which
 * is the worst possible time for a credential helper to stop working.
 *
 * Returns null when there is no host, because a request that does not say where
 * it is going cannot be put to anybody.
 */
export function parseHelperRequest(text: string): GitCredentialQuery | null {
  let protocol = ''
  let host = ''
  let path = ''
  for (const raw of text.split('\n')) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw
    if (line === '') break
    const equals = line.indexOf('=')
    if (equals <= 0) continue
    const key = line.slice(0, equals)
    const value = line.slice(equals + 1)
    if (key === 'protocol') protocol = value
    else if (key === 'host') host = value
    else if (key === 'path') path = value
  }
  // A host this long is not one git resolved; it is a caller that has gone wrong
  // or one seeing what this end will carry. The value ends up in a frame sent to
  // somebody's phone, so it is bounded here rather than trusted for being local.
  if (host === '' || host.length > MAX_CREDENTIAL_HOST_LENGTH) return null
  return { protocol, host, repo: repoFromPath(protocol, host, path) }
}

/**
 * `owner/name` out of the path git supplied, or null.
 *
 * The parsing is `parseRemoteUrl`'s, reached by putting the pieces back into the
 * URL they came out of. That is not a detour for its own sake: that function
 * already refuses `..` as an owner, refuses a three-segment path that is a gist
 * or a wiki rather than a repository, and refuses an owner beginning with a
 * hyphen — and this string ends up in a prompt somebody reads before approving a
 * push, which is the one screen in this feature that must not be able to lie
 * about what it is naming.
 *
 * Null is a legitimate outcome and is passed along rather than papered over. It
 * means this desktop does not know what the repository is called, and a client
 * should say so rather than invent a name.
 */
function repoFromPath(protocol: string, host: string, path: string): string | null {
  if (path === '' || path.length > MAX_CREDENTIAL_REPO_LENGTH) return null
  const trimmed = path.replace(/^\/+/, '')
  if (trimmed === '') return null
  const scheme = protocol === '' ? 'https' : protocol
  const parsed = parseRemoteUrl(`${scheme}://${host}/${trimmed}`)
  return parsed ? `${parsed.owner}/${parsed.name}` : null
}

/**
 * The answer, in the shape git reads it.
 *
 * Values with a newline in them are refused by the parser this never sees — see
 * `credentialValue` in `protocol.ts` — so this cannot produce a broken frame
 * from a well-formed message. It checks anyway, because the cost of being wrong
 * is that a device writes an extra `key=value` line of its own choosing into the
 * middle of git's input, and the cost of the check is a scan of a short string.
 */
export function formatHelperAnswer(username: string, password: string): string | null {
  if (/[\r\n\0]/.test(username) || /[\r\n\0]/.test(password)) return null
  return `username=${username}\npassword=${password}\n`
}

/* --------------------------------------------------------- read or write -- */

/** Verbs that only ever read. Anything not here prompts. */
const READ_VERBS = new Set([
  'fetch',
  'pull',
  'clone',
  'ls-remote',
  'remote',
  'submodule',
  'archive',
  'upload-pack',
])

/** Verbs that write. Listed for the log, not for the decision — the default is `write`. */
const WRITE_VERBS = new Set(['push', 'send-pack', 'receive-pack'])

/**
 * Options that swallow the token after them, so `git -c x=y push` is a push.
 *
 * Only the ones that take a *separate* argument. `--git-dir=/x` carries its value
 * with it and is skipped by the leading-hyphen rule like any other option.
 */
const OPTIONS_WITH_VALUES = new Set(['-c', '-C', '--git-dir', '--work-tree', '--namespace', '--exec-path'])

/** The last path segment, for a command line written with either separator. */
function commandName(token: string): string {
  const cut = Math.max(token.lastIndexOf('/'), token.lastIndexOf('\\'))
  return cut === -1 ? token : token.slice(cut + 1)
}

/**
 * The subcommand out of one command line, or null when it is not a git.
 *
 * Deliberately reads the tokens rather than matching the word anywhere in the
 * line: a checkout at `/Users/x/push-service` would otherwise make every fetch
 * inside it look like a push, which is a prompt nobody can explain.
 */
export function gitSubcommand(line: string): string | null {
  const parts = line.trim().split(/\s+/)
  for (let i = 0; i < parts.length; i += 1) {
    const name = commandName(parts[i])
    if (name !== 'git' && name !== 'git.exe') continue
    for (let j = i + 1; j < parts.length; j += 1) {
      const token = parts[j]
      if (OPTIONS_WITH_VALUES.has(token)) {
        j += 1
        continue
      }
      if (token.startsWith('-')) continue
      return token
    }
    return null
  }
  return null
}

/**
 * What git was doing, read off the processes above the helper.
 *
 * The nearest git wins: an agent CLI that runs `git push` inside a shell started
 * by `git fetch`'s pager would otherwise be classified by whichever ancestor was
 * checked last. Anything unrecognised — no git in the ancestry at all, a `ps`
 * that would not run, Windows — falls through to `write`, which prompts. See the
 * header for why that is the safe direction.
 */
export function classifyOperation(ancestry: readonly string[]): CredentialOperation {
  for (const line of ancestry) {
    const verb = gitSubcommand(line)
    if (verb === null) continue
    if (READ_VERBS.has(verb)) return 'read'
    if (WRITE_VERBS.has(verb)) return 'write'
  }
  return 'write'
}

/** One row of `ps -Ao pid=,ppid=,args=`. */
interface PsRow {
  ppid: number
  args: string
}

/**
 * Parse a whole `ps` table.
 *
 * Lines that do not begin with two numbers are skipped rather than treated as a
 * malformed table. A command line can contain a newline — a `git commit -m` with
 * a multi-line message is the everyday case — and `ps` prints it raw, so the
 * continuation lines are simply not rows.
 */
export function parsePsTable(output: string): Map<number, PsRow> {
  const rows = new Map<number, PsRow>()
  for (const line of output.split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
    if (!match) continue
    rows.set(Number(match[1]), { ppid: Number(match[2]), args: match[3] })
  }
  return rows
}

/** Walk a parsed table upwards from one process. Exported so it can be pinned. */
export function ancestryFrom(table: Map<number, PsRow>, pid: number): string[] {
  const out: string[] = []
  let at = pid
  const seen = new Set<number>()
  for (let depth = 0; depth < MAX_ANCESTRY_DEPTH; depth += 1) {
    // Checked *before* the row is taken, not after. A table read at one instant
    // can still describe a loop if a pid was reused between rows, and a process
    // that is its own parent would otherwise be reported twice before the check
    // noticed — a duplicate line in an ancestry is not wrong enough to fail
    // anything and is exactly the kind of thing that survives for years.
    if (seen.has(at)) break
    seen.add(at)
    const row = table.get(at)
    if (!row) break
    out.push(row.args)
    // Stop at the init process. Nothing above it says anything about what git
    // was doing, and every ancestry on the machine ends the same way.
    if (row.ppid <= 1) break
    at = row.ppid
  }
  return out
}

/**
 * The real ancestry, from one `ps`.
 *
 * One call for the whole table rather than one per generation: eight sequential
 * `execFile`s on the path of every fetch is tens of milliseconds of latency for
 * a question that a single 60 KB read answers.
 *
 * Windows has no `ps` and gets an empty answer, which classifies as `write` and
 * prompts. That is the honest outcome and it is in the header; the alternative is
 * a `wmic` call on a platform nobody has watched this run on.
 */
export async function psAncestry(pid: number, platform: Platform = currentPlatform()): Promise<string[]> {
  if (isWindows(platform)) return []
  return new Promise((resolve) => {
    execFile('ps', ['-Ao', 'pid=,ppid=,args='], { maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
      if (error) {
        resolve([])
        return
      }
      resolve(ancestryFrom(parsePsTable(stdout), pid))
    })
  })
}

/* ------------------------------------------------------------------- desk -- */

export interface CredentialProxyOptions {
  /** Root of the per-device guest git directories. */
  dir: string
  /**
   * Reads a process's ancestry. Injected so tests never spawn `ps` — and so the
   * classification can be pinned from a machine that is not the one being
   * described.
   */
  ancestry?: (pid: number) => Promise<string[]>
  /** Fixed port, for tests. Zero, the default, takes whatever is free. */
  port?: number
  reachTimeoutMs?: number
  decideTimeoutMs?: number
  silentTimeoutMs?: number
  platform?: Platform
}

interface Grant {
  deviceId: string
  sessionId: string | null
}

interface Pending {
  id: string
  deviceId: string
  repoKey: string | null
  operation: CredentialOperation
  prompted: boolean
  acked: boolean
  timer: NodeJS.Timeout | null
  settle(outcome: CredentialOutcome): void
}

/**
 * A device and a repository, as one string.
 *
 * The host is in the key as well as the repository: `github.com/o/r` and an
 * enterprise host's `git.acme.co/o/r` are two different repositories that a
 * `owner/name` alone cannot tell apart, and an approval for one must not answer
 * for the other.
 */
function approvalKey(host: string, repo: string): string {
  return `${host.toLowerCase()}/${repo}`
}

export function createCredentialProxy(options: CredentialProxyOptions): CredentialProxy {
  const ancestry = options.ancestry ?? ((pid: number) => psAncestry(pid, options.platform))
  const reachMs = options.reachTimeoutMs ?? REACH_TIMEOUT_MS
  const decideMs = options.decideTimeoutMs ?? DECIDE_TIMEOUT_MS
  const silentMs = options.silentTimeoutMs ?? SILENT_TIMEOUT_MS

  /** Key → the device a session may ask on behalf of. */
  const grants = new Map<string, Grant>()
  /** Session id → key, so an exit can close the grant it was started with. */
  const bySession = new Map<string, string>()
  /** Request id → what is waiting on it. */
  const pending = new Map<string, Pending>()
  /** Device → repositories a person has approved, this run, in memory. */
  const approvals = new Map<string, Set<string>>()

  let post: DevicePost | null = null
  let endpoint: Server | null = null
  let url: string | null = null
  let stopped = false

  /* ---------------------------------------------------------- the desk -- */

  function settle(entry: Pending, outcome: CredentialOutcome): void {
    if (!pending.delete(entry.id)) return
    if (entry.timer) clearTimeout(entry.timer)
    entry.timer = null
    entry.settle(outcome)
  }

  function arm(entry: Pending, ms: number, message: string): void {
    if (entry.timer) clearTimeout(entry.timer)
    entry.timer = setTimeout(() => settle(entry, { ok: false, message }), ms)
    entry.timer.unref?.()
  }

  /** The sentence a person reads in their terminal when nothing answered. */
  function unreachable(operation: CredentialOperation): string {
    return operation === 'write'
      ? "Your device isn't reachable — open the app to approve this push."
      : "Your device isn't reachable — open the app there and try again."
  }

  function approvedFor(deviceId: string, key: string | null): boolean {
    if (key === null) return false
    return approvals.get(deviceId)?.has(key) === true
  }

  function approve(deviceId: string, key: string | null): void {
    if (key === null) return
    let set = approvals.get(deviceId)
    if (!set) {
      set = new Set()
      approvals.set(deviceId, set)
    }
    set.add(key)
    // Oldest out rather than newest refused; a cap that starts saying no would
    // read as the approval having failed to stick.
    while (set.size > MAX_APPROVALS_PER_DEVICE) {
      const oldest = set.values().next()
      if (oldest.done) break
      set.delete(oldest.value)
    }
  }

  function countFor(deviceId: string): number {
    let count = 0
    for (const entry of pending.values()) if (entry.deviceId === deviceId) count += 1
    return count
  }

  /**
   * Ask the device that owns this session, and wait.
   *
   * The order of the refusals is the design. Everything that can be answered
   * without troubling anybody is answered first — an unknown key, a request with
   * no host, a device that is not there — so the only requests that reach a
   * person's phone are the ones a person can actually do something about.
   */
  async function request(key: string, text: string, pid: number): Promise<CredentialOutcome> {
    const grant = grants.get(key)
    if (!grant || stopped) {
      return { ok: false, message: 'This session is not set up to use a GitHub account from your device.' }
    }

    const query = parseHelperRequest(text)
    if (query === null) {
      return { ok: false, message: 'That request did not say which host it needed a login for.' }
    }

    const operation = classifyOperation(await ancestry(pid))
    const repoKey = query.repo === null ? null : approvalKey(query.host, query.repo)
    // A repository nobody can name cannot be remembered either, so it prompts
    // every time. That is the honest behaviour of "approve always for this repo"
    // when there is no repo: there is nothing to attach the always to.
    const prompted = operation === 'write' && !approvedFor(grant.deviceId, repoKey)

    if (!post || !post.reachable(grant.deviceId)) {
      return { ok: false, message: unreachable(operation) }
    }
    if (pending.size >= MAX_PENDING || countFor(grant.deviceId) >= MAX_PENDING_PER_DEVICE) {
      return { ok: false, message: 'Too many logins are being asked for at once. Try again in a moment.' }
    }

    const id = randomUUID()
    return new Promise<CredentialOutcome>((resolve) => {
      const entry: Pending = {
        id,
        deviceId: grant.deviceId,
        repoKey,
        operation,
        prompted,
        acked: false,
        timer: null,
        settle: resolve,
      }
      pending.set(id, entry)

      const heard = post?.ask(grant.deviceId, {
        t: 'credential.request',
        id,
        host: query.host,
        repo: query.repo,
        operation,
        prompt: prompted,
      })
      if (!heard) {
        settle(entry, { ok: false, message: unreachable(operation) })
        return
      }
      // The reachability deadline, not the human one. What happens if this fires
      // is the sentence the whole feature is judged on — see REACH_TIMEOUT_MS.
      arm(entry, reachMs, unreachable(operation))
    })
  }

  /* -------------------------------------------------------- the endpoint -- */

  /**
   * Answer one helper.
   *
   * Everything a caller could get wrong is refused before the key is compared, so
   * a probe learns nothing from the shape of the failure — and the key itself is
   * compared in constant time, because the alternative is a loopback oracle for a
   * secret that grants a push.
   */
  async function serveRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (req.method !== 'POST') return refuse(res, 405, 'that is not how to ask')
    const path = (req.url ?? '/').split('?')[0]
    if (path !== CREDENTIAL_PATH) return refuse(res, 404, 'nothing here')
    // A page in a browser on this machine can be pointed at 127.0.0.1 by a
    // hostile site. It cannot guess a key, and refusing a rebound Host costs
    // nothing — the same argument `hook-server.ts` makes at more length.
    const hostHeader = (req.headers.host ?? '').replace(/:\d+$/, '')
    if (!LOOPBACK_HOSTS.has(hostHeader)) return refuse(res, 403, 'not for you')

    const key = header(req, CREDENTIAL_HEADER)
    const pid = Number(header(req, PID_HEADER))
    // A plain lookup, and no constant-time comparison anywhere near it. That is
    // a decision rather than an omission: the key is 256 bits from
    // `randomBytes`, so what a timing difference on a hash lookup could tell an
    // attacker is "that whole key exists", never how much of a guess was right —
    // and anything able to measure it is already running as this account, which
    // means it can read the key straight out of the session's environment. A
    // comparison written to look careful here would be protecting the wrong end
    // of the same secret.
    if (key === '' || !grants.has(key)) return refuse(res, 403, 'not for you')

    let body: string
    try {
      body = await readBody(req)
    } catch {
      return refuse(res, 413, 'that request was too large')
    }

    const outcome = await request(key, body, Number.isInteger(pid) && pid > 0 ? pid : 0)
    if (!outcome.ok) return answer(res, `!${outcome.message}`)
    const formatted = formatHelperAnswer(outcome.username, outcome.password)
    if (formatted === null) {
      // Unreachable through the parser, which refuses control characters in
      // either field. Kept because the failure it guards is a device writing an
      // extra directive into git's input, and "unreachable" is a claim about
      // today's callers.
      return answer(res, '!That answer was not usable.')
    }
    answer(res, formatted)
  }

  /**
   * Write a response, and never throw doing it.
   *
   * A push can wait a minute on a person, and in that minute the git holding the
   * other end of this socket can be Ctrl-C'd — which destroys the response before
   * anything is written to it. `writeHead` on that response throws, and a throw
   * out of the settled half of a promise chain is an unhandled rejection in the
   * process running every one of the user's terminals. Somebody pressing Ctrl-C
   * on their own push is not an event this app may die of.
   */
  function respond(res: ServerResponse, code: number, headers: Record<string, string>, body: string): void {
    if (res.writableEnded || res.destroyed) return
    try {
      // Headers already out means something answered and then threw. There is
      // nothing useful left to say, but the socket still has to be closed —
      // leaving it open would hold a git until the whole-request deadline, which
      // is measured in minutes because a person may be deciding.
      if (res.headersSent) {
        res.end()
        return
      }
      res.writeHead(code, headers)
      res.end(body.endsWith('\n') ? body : `${body}\n`)
    } catch {
      /* the far end went away mid-answer; there is nothing left to tell */
    }
  }

  function answer(res: ServerResponse, body: string): void {
    respond(res, 200, {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    }, body)
  }

  function refuse(res: ServerResponse, code: number, why: string): void {
    respond(res, code, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' }, why)
  }

  function header(req: IncomingMessage, name: string): string {
    const value = req.headers[name]
    return typeof value === 'string' ? value : ''
  }

  function readBody(req: IncomingMessage): Promise<string> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = []
      let bytes = 0
      req.on('data', (chunk: Buffer) => {
        bytes += chunk.length
        if (bytes > MAX_REQUEST_BYTES) {
          reject(new Error('too large'))
          req.destroy()
          return
        }
        chunks.push(chunk)
      })
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
      req.on('error', reject)
    })
  }

  /**
   * Bring the listener up, once, and never throw out of it.
   *
   * A machine that will not let this app bind a loopback port is a machine where
   * the proxy does not work; it is not a machine where sessions should refuse to
   * start. The failure surfaces as sessions with no `link`, which is half one on
   * its own — isolated git, no helper, a push refused in milliseconds.
   */
  const listening = new Promise<string | null>((resolve) => {
    const server = createServer((req, res) => {
      void serveRequest(req, res).catch((error) => {
        console.error('[credentials] a helper request failed:', redact(String(error)))
        // `refuse` cannot throw and checks for a response that has already gone
        // — which is the only case that reaches here after headers were sent, so
        // there is one path rather than two.
        refuse(res, 500, 'that did not work')
      })
    })
    // A push waits on a person, so the whole-request deadline has to outlast the
    // longest thing a person is allowed to take. Headers arrive from a curl on
    // this machine and are never slow.
    server.headersTimeout = 10_000
    server.requestTimeout = decideMs + reachMs + 30_000
    server.on('error', (error) => {
      console.error('[credentials] the credential endpoint could not start:', redact(String(error)))
      resolve(null)
    })
    server.listen(options.port ?? 0, HOST, () => {
      endpoint = server
      // `address()` answers `AddressInfo | string | null` — the string is for a
      // unix socket, which this never binds. Narrowed rather than cast: the two
      // checks together already leave the compiler with one shape.
      const address = server.address()
      const port = address !== null && typeof address === 'object' ? address.port : 0
      url = `http://${HOST}:${port}${CREDENTIAL_PATH}`
      resolve(url)
    })
    server.unref?.()
  })

  /* ---------------------------------------------------------- the seams -- */

  return {
    serve(next: DevicePost): void {
      post = next
    },

    handle(deviceId: string, message: CredentialMessage): void {
      const entry = pending.get(message.id)
      // An answer for a request that is not this device's is dropped in silence
      // rather than refused. It is either a race — the request timed out a
      // moment ago — or a device answering a question that was put to somebody
      // else, and the second one must not be able to learn that it guessed an id
      // that exists.
      if (!entry || entry.deviceId !== deviceId) return

      if (message.t === 'credential.ack') {
        if (entry.acked) return
        entry.acked = true
        // The device is there. Swap the reachability deadline for the one that
        // allows for a human, or a short one when nobody is being asked.
        arm(
          entry,
          entry.prompted ? decideMs : silentMs,
          entry.prompted
            ? 'Nobody answered on your device. Approve it there, then try again.'
            : 'Your device did not answer in time. Try again.',
        )
        return
      }

      if (message.t === 'credential.deny') {
        settle(entry, {
          ok: false,
          message:
            message.reason === 'no-account'
              ? 'No GitHub account is connected in the app on your device. Connect one there, then try again.'
              : entry.operation === 'write'
                ? 'That push was refused on your device.'
                : 'That request was refused on your device.',
        })
        return
      }

      // "Approve always" is honoured only for a request somebody was actually
      // asked about. A device that sets it on a silent fetch has not been given
      // consent to anything, and recording one would turn a read nobody saw into
      // a standing permission to push.
      if (message.remember === true && entry.prompted) approve(deviceId, entry.repoKey)
      settle(entry, { ok: true, username: message.username, password: message.password })
    },

    connectionClosed(deviceId: string): void {
      // Only when the last way to reach it has gone. A phone with a second socket
      // open, or one that reconnected before this ran, has not disappeared.
      if (post?.reachable(deviceId)) return
      for (const entry of [...pending.values()]) {
        if (entry.deviceId !== deviceId) continue
        settle(entry, { ok: false, message: unreachable(entry.operation) })
      }
    },

    forget(deviceId: string): void {
      approvals.delete(deviceId)
      for (const entry of [...pending.values()]) {
        if (entry.deviceId !== deviceId) continue
        settle(entry, { ok: false, message: 'That device is no longer allowed to answer here.' })
      }
      for (const [key, grant] of [...grants]) {
        if (grant.deviceId !== deviceId) continue
        grants.delete(key)
        if (grant.sessionId) bySession.delete(grant.sessionId)
      }
    },

    async openGuestSession(deviceId: string): Promise<GuestSession> {
      const where = await listening
      // 32 bytes, hex. It lives in one PTY's environment and nowhere else — not
      // in the helper on disk, not in a config file, not in a log.
      const key = randomBytes(32).toString('hex')
      grants.set(key, { deviceId, sessionId: null })

      const dir = guestGitDir(options.dir, deviceKey(deviceId))
      const link: CredentialLink | undefined = where
        ? { url: where, key, helper: join(options.dir, HELPER_FILE) }
        : undefined
      const env = prepareGuestGit({
        dir,
        ...(link ? { link } : {}),
        ...(options.platform ? { platform: options.platform } : {}),
      })

      return {
        env,
        started(sessionId: string): void {
          const grant = grants.get(key)
          if (!grant) return
          grant.sessionId = sessionId
          bySession.set(sessionId, key)
        },
        close(): void {
          const grant = grants.get(key)
          grants.delete(key)
          if (grant?.sessionId) bySession.delete(grant.sessionId)
        },
      }
    },

    sessionEnded(sessionId: string): void {
      const key = bySession.get(sessionId)
      if (key === undefined) return
      bySession.delete(sessionId)
      grants.delete(key)
    },

    address: () => url,

    async stop(): Promise<void> {
      stopped = true
      for (const entry of [...pending.values()]) {
        settle(entry, { ok: false, message: 'The app on this machine is shutting down.' })
      }
      grants.clear()
      bySession.clear()
      approvals.clear()
      // Awaited rather than read straight off `endpoint`: a stop that lands
      // while the listener is still binding would otherwise find nothing to
      // close and leave a socket open for the rest of the process's life.
      await listening
      const server = endpoint
      endpoint = null
      if (!server) return
      await new Promise<void>((done) => server.close(() => done()))
    },
  }
}

/**
 * A device id, folded into something safe to be a directory name.
 *
 * Device ids are base64url today and would be safe spelled out, which is exactly
 * why this is a hash rather than a `replace`: the next id format is not this
 * module's decision, and a path built from an identifier somebody else owns is a
 * path that eventually contains a separator. It also keeps the id itself out of a
 * directory listing, which is a small thing that costs nothing.
 */
export function deviceKey(deviceId: string): string {
  return createHash('sha256').update(deviceId).digest('hex').slice(0, 16)
}
