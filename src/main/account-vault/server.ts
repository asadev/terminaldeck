/**
 * The socket the `security` shim talks to — where a session's keychain lookup
 * is answered from the vault, for that session's own account and no other.
 *
 * ## Why a socket and not a file
 *
 * Because the alternative is a plaintext login on disk for as long as a session
 * runs. The agent asks for its credential on every request (it caches for
 * thirty seconds — `ASt=30000` in 2.1.287), so whatever answers has to be there
 * the whole time. A process answering from memory is the only shape where the
 * token exists in the clear in exactly two places: this process, and the agent
 * that asked.
 *
 * ## Tickets — what stops one session reading another account
 *
 * Every Claude Code session this app starts is handed one value in its
 * environment: a ticket, minted here for that launch alone — its *seat* (see
 * {@link Seat}). The shim sends it with every request, and the seat says which
 * account's login it is answered with. That is the whole of the isolation: a
 * session is only ever answered with the login its own seat names, so
 * switching one session's account — which retargets that one seat, in place,
 * without touching the process — cannot sign any other session in or out. A
 * request with no ticket, or one this run did not mint, is answered "not found"
 * for anything that is a login, and never with somebody's token.
 *
 * What a ticket does not try to be is a defence against the session itself. Any
 * process in that session can already ask for that account's credential — it is
 * the agent's own login, and the agent is the thing being served — exactly as
 * any process could ask the real keychain for the agent's item before this
 * existed. The line this draws is between accounts, not inside one.
 *
 * ## The answer is three lines of text
 *
 * `exit <code>`, then one line for stderr, then stdout. The shim is a `sh`
 * script and cannot assume `jq`; the open shim made the same choice for the same
 * reason. `pass` alone means "not ours — run the real command", and `capture`
 * means "run the real command and tell me what it printed" (see
 * {@link VaultServerDeps.adopting}).
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, unlinkSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { connect } from 'node:net'
import { userInfo } from 'node:os'
import { dirname } from 'node:path'
import type { ProviderId } from '../../shared/types'
import {
  directorySuffixes,
  EXIT_NOT_FOUND,
  keychainUser,
  NOT_FOUND_TEXT,
  readShimCall,
  serviceFor,
  type KeychainRequest,
  type ShimAnswer,
} from './keychain-requests'
import type { AccountVault } from './store'

/* -------------------------------------------------------------- tickets -- */

/**
 * One running process's place at the vault: which login its keychain lookups
 * are answered with, and which directory its keychain *names* come from.
 *
 * ## Why a seat is per launch and not per account
 *
 * Asad, 0.16.0: *"when we switch it, a new conversation comes… Session should
 * not be touched. Only account should be changing."* A per-account ticket can
 * only ever answer as the account it names, so changing account meant a new
 * ticket, which meant a new process. A seat separates the two things that were
 * welded together:
 *
 *  - **`launch` / `launchDir`** — fixed for the life of the process. The agent
 *    was started with that account's config directory, so every keychain name
 *    it asks for carries that directory's hash, for ever. That is what the
 *    nested-process check below is made against.
 *  - **`serving`** — which account's login is handed back. Changed in place by
 *    {@link TicketBook.retarget}: the process, its terminal and its
 *    conversation are untouched, and its next lookup gets the other login.
 *
 * ## Where a write goes
 *
 * To {@link Seat.lastServed}: the account whose login this process was last
 * handed. Claude Code saves a refreshed token as a compare-and-swap — it reads
 * the stored login fresh, under its own lock, and writes only if the refresh
 * token there is still the one it just spent (`WQn` in 2.1.287). That read is
 * answered from `serving`, so by the time a write arrives the read before it
 * has already said whose login it is about. Routing by `serving` instead would
 * be wrong for exactly one window — a switch landing between that read and its
 * write — and in that window it would put one account's new tokens into the
 * other's slot.
 */
export interface Seat {
  /** The account the process was started as. Never changes. */
  launch: string
  /**
   * The config directory the process was started with, whose hash is on every
   * keychain name it asks for; `null` for the machine's own install, whose
   * names carry no hash. `undefined` means "the launch account's own
   * directory", read through `configDirOf` when asked.
   */
  launchDir: string | null | undefined
  /**
   * The folder the process keeps its credential files in — its plaintext
   * fallback store, the file whose time makes it read its login again, its
   * refresh lock (`yb()` in Claude Code 2.1.287) — when that folder is this
   * app's own. Null when it is not (the folder is shared with the person's own
   * terminal `claude`), in which case nothing is ever written there.
   */
  storeDir: string | null
  /** The account whose login it is handed now. Null once that account is deleted. */
  serving: string | null
  /** The account whose login the most recent lookup was answered with. */
  lastServed: string | null
  /** The session the seat belongs to, once the session has an id. */
  sessionId: string | null
}

