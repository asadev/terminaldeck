/**
 * The relay's one HTTP route: an AI app on the internet reaching a Mac's tools.
 *
 * ## What arrives here
 *
 * claude.ai, ChatGPT, or a Claude Code on somebody's laptop, configured with a
 * link the Mac's owner copied out of Settings:
 *
 *     POST https://relay.example/mcp/<hostId>            Authorization: Bearer <key>
 *     POST https://relay.example/mcp/<hostId>/<key>      (for apps that cannot set a header)
 *
 * Each request is an MCP message over Streamable HTTP, stateless. The relay
 * hands it down the host's existing socket — the one a Mac already holds open
 * for its phones — in an envelope of its own, and writes whatever comes back
 * into the HTTP response. It does that and nothing else.
 *
 * ## The relay checks nothing that matters, on purpose
 *
 * **It never validates a key.** It cannot: it holds no list of keys, and the
 * rendezvous header already explains why this service must hold nothing worth
 * stealing. The key goes to the desktop, which compares a hash of it against
 * its own disk and applies every tier, confirmation and log row exactly as it
 * does for the copilot at the desk. What the relay *does* own is everything
 * that protects the relay itself: a cap on the body, a cap on requests per host
 * per minute and in flight, a deadline, and a fast 404 for a host that is not
 * there.
 *
 * ## It is not sealed, and the settings page says so
 *
 * TLS ends at the proxy in front of this process, so these requests are
 * plaintext here — the one thing this service carries that it *can* read.
 * `src/shared/relay-wire.ts` states the cost and why it is acceptable.
 *
 * ## Nothing here may ever print a path
 *
 * The path is `/mcp/<hostId>/<key>` for the apps that need the secret-link
 * form, so a path is a credential. There is no request log in this process and
 * there must never be one; every error message below is a constant. The test
 * suite fails if a key ever reaches the console.
 *
 * ## Why the probes get answers rather than silence
 *
 * A client adding a connector looks around before it commits. claude.ai and
 * the MCP SDK ask `/.well-known/oauth-protected-resource` (sometimes with the
 * resource path appended, so *those* paths carry the key too) and
 * `/.well-known/oauth-authorization-server` to learn whether to start an OAuth
 * dance. A JSON 404 there is how a server says "no OAuth here", and it is what
 * makes the secret link work as an authless connector instead of a connector
 * stuck asking for a login that does not exist. `GET` and `DELETE` on the MCP
 * path are the stream-resume and session-teardown halves of Streamable HTTP; a
 * stateless server answers both 405, which every SDK client handles.
 */

import { randomBytes } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'

/* -------------------------------------------------------------------------- */
/* The wire, mirrored                                                          */
/* -------------------------------------------------------------------------- */

/*
 * A copy of `src/shared/relay-wire.ts`'s MCP section, for the reason the
 * envelope above it is copied: the relay deploys on its own. The desktop's
 * `relay-client.test.ts` imports both and fails the moment they disagree.
 */

export const MCP_ENVELOPE = { request: 0x10, reply: 0x11, cancel: 0x12, reach: 0x13 } as const
export const RELAY_MCP_PREFIX = '/mcp/'
export const MCP_MAX_REQUEST_BYTES = 64 * 1024
export const MCP_MAX_RESPONSE_BYTES = 8 * 1024 * 1024
export const MCP_RELAY_WAIT_MS = 150_000
export const MCP_RATE_PER_MINUTE = 120
export const MCP_MAX_IN_FLIGHT = 8
export const MCP_REPLY_FIRST = 0x01
export const MCP_REPLY_LAST = 0x02
export const MCP_NOT_FOUND_STATUS = 404
export const MCP_NOT_FOUND_BODY =
  '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Nothing answered at this address. The computer ' +
  'may be off or not connected, or this link may have been turned off."}}'

const REQUEST_ID_BYTES = 16

export interface McpReplySlice {
  first: boolean
  last: boolean
  head: { status: number; contentType: string | null } | null
  chunk: Buffer
}

function withHead(head: unknown, rest: Buffer): Buffer {
  const json = Buffer.from(JSON.stringify(head), 'utf8')
  const length = Buffer.alloc(2)
  length.writeUInt16BE(json.length, 0)
  return Buffer.concat([length, json, rest])
}

