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
 * Every session started as an account this app keeps is handed one value in its
 * environment: a ticket, minted here per account per run. The shim sends it
 * with every request, and the ticket names the account. That is the whole of
 * the isolation, and it is deliberately simple: a session can only ever be
 * answered with the login it was started as, so switching one session's account
 * — which restarts it with a different ticket — cannot sign any other session
 * in or out. A request with no ticket, or one this run did not mint, is
 * answered "not found" for anything that is a login, and never with somebody's
 * token.
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

import { randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, unlinkSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { connect } from 'node:net'
import { dirname } from 'node:path'
import type { ProviderId } from '../../shared/types'
import {
  EXIT_NOT_FOUND,
  NOT_FOUND_TEXT,
  readShimCall,
  type KeychainRequest,
  type ShimAnswer,
} from './keychain-requests'
import type { AccountVault } from './store'

/* -------------------------------------------------------------- tickets -- */

/**
 * The tickets this run has minted, one per account.
 *
 * One per account rather than one per session because `sessionEnv` is asked for
 * the environment more than once on the way to a single spawn (the WSL bridge
 * asks for its keys), and a mint per call would hand one process two answers.
 * Per account is also exactly the isolation that matters — see the header.
 */
export class TicketBook {
  private readonly byTicket = new Map<string, string>()
  private readonly byAccount = new Map<string, string>()

  /** This account's ticket, minted the first time it is asked for. */
  ticketFor(accountId: string): string {
    const held = this.byAccount.get(accountId)
    if (held !== undefined) return held
    const ticket = randomBytes(24).toString('hex')
    this.byAccount.set(accountId, ticket)
    this.byTicket.set(ticket, accountId)
    return ticket
  }

  /**
   * Which account a ticket names, or null.
   *
   * Compared in constant time against the one candidate it could be, so a
   * process probing the socket learns nothing from how long a wrong guess took.
   */
  accountFor(ticket: string): string | null {
    if (typeof ticket !== 'string' || !/^[0-9a-f]{48}$/.test(ticket)) return null
    const accountId = this.byTicket.get(ticket)
    if (accountId === undefined) return null
    const expected = this.byAccount.get(accountId)
    if (expected === undefined) return null
    const a = Buffer.from(ticket)
    const b = Buffer.from(expected)
    return a.length === b.length && timingSafeEqual(a, b) ? accountId : null
  }

  /**
   * Stop answering for this account. Called when it is deleted, so a session
   * still running as it — there should be none, but a delete does not wait for
   * one — gets "not found" rather than a login that no longer exists.
   */
  revoke(accountId: string): void {
    const ticket = this.byAccount.get(accountId)
    if (ticket !== undefined) this.byTicket.delete(ticket)
    this.byAccount.delete(accountId)
  }
}

/* --------------------------------------------------------------- answers -- */

export interface VaultServerDeps {
  vault: AccountVault
  tickets: TicketBook
  /** Which agent an account belongs to, or null when it no longer exists. */
  providerOf(accountId: string): ProviderId | null
  /**
   * True while this account still has its login where the agent kept it before
   * the app kept logins — an account made before this release.
   *
   * For those, and only until something is kept, a lookup is answered
   * `capture`: the shim runs the agent's own command against the real keychain
   * exactly as it would have run without this app, and hands back what it
   * printed. That is the whole migration — no prompt, because it is the same
   * command from the same binary that has always read that item, and no second
   * sign-in. The first answer captured, or the first write, ends it for good
   * ({@link markKept}), so an item left in the keychain afterwards is never read
   * again.
   */
  adopting(accountId: string): boolean
  /** Record that this account's login is now kept here. Persisted by the caller. */
  markKept(accountId: string): void
  /** Told when an agent signs an account in, refreshes it, or signs it out. */
  onCapture?(event: { accountId: string; slot: string; kind: 'sign-in' | 'refresh' | 'adopted' | 'signed-out' }): void
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
    deps.markKept(accountId)
    if (written.changed) deps.onCapture?.({ accountId, slot: request.slot, kind })
    return { code: 0, stdout: '', stderr: '' }
  }
  // delete — a sign-out, or the agent giving up on a login it could not
  // refresh. Either way the account is signed out, here as everywhere.
  const held = deps.vault.read(accountId, request.slot) !== null
  if (!held) return notFound()
  deps.vault.drop(accountId, request.slot)
  deps.markKept(accountId)
  deps.onCapture?.({ accountId, slot: request.slot, kind: 'signed-out' })
  return { code: 0, stdout: '', stderr: '' }
}

/** The wire answer: `pass`, `capture`, or `exit <code>` + stderr + stdout. */
export type WireAnswer = { kind: 'pass' } | { kind: 'capture' } | { kind: 'exit'; answer: ShimAnswer }

/**
 * Everything the socket decides, as a pure function of the body and the deps,
 * so the whole contract can be tested without a socket.
 */
export function answerShim(body: Buffer, deps: VaultServerDeps): WireAnswer {
  const read = readBody(body)
  if (read === null) return { kind: 'pass' }
  const call = readShimCall(read.argv, read.rest)
  if (call.kind === 'pass') return { kind: 'pass' }

  const accountId = deps.tickets.accountFor(read.ticket)
  const provider = accountId === null ? null : deps.providerOf(accountId)
  // A login lookup with a ticket this run did not mint, or for an account that
  // has been deleted: "not found", never somebody else's token, and never the
  // real keychain — passing it through would read whatever the agent's
  // directory hash happens to name, which is the path-bound store this whole
  // module exists to stop depending on.
  if (accountId === null || provider === null) {
    const locked = call.requests.every((request) => request.op === 'locked?')
    return { kind: 'exit', answer: locked ? { code: 0, stdout: '', stderr: '' } : notFound() }
  }

  // An account still on its pre-vault login: let the agent read it once, the
  // way it always has, and keep what it reads. Only a pure lookup of something
  // the vault does not hold — a write or a delete is the agent telling us what
  // the login is now, and that is taken as it comes.
  if (
    deps.adopting(accountId) &&
    call.requests.length === 1 &&
    call.requests[0]?.op === 'find' &&
    call.requests[0].wantsPassword &&
    deps.vault.read(accountId, call.requests[0].slot) === null
  ) {
    return { kind: 'capture' }
  }

  let last: ShimAnswer = { code: 0, stdout: '', stderr: '' }
  const out: string[] = []
  for (const request of call.requests) {
    last = answerOne(request, accountId, provider, deps)
    if (last.stdout !== '') out.push(last.stdout)
  }
  return { kind: 'exit', answer: { code: last.code, stdout: out.join('\n'), stderr: last.stderr } }
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
  const accountId = deps.tickets.accountFor(read.ticket)
  const provider = accountId === null ? null : deps.providerOf(accountId)
  if (accountId === null || provider === null || !deps.adopting(accountId)) return false
  const call = readShimCall(read.argv, '')
  if (call.kind !== 'ours' || call.requests.length !== 1) return false
  const request = call.requests[0]
  if (request?.op !== 'find' || !request.wantsPassword) return false
  if (codeText !== '0') return false
  const value = read.rest.trim()
  if (value === '') return false
  const written = deps.vault.put(accountId, provider, request.slot, value, 'adopted')
  if (!written.ok) return false
  deps.markKept(accountId)
  deps.onCapture?.({ accountId, slot: request.slot, kind: 'adopted' })
  return true
}

/** The text the shim reads. */
export function wireText(answer: WireAnswer): string {
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
        if (req.url === '/keychain') return reply(res, 200, wireText(answerShim(body, deps)))
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