/**
 * The tickets this run has minted.
 *
 * Two kinds, one book:
 *
 *  - **A seat per session** ({@link seat}): minted for one launch, bound to
 *    the session's id once it has one, retargeted by an account switch,
 *    released when the process ends.
 *  - **A ticket per account** ({@link ticketFor}): for the short-lived probes
 *    `sessionEnv` starts (sign-in checks, usage reads), which are asked for the
 *    environment more than once on the way to one spawn and must not hand one
 *    process two answers. It is a seat too — launched as and serving that
 *    account — and is never retargeted.
 */
export class TicketBook {
  private readonly seats = new Map<string, Seat>()
  private readonly byAccount = new Map<string, string>()
  private readonly bySession = new Map<string, string>()

  private mint(seat: Seat): string {
    const ticket = randomBytes(24).toString('hex')
    this.seats.set(ticket, seat)
    return ticket
  }

  /** This account's own ticket, minted the first time it is asked for. */
  ticketFor(accountId: string): string {
    const held = this.byAccount.get(accountId)
    if (held !== undefined && this.seats.has(held)) return held
    const ticket = this.mint({
      launch: accountId,
      launchDir: undefined,
      storeDir: null,
      serving: accountId,
      lastServed: accountId,
      sessionId: null,
    })
    this.byAccount.set(accountId, ticket)
    return ticket
  }

  /** A seat for one launch: started as `launch`, naming its keychain items after `launchDir`, served as `serving`. */
  seat(launch: string, launchDir: string | null, serving: string = launch, storeDir: string | null = null): string {
    return this.mint({ launch, launchDir, storeDir, serving, lastServed: serving, sessionId: null })
  }

  /** Tie a seat to the session it was minted for. A per-account ticket is never tied. */
  bind(ticket: string, sessionId: string): boolean {
    const seat = this.seats.get(ticket)
    if (seat === undefined || this.byAccount.get(seat.launch) === ticket) return false
    seat.sessionId = sessionId
    this.bySession.set(sessionId, ticket)
    return true
  }

  /**
   * The seat a ticket names, or null.
   *
   * Compared in constant time against the one candidate it could be, so a
   * process probing the socket learns nothing from how long a wrong guess took.
   */
  seatOf(ticket: string): Seat | null {
    if (typeof ticket !== 'string' || !/^[0-9a-f]{48}$/.test(ticket)) return null
    for (const [candidate, seat] of this.seats) {
      const a = Buffer.from(ticket)
      const b = Buffer.from(candidate)
      if (a.length === b.length && timingSafeEqual(a, b)) return seat
    }
    return null
  }

  /** Which account a ticket is answered as now, or null. */
  accountFor(ticket: string): string | null {
    return this.seatOf(ticket)?.serving ?? null
  }

  /** The seat of a running session, or null when it has none. */
  sessionSeat(sessionId: string): Readonly<Seat> | null {
    const ticket = this.bySession.get(sessionId)
    return ticket === undefined ? null : (this.seats.get(ticket) ?? null)
  }

  /** Serve this session as another account from its next lookup on. */
  retarget(sessionId: string, accountId: string): boolean {
    const ticket = this.bySession.get(sessionId)
    const seat = ticket === undefined ? undefined : this.seats.get(ticket)
    if (seat === undefined) return false
    seat.serving = accountId
    return true
  }

  /** Record which account a lookup on this ticket was answered with. */
  noteServed(ticket: string, accountId: string): void {
    const seat = this.seats.get(ticket)
    if (seat !== undefined) seat.lastServed = accountId
  }

  /** The process has ended: nothing will ask on its seat again. */
  release(sessionId: string): void {
    const ticket = this.bySession.get(sessionId)
    if (ticket === undefined) return
    this.bySession.delete(sessionId)
    this.seats.delete(ticket)
  }