export function encodeMcpRequest(
  head: {
    pathKey: string | null
    authorization: string | null
    protocolVersion: string | null
    userAgent: string | null
  },
  body: Buffer,
): Buffer {
  return withHead({ v: 1, ...head }, body)
}

/** Null for a slice that cannot be read. The request it belonged to is ended. */
export function decodeMcpReply(payload: Buffer): McpReplySlice | null {
  if (payload.length < 1) return null
  const flags = payload[0]
  const first = (flags & MCP_REPLY_FIRST) !== 0
  const last = (flags & MCP_REPLY_LAST) !== 0
  const rest = payload.subarray(1)
  if (!first) return { first, last, head: null, chunk: Buffer.from(rest) }
  if (rest.length < 2) return null
  const length = rest.readUInt16BE(0)
  if (rest.length < 2 + length) return null
  let head: unknown
  try {
    head = JSON.parse(rest.subarray(2, 2 + length).toString('utf8'))
  } catch {
    return null
  }
  if (typeof head !== 'object' || head === null) return null
  const record = head as Record<string, unknown>
  const status = record.status
  if (typeof status !== 'number' || !Number.isInteger(status) || status < 100 || status > 599) return null
  return {
    first,
    last,
    head: { status, contentType: typeof record.contentType === 'string' ? record.contentType : null },
    chunk: Buffer.from(rest.subarray(2 + length)),
  }
}

/* -------------------------------------------------------------------------- */
/* What the rendezvous lends this route                                        */
/* -------------------------------------------------------------------------- */

/** Where a forwarded request's answer goes. Exactly one of these is called last. */
export interface McpSink {
  slice(slice: McpReplySlice): void
  /** The host went away, or sent something unreadable, before the answer ended. */
  gone(): void
}

/** Why a request was not let through to its host. */
export type McpAdmission = 'ok' | 'offline' | 'busy' | 'rate'

/**
 * The narrow door onto the routing table this route needs.
 *
 * An interface so the route can be read on its own, and so nothing here can
 * reach a guest's channel or a host's secret: it can ask whether a host serves
 * MCP, put a request on its socket, and take one back.
 */
export interface McpRouting {
  /**
   * May one more request go to this host? Spends from its per-minute window.
   *
   * Asked before the body is read, so an offline host costs one status line
   * rather than a 64 KiB upload and a loop against a busy host is turned away
   * at the door.
   */
  admit(hostId: string): McpAdmission
  /**
   * Put the request on the host's socket. Null when the host left in the moment
   * since `admit` — the answer that counts is this one.
   */
  forward(hostId: string, payload: Buffer, sink: McpSink): Buffer | null
  cancel(hostId: string, id: Buffer): void
}

/* -------------------------------------------------------------------------- */
/* Per host: is it serving, and how much is it being asked                     */
/* -------------------------------------------------------------------------- */

/**
 * One host's MCP state, held on the host entry and dying with it.
 *
 * `serving` starts false and only the host's own `reach` frame sets it, so a
 * desktop from before this route existed is never sent a request it would drop
 * on the floor — it gets the fast 404 instead of a two-and-a-half-minute wait.
 */
export class McpHostState {
  serving = false
  readonly requests = new Map<string, McpSink>()
  private readonly hits: number[] = []

  constructor(private readonly now: () => number) {}

  /**
   * A plain sliding window, the same shape the desktop's own budgets use and
   * for the same reason: a bucket refills smoothly and lets a loop sustain its
   * average forever, which is exactly the runaway this exists to stop.
   */
  take(): boolean {
    const at = this.now()
    while (this.hits.length > 0 && this.hits[0] <= at - 60_000) this.hits.shift()
    if (this.hits.length >= MCP_RATE_PER_MINUTE) return false
    this.hits.push(at)
    return true
  }

  /** The host is gone: every request it owed an answer is ended now. */
  drop(): void {
    this.serving = false
    const owed = [...this.requests.values()]
    this.requests.clear()
    for (const sink of owed) sink.gone()
  }
}

export function newRequestId(): Buffer {
  return randomBytes(REQUEST_ID_BYTES)
}