  /**
   * Stop answering for this account. Called when it is deleted, so a session
   * still running as it gets "not found" rather than a login that no longer
   * exists — and a session merely *started* as it keeps its seat, because what
   * it is served is whatever it was switched to.
   */
  revoke(accountId: string): void {
    const ticket = this.byAccount.get(accountId)
    if (ticket !== undefined) this.seats.delete(ticket)
    this.byAccount.delete(accountId)
    for (const seat of this.seats.values()) {
      if (seat.serving === accountId) seat.serving = null
      if (seat.lastServed === accountId) seat.lastServed = null
    }
  }
}

/* --------------------------------------------------------------- answers -- */

/**
 * Where an account's login is handed out from when a seat serves it.
 *
 *  - `vault`     this app keeps it (or is moving it in): answered from the vault.
 *  - `keychain`  the agent keeps it, in the keychain item it names after `dir`
 *                (`null`: the machine's own install, the login a person's own
 *                terminal uses). Read and written there, by the real `security`,
 *                never copied into the vault — taking the machine's own login
 *                into the app would leave the terminal holding a token the app
 *                had refreshed out from under it.
 */
export type LoginSource = { kind: 'vault' } | { kind: 'keychain'; dir: string | null }

export interface VaultServerDeps {
  vault: AccountVault
  tickets: TicketBook
  /** Which agent an account belongs to, or null when it no longer exists. */
  providerOf(accountId: string): ProviderId | null
  /**
   * The account's own config directory, whose hash every lookup must carry.
   * See `keychain-requests.ts` — this is what stops a nested process with some
   * other directory, holding an inherited ticket, being answered as this one.
   */
  configDirOf(accountId: string): string | null
  /**
   * True while this slot of this account still lives where the agent kept it
   * before the app kept logins — an account made before this release, and a
   * slot of it nothing has settled yet.
   *
   * Per slot, not per account: an account has two keychain items (the login and
   * the API key), and settling one must not strand the other in the keychain.
   *
   * For such a slot a lookup is answered `capture`: the shim runs the agent's
   * own command against the real keychain exactly as it would have run without
   * this app, and hands back what it printed. That is the whole migration — no
   * prompt, because it is the same command from the same binary that has always
   * read that item, and no second sign-in. A sign-out is handed to the real
   * command too, so the item really goes. Whatever happens first — a capture, a
   * "not found", a write, a sign-out — settles the slot for good
   * ({@link markKept}), so an item left in the keychain afterwards is never
   * read again.
   */
  adopting(accountId: string, slot: string): boolean
  /** Record that this slot of this account now lives here. Persisted by the caller. */
  markKept(accountId: string, slot: string): void
  /**
   * Where an account's login is served from. Absent, every account is the
   * vault's — the shape before a session could be switched in place.
   */
  sourceOf?(accountId: string): LoginSource | null
  /**
   * Run the real `security` with these arguments and this stdin, for a lookup
   * this app makes on a seat's behalf under a name the agent did not ask for
   * (see {@link KeychainStep}). Absent, nothing is ever run from here.
   */
  runReal?(argv: readonly string[], stdin: string | null): Promise<ShimAnswer>
  /** Told when an agent signs an account in, refreshes it, or signs it out. */
  onCapture?(event: { accountId: string; slot: string; kind: 'sign-in' | 'refresh' | 'adopted' | 'signed-out' }): void
  /**
   * Told when a seat is first handed a different account's login than the one
   * it was handed last — the moment a switch made in place has taken.
   */
  onServed?(event: { sessionId: string | null; accountId: string }): void
}

/** A request body: ticket, argc, the argv, then everything after as stdin. */
export function readBody(body: Buffer): { ticket: string; argv: string[]; rest: string } | null {
  const parts = body.toString('utf8').split('\0')
  if (parts.length < 2) return null
  const ticket = parts[0] ?? ''
  const argc = Number.parseInt(parts[1] ?? '', 10)
  if (!Number.isInteger(argc) || argc < 0 || argc > 64 || parts.length < 2 + argc) return null
  const argv = parts.slice(2, 2 + argc)
  const rest = parts.slice(2 + argc).join('\0')
  return { ticket, argv, rest }
}

/** The attribute listing `find-generic-password` prints without `-w`. */
function attributes(slot: string): string {
  const service = slot.replace(/^keychain:/, '')
  return [
    'keychain: "vault"',
    'class: "genp"',
    'attributes:',
    `    "svce"<blob>="${service}"`,
  ].join('\n')
}

function notFound(): ShimAnswer {
  return { code: EXIT_NOT_FOUND, stdout: '', stderr: NOT_FOUND_TEXT }
}

/**
 * Answer one request for one account.
 *
 * `add` records whether it was a first login or a refresh by whether anything
 * was held, because that is the distinction a person can see: "signed in" and
 * "kept up to date" are different sentences on the Accounts screen.
 */
function answerOne(
  request: KeychainRequest,
  accountId: string,
  provider: ProviderId,
  deps: VaultServerDeps,
): ShimAnswer {
  if (request.op === 'locked?') {
    // Never locked: the vault answers whatever state the login keychain is in,
    // and a "locked" here would make the agent skip a write the vault can take.
    return { code: 0, stdout: '', stderr: '' }
  }
  if (request.op === 'find') {
    const value = deps.vault.read(accountId, request.slot)
    if (value === null) return notFound()
    return { code: 0, stdout: request.wantsPassword ? value : attributes(request.slot), stderr: '' }
  }
  if (request.op === 'add') {
    const held = deps.vault.read(accountId, request.slot) !== null
    const kind = held ? 'refresh' : 'sign-in'
    const written = deps.vault.put(accountId, provider, request.slot, request.value, kind)
    if (!written.ok) {
      // Not the keychain's "locked" code: that one makes the agent hold the new
      // token in memory only and try again later, which is right for a locked
      // keychain and wrong for a disk that refused — the token would be lost
      // at the next restart with nothing said. A plain failure lets the agent
      // fall back to its own file, which is the behaviour it has without us.
      return { code: 1, stdout: '', stderr: `security: ${written.message}` }
    }
    deps.markKept(accountId, request.slot)
    if (written.changed) deps.onCapture?.({ accountId, slot: request.slot, kind })
    return { code: 0, stdout: '', stderr: '' }
  }
  // delete — a sign-out, or the agent giving up on a login it could not
  // refresh. Either way the account is signed out, here as everywhere, and the
  // slot is settled: an empty slot is an answer, and it must stay the answer.
  const held = deps.vault.read(accountId, request.slot) !== null
  deps.markKept(accountId, request.slot)
  if (!held) return notFound()
  const dropped = deps.vault.drop(accountId, request.slot)
  if (!dropped.ok) return { code: 1, stdout: '', stderr: `security: ${dropped.message}` }
  deps.onCapture?.({ accountId, slot: request.slot, kind: 'signed-out' })
  return { code: 0, stdout: '', stderr: '' }
}

/** `sha256` as hex, the hash the CLI names a keychain item with. */
function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex')
}

/**
 * The directory hashes a seat's own lookups carry. `null` in the set is the
 * unsuffixed name of the machine's own install — the only way a seat started
 * on it asks.
 */
function ownSuffixes(seat: Seat, deps: VaultServerDeps): ReadonlySet<string | null> {
  if (seat.launchDir === null) return new Set([null])
  const dir = seat.launchDir ?? deps.configDirOf(seat.launch)
  return dir === null ? new Set() : directorySuffixes(dir, sha256)
}

/**
 * The folder whose hash is on a seat's own keychain names (`null`: no hash),
 * or `undefined` when it cannot be known.
 */
function seatNaming(seat: Seat, deps: VaultServerDeps): string | null | undefined {
  if (seat.launchDir !== undefined) return seat.launchDir
  return deps.configDirOf(seat.launch) ?? undefined
}

/** The folder whose hash is on an account's own keychain items, or `undefined` when unknown. */
function accountNaming(account: string, source: LoginSource | null, deps: VaultServerDeps): string | null | undefined {
  if (source === null) return undefined
  if (source.kind === 'keychain') return source.dir
  return deps.configDirOf(account) ?? undefined
}

/** Two namings the CLI would hash the same — both absent, or the same folder. */
function sameNaming(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a === undefined || b === undefined) return false
  if (a === null || b === null) return a === b
  return a.normalize('NFC') === b.normalize('NFC')
}

/**
 * Does this request carry the seat's own directory hash?
 *
 * `locked?` names no service and is always the seat's to answer. Anything else
 * must carry the hash the CLI derives from the directory the process was
 * started with; anything else is a different agent install asking.
 */
function carriesOwnHash(request: KeychainRequest, own: ReadonlySet<string | null>): boolean {
  if (request.op === 'locked?') return true
  return own.has(request.suffix)
}