/* -------------------------------------------------------------------------- */
/* The HTTP half                                                               */
/* -------------------------------------------------------------------------- */

/** Host ids are fixed-length uppercase base32. Mirrors `isHostId`. */
const HOST_ID = /^[A-HJ-NP-Z2-9]{26}$/

/**
 * A key, as far as the relay can tell without knowing any.
 *
 * Shape only — the desktop decides whether it is real. Loose enough for any key
 * the desktop will ever mint and tight enough that a path segment holding a
 * slash, a dot or a percent escape is refused here rather than forwarded.
 */
const KEY_SHAPE = /^[A-Za-z0-9_-]{16,128}$/

interface McpPath {
  hostId: string
  pathKey: string | null
}

/** `/mcp/<hostId>` or `/mcp/<hostId>/<key>`, a trailing slash forgiven. Null otherwise. */
export function parseMcpPath(pathname: string): McpPath | null {
  if (!pathname.startsWith(RELAY_MCP_PREFIX)) return null
  const parts = pathname.slice(RELAY_MCP_PREFIX.length).replace(/\/$/, '').split('/')
  if (parts.length === 0 || parts.length > 2) return null
  const [hostId, pathKey] = parts
  if (!HOST_ID.test(hostId)) return null
  if (pathKey !== undefined && !KEY_SHAPE.test(pathKey)) return null
  return { hostId, pathKey: pathKey ?? null }
}

/** Is this one of the probes a client makes before connecting? */
export function isDiscoveryProbe(pathname: string): boolean {
  return pathname.includes('/.well-known/')
}

function headerText(value: string | string[] | undefined): string | null {
  if (typeof value === 'string') return value
  if (Array.isArray(value) && typeof value[0] === 'string') return value[0]
  return null
}

const COMMON_HEADERS = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' } as const

function answer(res: ServerResponse, status: number, body: string, extra: Record<string, string> = {}): void {
  if (res.headersSent || res.writableEnded || res.destroyed) return
  res.writeHead(status, { 'content-type': 'application/json', ...COMMON_HEADERS, ...extra })
  res.end(body)
}

function jsonRpcError(code: number, message: string): string {
  return JSON.stringify({ jsonrpc: '2.0', id: null, error: { code, message } })
}

/** Fixed sentences. Not one of them may ever be composed from the request. */
const TOO_LARGE = jsonRpcError(-32600, 'That request is too large to forward.')
const TOO_MANY = jsonRpcError(-32000, 'Too many requests for this computer right now. Wait a minute and try again.')
const TOO_SLOW = jsonRpcError(-32000, 'The computer did not answer in time.')
const WENT_AWAY = jsonRpcError(-32000, 'The computer disconnected before it finished answering.')
const ONLY_POST = jsonRpcError(-32000, 'This address only takes POST. It is a stateless MCP server, so there is no stream to open and no session to end.')
const NO_OAUTH = JSON.stringify({ error: 'not_found', error_description: 'This server does not use OAuth. The link itself is the credential.' })

/** Answer content types we pass through. Anything else becomes JSON's. */
function passContentType(value: string | null): string {
  if (value !== null && /^(application\/json|text\/event-stream)\b/i.test(value)) return value
  return 'application/json'
}

/**
 * Handle one HTTP request, or say it was not ours.
 *
 * Returns false for any path this route does not own, so the caller's own 404
 * keeps answering everything else exactly as it did before this route existed.
 */