/**
 * One lookup this app makes against the real keychain on a seat's behalf,
 * under the name of the account being served rather than the name the agent
 * asked for — the agent's directory is fixed at launch, its login is not.
 *
 * `adopt` is the move-in of an account made before the vault, for a seat that
 * was switched to it: what the read finds is kept, exactly as `capture` keeps
 * it for a session started on that account.
 */
export interface KeychainStep {
  via: 'keychain'
  account: string
  request: Exclude<KeychainRequest, { op: 'locked?' }>
  service: string
  adopt: boolean
}

/** A request the vault answers, run in its place among keychain steps. */
export interface VaultStep {
  via: 'vault'
  account: string
  request: KeychainRequest
}

/**
 * The wire answer: `pass`, `capture`, `exit <code>` + stderr + stdout — or
 * `steps`, which never reaches the wire: the socket runs them (some against the
 * real keychain, see {@link KeychainStep}) and sends the result as an `exit`.
 */
export type WireAnswer =
  | { kind: 'pass' }
  | { kind: 'capture' }
  | { kind: 'exit'; answer: ShimAnswer }
  | { kind: 'steps'; ticket: string; steps: Array<KeychainStep | VaultStep> }

/** Where a login is served from, defaulting to the vault. */
function sourceFor(accountId: string, deps: VaultServerDeps): LoginSource | null {
  return deps.sourceOf ? deps.sourceOf(accountId) : { kind: 'vault' }
}

/** Record whose login a lookup was answered with, and say so when it changed. */
function served(ticket: string, seat: Seat, accountId: string, deps: VaultServerDeps): void {
  const before = seat.lastServed
  deps.tickets.noteServed(ticket, accountId)
  if (before !== accountId) deps.onServed?.({ sessionId: seat.sessionId, accountId })
}

/**
 * Everything the socket decides, as a pure function of the body and the deps,
 * so the whole contract can be tested without a socket.
 */