export function handleMcpHttp(
  req: IncomingMessage,
  res: ServerResponse,
  routing: McpRouting,
  waitMs: number = MCP_RELAY_WAIT_MS,
): boolean {
  // The query is dropped, never read: nothing here takes one, and a key passed
  // as `?key=` would be a key in a place proxies log.
  const pathname = (req.url ?? '/').split('?')[0]

  if (isDiscoveryProbe(pathname)) {
    answer(res, 404, NO_OAUTH)
    return true
  }

  if (!pathname.startsWith(RELAY_MCP_PREFIX)) return false

  const target = parseMcpPath(pathname)
  if (!target) {
    answer(res, MCP_NOT_FOUND_STATUS, MCP_NOT_FOUND_BODY)
    return true
  }

  if (req.method !== 'POST') {
    // Stateless Streamable HTTP: no stream for GET to resume, no session for
    // DELETE to end. 405 is the specification's own answer for both, and it is
    // given before the host is consulted, so it says nothing about whether the
    // host exists.
    answer(res, 405, ONLY_POST, { allow: 'POST' })
    return true
  }

  const admitted = routing.admit(target.hostId)
  if (admitted === 'offline') {
    answer(res, MCP_NOT_FOUND_STATUS, MCP_NOT_FOUND_BODY)
    return true
  }
  if (admitted !== 'ok') {
    answer(res, 429, TOO_MANY, { 'retry-after': admitted === 'rate' ? '60' : '5' })
    return true
  }

  // Refused on its declared size before a byte is read, where the client said
  // what it was about to send. A client that lies is caught by the count below.
  const declared = Number(headerText(req.headers['content-length']) ?? 'NaN')
  if (Number.isFinite(declared) && declared > MCP_MAX_REQUEST_BYTES) {
    answer(res, 413, TOO_LARGE, { connection: 'close' })
    res.once('finish', () => req.socket.destroy())
    return true
  }

  const chunks: Buffer[] = []
  let size = 0
  let settled = false
  let id: Buffer | null = null
  let timer: NodeJS.Timeout | null = null
  let written = 0

  const finish = (): void => {
    settled = true
    if (timer) clearTimeout(timer)
    timer = null
  }

  /*
   * The client hanging up has to reach the desktop.
   *
   * An alter-tier call can be sitting on the owner's screen waiting for a tap;
   * if the AI that asked has gone, the question must be withdrawn rather than
   * approved into a change nobody is waiting to hear about. The desktop turns a
   * cancel into the same `caller-gone` refusal a dropped loopback client gets.
   */
  res.once('close', () => {
    if (settled) return
    finish()
    if (id) routing.cancel(target.hostId, id)
  })

  req.on('data', (chunk: Buffer) => {
    if (settled) return
    size += chunk.length
    if (size > MCP_MAX_REQUEST_BYTES) {
      finish()
      answer(res, 413, TOO_LARGE, { connection: 'close' })
      res.once('finish', () => req.socket.destroy())
      return
    }
    chunks.push(chunk)
  })

  req.on('error', () => {
    if (settled) return
    finish()
    res.destroy()
  })

  req.on('end', () => {
    if (settled) return
    const payload = encodeMcpRequest(
      {
        pathKey: target.pathKey,
        authorization: headerText(req.headers.authorization),
        protocolVersion: headerText(req.headers['mcp-protocol-version']),
        userAgent: headerText(req.headers['user-agent']),
      },
      Buffer.concat(chunks),
    )

    const sink: McpSink = {
      slice(slice) {
        if (settled) return
        if (slice.first) {
          if (!slice.head || res.headersSent) {
            finish()
            res.destroy()
            return
          }
          res.writeHead(slice.head.status, {
            'content-type': passContentType(slice.head.contentType),
            ...COMMON_HEADERS,
          })
        } else if (!res.headersSent) {
          // A middle slice with no head in front of it is a desktop that has
          // lost its place; there is no honest response to compose from it.
          finish()
          res.destroy()
          return
        }
        written += slice.chunk.length
        if (written > MCP_MAX_RESPONSE_BYTES) {
          finish()
          if (id) routing.cancel(target.hostId, id)
          res.destroy()
          return
        }
        if (slice.chunk.length > 0) res.write(slice.chunk)
        if (slice.last) {
          finish()
          res.end()
        }
      },
      gone() {
        if (settled) return
        finish()
        if (res.headersSent) res.destroy()
        else answer(res, 502, WENT_AWAY)
      },
    }

    const forwarded = routing.forward(target.hostId, payload, sink)
    if (forwarded === null) {
      finish()
      answer(res, MCP_NOT_FOUND_STATUS, MCP_NOT_FOUND_BODY)
      return
    }
    id = forwarded
    timer = setTimeout(() => {
      if (settled) return
      finish()
      if (id) routing.cancel(target.hostId, id)
      if (res.headersSent) res.destroy()
      else answer(res, 504, TOO_SLOW)
    }, waitMs)
    timer.unref?.()
  })

  return true
}