export function answerShim(body: Buffer, deps: VaultServerDeps): WireAnswer {
  const read = readBody(body)
  if (read === null) return { kind: 'pass' }
  const call = readShimCall(read.argv, read.rest)
  if (call.kind === 'pass') return { kind: 'pass' }

  const seat = deps.tickets.seatOf(read.ticket)
  const serving = seat?.serving ?? null
  const provider = serving === null ? null : deps.providerOf(serving)
  // A login lookup with a ticket this run did not mint, or for an account that
  // has been deleted: "not found", never somebody else's token, and never the
  // real keychain — passing it through would read whatever the agent's
  // directory hash happens to name, which is the path-bound store this whole
  // module exists to stop depending on.
  if (seat === null || serving === null || provider === null) {
    const locked = call.requests.every((request) => request.op === 'locked?')
    return { kind: 'exit', answer: locked ? { code: 0, stdout: '', stderr: '' } : notFound() }
  }

  /*
   * Somebody else's lookup, carrying this seat's ticket.
   *
   * The ticket is inherited by everything the session runs, so a nested agent
   * with its own `CLAUDE_CONFIG_DIR` — or none, which is the machine's own
   * install — arrives here holding it. Its keychain item is named after *its*
   * directory, so it goes to the real `security`, untouched, as if this app
   * were not here: never answered from this seat's login, and never able to
   * overwrite or delete it.
   */
  if (!call.requests.every((request) => carriesOwnHash(request, ownSuffixes(seat, deps)))) return { kind: 'pass' }

  /*
   * Which account each request is about. A lookup is answered as the account
   * being served; a write or a sign-out goes to the account whose login the
   * process last read — see `Seat` for why that is not the same thing for one
   * short window around a switch.
   */
  const accountOf = (request: KeychainRequest): string =>
    request.op === 'find' ? serving : (seat.lastServed ?? serving)
  /*
   * The real command, untouched, can only answer for an account whose own
   * keychain item is the name the process asks under — the account it was
   * started as, kept by the agent, *and* started without its credential folder
   * moved (a session on the Mac's own login is started with that folder in this
   * app's data, see `seatLaunch`, so its names carry that folder's hash and are
   * rewritten to the real item instead).
   */
  const ownNames = (account: string): boolean => {
    const source = sourceFor(account, deps)
    return sameNaming(seatNaming(seat, deps), accountNaming(account, source, deps))
  }
  const launchKeychain = (account: string): boolean =>
    account === seat.launch && sourceFor(account, deps)?.kind === 'keychain' && ownNames(account)

  /*
   * The agent's own login, on the seat it was started on: the real command,
   * untouched, exactly as if this app were not there. Every session started on
   * a login the agent keeps runs through here until it is switched.
   */
  if (
    call.requests.every((request) =>
      request.op === 'locked?' ? launchKeychain(serving) : launchKeychain(accountOf(request)),
    )
  ) {
    if (call.requests.some((request) => request.op === 'find')) served(read.ticket, seat, serving, deps)
    return { kind: 'pass' }
  }

  /*
   * A slot still on its pre-vault login, on the seat started as that account.
   * Two cases, and nothing else is let through to the keychain:
   *
   *  - a lookup of something the vault does not hold: the agent reads it once,
   *    the way it always has, and what it reads is kept (`capture`). Only for a
   *    lookup on the command line — `acceptCapture` is handed the argv and the
   *    output, not stdin, so an interactive-mode lookup could never be kept and
   *    would pass through for ever; it is passed as what it is instead.
   *  - a sign-out of something the vault does not hold: the agent is deleting
   *    the item it has, so the real command deletes it, and the slot is settled
   *    so the next lookup cannot read the login back.
   *
   * A write is the agent saying what the login is now, and is taken as it comes.
   */
  const only = call.requests.length === 1 ? call.requests[0] : undefined
  if (
    only !== undefined &&
    only.op !== 'locked?' &&
    only.op !== 'add' &&
    accountOf(only) === seat.launch &&
    ownNames(seat.launch) &&
    deps.adopting(seat.launch, only.slot) &&
    deps.vault.read(seat.launch, only.slot) === null
  ) {
    if (only.op === 'delete') {
      deps.markKept(seat.launch, only.slot)
      return { kind: 'pass' }
    }
    served(read.ticket, seat, seat.launch, deps)
    const interactive = read.argv.length === 1 && read.argv[0] === '-i'
    return only.wantsPassword && !interactive ? { kind: 'capture' } : { kind: 'pass' }
  }

  /*
   * The steps: each request answered from wherever its account's login lives.
   * When the vault answers every one of them, they are answered right here and
   * the socket never runs anything.
   */
  const steps: Array<KeychainStep | VaultStep> = []
  for (const request of call.requests) {
    if (request.op === 'locked?') {
      steps.push({ via: 'vault', account: serving, request })
      continue
    }
    const account = accountOf(request)
    const source = sourceFor(account, deps)
    if (source === null) {
      // An account this process cannot serve right now (its kept login is out
      // of reach): "not found" for a lookup, a refusal for a write. Never the
      // keychain, for the reason the ticket check above gives.
      return {
        kind: 'exit',
        answer:
          request.op === 'find'
            ? notFound()
            : { code: 1, stdout: '', stderr: 'security: the app that keeps this login cannot reach it right now.' },
      }
    }
    if (source.kind === 'keychain') {
      steps.push({ via: 'keychain', account, request, service: serviceFor(request.slot, source.dir, sha256), adopt: false })
      continue
    }
    // The vault's — unless it is an account made before the vault, still on its
    // old keychain item, and this seat was switched to it: then that item is
    // read once (or deleted, for a sign-out) and the slot settled, the same
    // move `capture` makes for a session started on it.
    if (
      request.op !== 'add' &&
      !(account === seat.launch && ownNames(account)) &&
      deps.adopting(account, request.slot) &&
      deps.vault.read(account, request.slot) === null
    ) {
      const dir = deps.configDirOf(account)
      if (dir !== null) {
        steps.push({ via: 'keychain', account, request, service: serviceFor(request.slot, dir, sha256), adopt: true })
        continue
      }
    }
    steps.push({ via: 'vault', account, request })
  }

  if (steps.some((step) => step.via === 'keychain')) return { kind: 'steps', ticket: read.ticket, steps }

  let last: ShimAnswer = { code: 0, stdout: '', stderr: '' }
  const out: string[] = []
  for (const step of steps) {
    const stepProvider = deps.providerOf(step.account) ?? provider
    last = answerOne(step.request, step.account, stepProvider, deps)
    if (step.request.op === 'find') served(read.ticket, seat, step.account, deps)
    if (last.stdout !== '') out.push(last.stdout)
  }
  return { kind: 'exit', answer: { code: last.code, stdout: out.join('\n'), stderr: last.stderr } }
}

/** The argv and stdin for one keychain step, the same commands the CLI itself runs. */
export function keychainCommand(step: KeychainStep, user: string): { argv: string[]; stdin: string | null } {
  const { request, service } = step
  if (request.op === 'find') {
    return {
      argv: ['find-generic-password', '-a', user, ...(request.wantsPassword ? ['-w'] : []), '-s', service],
      stdin: null,
    }
  }
  if (request.op === 'delete') return { argv: ['delete-generic-password', '-a', user, '-s', service], stdin: null }
  // A write goes over stdin in interactive mode, never on a command line, for
  // the reason the CLI does it that way: argv is visible to every process.
  const hexValue = Buffer.from(request.value, 'utf8').toString('hex')
  return { argv: ['-i'], stdin: `add-generic-password -U -a "${user}" -s "${service}" -X "${hexValue}"\n` }
}

/**
 * Run a `steps` answer: each keychain step through the real `security`, each
 * vault step from the vault, in order, and the last one's result as the answer.
 */
export async function runSteps(
  answer: Extract<WireAnswer, { kind: 'steps' }>,
  deps: VaultServerDeps,
  user: string,
): Promise<ShimAnswer> {
  const seat = deps.tickets.seatOf(answer.ticket)
  let last: ShimAnswer = { code: 0, stdout: '', stderr: '' }
  const out: string[] = []
  for (const step of answer.steps) {
    if (step.via === 'vault') {
      const provider = deps.providerOf(step.account)
      if (provider === null) return notFound()
      last = answerOne(step.request, step.account, provider, deps)
    } else {
      if (deps.runReal === undefined) {
        return step.request.op === 'find' ? notFound() : { code: 1, stdout: '', stderr: 'security: nothing here can reach the keychain.' }
      }
      const { argv, stdin } = keychainCommand(step, user)
      last = await deps.runReal(argv, stdin)
      if (step.adopt) {
        const provider = deps.providerOf(step.account)
        const value = last.stdout.trim()
        if (step.request.op === 'find' && step.request.wantsPassword && last.code === 0 && value !== '' && provider !== null) {
          const written = deps.vault.put(step.account, provider, step.request.slot, value, 'adopted')
          if (written.ok) {
            deps.markKept(step.account, step.request.slot)
            deps.onCapture?.({ accountId: step.account, slot: step.request.slot, kind: 'adopted' })
          }
        } else if (last.code === EXIT_NOT_FOUND || step.request.op === 'delete') {
          deps.markKept(step.account, step.request.slot)
        }
      }
    }
    if (step.request.op === 'find' && seat !== null) served(answer.ticket, seat, step.account, deps)
    if (last.stdout !== '') out.push(last.stdout.replace(/\n$/, ''))
  }
  return { code: last.code, stdout: out.join('\n'), stderr: last.stderr }
}

/**
 * What the shim reports after running the real command for a `capture`.
 *
 * Body: ticket, the real command's exit code, argc, argv, then its stdout. Kept
 * only when the command succeeded and printed something — a "not found" from the
 * real keychain is an account that was never signed in there, and the next
 * sign-in will land in the vault directly.
 */
export function acceptCapture(body: Buffer, deps: VaultServerDeps): boolean {
  const parts = body.toString('utf8').split('\0')
  if (parts.length < 3) return false
  const [ticket = '', codeText = '', ...rest] = parts
  const read = readBody(Buffer.from([ticket, ...rest].join('\0'), 'utf8'))
  if (read === null) return false
  const seat = deps.tickets.seatOf(read.ticket)
  // Only on the seat started as the account: the real command read the item
  // named after the launch directory, which is that account's and nobody else's.
  if (seat === null || seat.serving === null || seat.serving !== seat.launch) return false
  if (!sameNaming(seatNaming(seat, deps), deps.configDirOf(seat.launch) ?? undefined)) return false
  const accountId = seat.launch
  const provider = deps.providerOf(accountId)
  if (provider === null) return false
  const call = readShimCall(read.argv, '')
  if (call.kind !== 'ours' || call.requests.length !== 1) return false
  const request = call.requests[0]
  if (request?.op !== 'find' || !request.wantsPassword) return false
  if (!deps.adopting(accountId, request.slot)) return false
  if (!carriesOwnHash(request, ownSuffixes(seat, deps))) return false
  /*
   * "Not found" in the real keychain settles the slot too: there was nothing
   * there to move, and the next sign-in lands in the vault directly. Any other
   * failure — 36, the keychain is locked — settles nothing, so the next lookup
   * tries again.
   */
  if (codeText === String(EXIT_NOT_FOUND)) {
    deps.markKept(accountId, request.slot)
    return true
  }
  if (codeText !== '0') return false
  const value = read.rest.trim()
  if (value === '') return false
  const written = deps.vault.put(accountId, provider, request.slot, value, 'adopted')
  if (!written.ok) return false
  deps.markKept(accountId, request.slot)
  deps.onCapture?.({ accountId, slot: request.slot, kind: 'adopted' })
  return true
}

/** The text the shim reads. A `steps` answer is run first; see `startVaultSocket`. */
export function wireText(answer: Exclude<WireAnswer, { kind: 'steps' }>): string {
  if (answer.kind === 'pass') return 'pass\n'
  if (answer.kind === 'capture') return 'capture\n'
  const stderr = answer.answer.stderr.replace(/[\r\n]+/g, ' ')
  return `exit ${answer.answer.code}\n${stderr}\n${answer.answer.stdout}`
}

/* ---------------------------------------------------------------- serving -- */

/** A login fits in this many times over. A body larger than it is not ours. */
const MAX_BODY_BYTES = 512 * 1024

function readRequest(req: IncomingMessage): Promise<Buffer | null> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = []
    let size = 0
    let done = false
    req.on('data', (chunk: Buffer) => {
      if (done) return
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        done = true
        resolve(null)
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      if (done) return
      done = true
      resolve(Buffer.concat(chunks))
    })
    req.on('error', () => {
      if (done) return
      done = true
      resolve(null)
    })
  })
}

function reply(res: ServerResponse, status: number, text: string): void {
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' })
  res.end(text)
}

/** Does something already answer on this path? */
function socketAnswers(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = connect(path)
    const finish = (answer: boolean): void => {
      probe.destroy()
      resolve(answer)
    }
    probe.once('connect', () => finish(true))
    probe.once('error', () => finish(false))
    setTimeout(() => finish(false), 500).unref()
  })
}

export interface VaultSocket {
  path: string
  close(): Promise<void>
}

/**
 * Listen on `path`, owner-only, and answer the shim.
 *
 * A socket that is already being served is refused rather than taken over: two
 * copies of this app with the same data folder would otherwise answer each
 * other's sessions, and `requestSingleInstanceLock` already says that cannot
 * happen — so if it has, the second copy runs without a vault rather than
 * guessing. A stale file left by a crash is removed.
 */
export async function startVaultSocket(path: string, deps: VaultServerDeps): Promise<VaultSocket> {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  chmodSync(dirname(path), 0o700)
  if (existsSync(path)) {
    if (await socketAnswers(path)) {
      throw new Error(`account vault: ${path} is already being served by another copy of this app`)
    }
    unlinkSync(path)
  }

  const server: Server = createServer((req, res) => {
    void (async () => {
      if (req.method !== 'POST') return reply(res, 405, 'pass\n')
      const body = await readRequest(req)
      if (body === null) return reply(res, 413, 'pass\n')
      try {
        if (req.url === '/keychain') {
          const answer = answerShim(body, deps)
          if (answer.kind !== 'steps') return reply(res, 200, wireText(answer))
          const ran = await runSteps(answer, deps, keychainUser(process.env, () => userInfo().username))
          return reply(res, 200, wireText({ kind: 'exit', answer: ran }))
        }
        if (req.url === '/keychain/captured') {
          return reply(res, 200, acceptCapture(body, deps) ? 'ok\n' : 'no\n')
        }
        return reply(res, 404, 'pass\n')
      } catch {
        // Never a stack trace down a socket a session can read. "Not found" is
        // the safe answer for anything that was about a login.
        return reply(res, 200, wireText({ kind: 'exit', answer: notFound() }))
      }
    })()
  })
  server.headersTimeout = 5_000
  server.requestTimeout = 10_000

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(path, () => {
      server.off('error', reject)
      resolve()
    })
  })
  chmodSync(path, 0o600)

  return {
    path,
    close: () =>
      new Promise<void>((resolve) => {
        // A shim mid-request must not hold the app's quit open: it falls closed
        // on its own ("not found") when the answer does not come.
        server.closeAllConnections()
        server.close(() => {
          try {
            unlinkSync(path)
          } catch {
            // Already gone.
          }
          resolve()
        })
      }),
  }
}
