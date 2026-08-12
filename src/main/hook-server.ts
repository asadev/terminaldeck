/**
 * The endpoint provider hooks call back into.
 *
 * An agent CLI hook is a shell command. Ours POSTs the event JSON the CLI
 * writes to its stdin at this server, which turns it into a typed event the
 * rest of the app can act on without scraping terminal output.
 *
 * Three properties do the security work, in this order:
 *
 *  1. It binds to 127.0.0.1 only. Nothing off this machine can reach it, which
 *     is the boundary that actually matters.
 *  2. Every request must carry a per-run token, compared in constant time. The
 *     token is generated at startup and never persists, so an install from a
 *     previous run cannot post into this one.
 *  3. The Host header must be a loopback literal. A browser on this machine can
 *     be pointed at 127.0.0.1 by a hostile page (DNS rebinding), and while such
 *     a page cannot guess the token, refusing a rebound Host costs nothing.
 *
 * Be honest about what the token is worth: it lives in the user's provider
 * config, which on this machine is mode 0644 for two of the three providers.
 * Another process running as this user can read it. The token stops confused
 * software and drive-by browser requests; it is not a defence against a local
 * attacker who is already reading your home directory.
 */

import { randomBytes, timingSafeEqual } from 'node:crypto'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { BRAND } from '../shared/brand'

/* ------------------------------------------------------------------ types -- */

export interface HookEndpoint {
  port: number
  /** Per-run secret. Regenerated on every start; never written to disk by us. */
  token: string
}

export interface HookEvent {
  /** Which CLI fired it. */
  provider: string
  /** Event name as that CLI spells it — `PostToolUse`, `AfterTool`, … */
  event: string
  /** Our own session id, from the env var the PTY injects. Null outside one. */
  sessionId: string | null
  /** The CLI's own session id, when the payload carries one. */
  cliSessionId: string | null
  /** Working directory the CLI reported, when it reported one. */
  cwd: string | null
  /** Tool name for tool events, when present. */
  toolName: string | null
  receivedAt: number
  /** The parsed payload, or an empty object when the body was not JSON. */
  payload: Record<string, unknown>
}

export type HookEventListener = (event: HookEvent) => void

export interface HookServerOptions {
  /** Called for every accepted event. Errors thrown here are swallowed. */
  onEvent?: HookEventListener
  /** Fixed port, for tests. Zero (the default) takes whatever is free. */
  port?: number
}

/* -------------------------------------------------------------- constants -- */

const HOST = '127.0.0.1'

/** Header names, kept in step with the brand rather than spelled out twice. */
export const TOKEN_HEADER = `x-${BRAND.id}-token`
export const SESSION_HEADER = `x-${BRAND.id}-session`

/**
 * Hook payloads carry tool input, which for a large Write is genuinely big.
 * 1 MB is generous for that and still far short of anything that could be used
 * to push the app into swap by posting at it in a loop.
 */
const MAX_BODY_BYTES = 1024 * 1024

/** Provider and event names are path segments; keep them boring. */
const SEGMENT_RE = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/

/**
 * Header and whole-request deadlines.
 *
 * A hook payload arrives over loopback from a process on this machine, so it is
 * milliseconds of work. Node's defaults (60s for headers, 300s for the request)
 * would let a socket that opens and then says nothing sit there for five
 * minutes; these are still enormous for the real traffic and bound that.
 */
const HEADERS_TIMEOUT_MS = 10_000
const REQUEST_TIMEOUT_MS = 30_000

/* --------------------------------------------------------------- internals -- */

let server: Server | null = null
let endpoint: HookEndpoint | null = null
/**
 * The start that is in flight, if any.
 *
 * `startHookServer` awaits `listen`, so two callers that both arrive before it
 * resolves would both build a server: the first would be overwritten here and
 * left listening on a port nobody holds a reference to, for the life of the
 * process. Racing callers share this promise instead.
 */
let starting: Promise<HookEndpoint> | null = null
const listeners = new Set<HookEventListener>()

/** The live endpoint, or null when the server is not running. */
export function currentHookEndpoint(): HookEndpoint | null {
  return endpoint
}

/** Subscribe to hook events. Returns an unsubscribe function. */
export function onHookEvent(listener: HookEventListener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

function emit(event: HookEvent): void {
  for (const listener of listeners) {
    try {
      listener(event)
    } catch (error) {
      // One bad subscriber must not stop the others, and must never propagate
      // back to the HTTP response — the CLI is waiting on that response.
      console.error('[hook-server] listener threw:', error)
    }
  }
}

/**
 * Constant-time comparison that does not leak length either.
 *
 * `timingSafeEqual` throws on a length mismatch, so comparing raw buffers would
 * turn "wrong length" into a different, faster answer than "wrong bytes".
 */
function tokenMatches(supplied: unknown, expected: string): boolean {
  if (typeof supplied !== 'string') return false
  const a = Buffer.from(supplied)
  const b = Buffer.from(expected)
  if (a.length !== b.length) {
    // Still do the work, against a same-length buffer, so the failure costs the
    // same as a byte mismatch.
    timingSafeEqual(b, b)
    return false
  }
  return timingSafeEqual(a, b)
}

function isLoopback(address: string | undefined): boolean {
  if (!address) return false
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
}

/** Reject a Host that resolved somewhere other than this machine's loopback. */
function hostIsLocal(host: string | undefined, port: number): boolean {
  if (!host) return false
  const expected = new Set([`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`])
  return expected.has(host.toLowerCase())
}

/** `/hook/<provider>/<event>` and nothing else. */
export function parseHookPath(url: string | undefined): { provider: string; event: string } | null {
  if (!url) return null
  const path = url.split('?')[0]
  const parts = path.split('/').filter((part) => part !== '')
  if (parts.length !== 3 || parts[0] !== 'hook') return null
  if (!SEGMENT_RE.test(parts[1]) || !SEGMENT_RE.test(parts[2])) return null
  return { provider: parts[1], event: parts[2] }
}

/** Distinguishes "too big" from "the caller vanished", which answer differently. */
class PayloadTooLarge extends Error {}

/**
 * Collect the request body, with three ways to stop.
 *
 * Every one of them has to settle the promise exactly once. A body read that
 * can hang is a request handler that can hang, and the handler holds the socket
 * the CLI is blocked on — so premature close is an outcome here, not an
 * oversight. Going over the cap stops buffering but keeps draining: tearing the
 * socket down mid-upload loses the 413 the caller should have been told about.
 */
export function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let settled = false

    /**
     * Settles once and stays subscribed.
     *
     * Detaching the handlers here would be tidier and wrong: the request can
     * still emit `error` after we have answered, and a stream that errors with
     * no listener takes the process with it. Everything below is idempotent, so
     * later events are simply absorbed.
     */
    const finish = (error: Error | null, body?: string): void => {
      if (settled) return
      settled = true
      if (error) reject(error)
      else resolve(body ?? '')
    }

    req.on('data', (chunk: Buffer) => {
      // Past the cap nothing more is kept. The chunk is still consumed — the
      // stream stays in flowing mode and discards it — so the connection lives
      // long enough to be told 413 instead of being cut off mid-upload.
      if (settled) return
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        finish(new PayloadTooLarge('hook payload too large'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => finish(null, Buffer.concat(chunks).toString('utf8')))
    req.on('error', (error: Error) => finish(error))
    // 'close' without 'end' is a caller that went away mid-body. Node emits an
    // ECONNRESET 'error' first on current versions, but relying on that is what
    // turns a disconnect into a promise nobody ever settles.
    req.on('close', () => finish(new Error('hook request closed before its body arrived')))
  })
}

function str(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/**
 * Turn a raw payload into the fields the app actually uses.
 *
 * Field names differ per CLI and per version, so each is looked for under the
 * spellings seen in the real schemas and left null when absent. A missing field
 * is normal; guessing one would be worse than not having it.
 */
export function toHookEvent(
  provider: string,
  event: string,
  sessionId: string | null,
  body: string,
): HookEvent {
  let payload: Record<string, unknown> = {}
  if (body.trim() !== '') {
    try {
      const parsed: unknown = JSON.parse(body)
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        payload = parsed as Record<string, unknown>
      }
    } catch {
      // A hook that posts something unparseable still tells us the event fired.
    }
  }

  return {
    provider,
    event,
    sessionId,
    cliSessionId: str(payload.session_id),
    cwd: str(payload.cwd) ?? str(payload.workspace_dir),
    toolName: str(payload.tool_name),
    receivedAt: Date.now(),
    payload,
  }
}

function deny(res: ServerResponse, code: number): void {
  // The caller may already be gone — an oversized upload is answered while its
  // own socket is being torn down. Writing to that is a throw, not a reply.
  if (res.writableEnded || res.destroyed) return
  res.writeHead(code, { 'content-type': 'text/plain' })
  res.end()
}

async function handle(req: IncomingMessage, res: ServerResponse, live: HookEndpoint): Promise<void> {
  if (!isLoopback(req.socket.remoteAddress)) return deny(res, 403)
  if (req.method !== 'POST') return deny(res, 405)
  if (!hostIsLocal(req.headers.host, live.port)) return deny(res, 403)

  // Token before path: an unauthenticated caller learns nothing about which
  // routes exist.
  if (!tokenMatches(req.headers[TOKEN_HEADER], live.token)) return deny(res, 403)

  const route = parseHookPath(req.url)
  if (!route) return deny(res, 404)

  let body: string
  try {
    body = await readBody(req)
  } catch (error) {
    // A caller that disconnected mid-body gets nothing, because there is
    // nothing left to answer; deny() knows the difference.
    return deny(res, error instanceof PayloadTooLarge ? 413 : 400)
  }

  const sessionId = str(req.headers[SESSION_HEADER])

  // 204 with no body: the CLI blocks on this response, so it should be the
  // cheapest thing we can send. Anything we return would be parsed as hook
  // output and could change the agent's behaviour — we are observing, not
  // steering.
  res.writeHead(204)
  res.end()

  // Only now tell the app. Subscribers run synchronously, and a slow one on
  // this side of the response would be a slow one inside the user's turn: the
  // agent is stopped dead until its hook command returns.
  emit(toHookEvent(route.provider, route.event, sessionId, body))
}

/* --------------------------------------------------------------- lifecycle -- */

/**
 * Start the endpoint and wire its IPC. One call from the main process:
 *
 *     import { registerHookServer } from './hook-server'
 *     await registerHookServer(ipcMain)
 *
 * Channels:
 *  - `hooks:server` (invoke) → { port, running } — the token is deliberately
 *    not exposed to the renderer. The renderer never needs to call the endpoint,
 *    and a secret that reaches page code is a secret one XSS away from leaving.
 *
 * Returns the endpoint so the caller can install hooks against it. Calling it
 * twice returns the running one rather than starting a second server.
 */
export async function registerHookServer(
  ipcMain: Electron.IpcMain,
  options: HookServerOptions = {},
): Promise<HookEndpoint> {
  if (options.onEvent) listeners.add(options.onEvent)

  // This function promises to be safe to call twice, and `ipcMain.handle`
  // throws on a channel that already has a handler — so the promise has to be
  // kept here too, not just for the socket below.
  ipcMain.removeHandler('hooks:server')
  ipcMain.handle('hooks:server', () => ({
    port: endpoint?.port ?? null,
    running: endpoint !== null,
  }))

  if (endpoint) return endpoint
  return startHookServer(options)
}

/**
 * Start the endpoint without touching IPC — the seam the tests drive.
 *
 * Safe to call concurrently: the second caller joins the first start rather
 * than opening a socket of its own.
 */
export async function startHookServer(options: HookServerOptions = {}): Promise<HookEndpoint> {
  if (options.onEvent) listeners.add(options.onEvent)
  if (endpoint) return endpoint
  if (starting) return starting

  starting = openServer(options)
  try {
    return await starting
  } finally {
    starting = null
  }
}

async function openServer(options: HookServerOptions): Promise<HookEndpoint> {
  const token = randomBytes(24).toString('hex')
  const live: HookEndpoint = { port: 0, token }

  const next = createServer((req, res) => {
    void handle(req, res, live).catch(() => {
      // A handler that threw has already told us nothing useful; the CLI just
      // needs a response so its hook does not hang.
      if (!res.headersSent) deny(res, 500)
      else res.end()
    })
  })

  // A dropped connection from a hook that timed out is routine, not a crash.
  next.on('clientError', (_error, socket) => socket.destroy())
  next.headersTimeout = HEADERS_TIMEOUT_MS
  next.requestTimeout = REQUEST_TIMEOUT_MS

  await new Promise<void>((resolve, reject) => {
    const onListenError = (error: Error): void => {
      // A server that failed to bind still holds a handle; drop it rather than
      // leave it behind for every retry.
      next.close()
      reject(error)
    }
    next.once('error', onListenError)
    // Port 0 asks the OS for a free one: a fixed port would collide with
    // whatever else on this machine already wanted it, and a second copy of
    // the app would fail to start.
    next.listen(options.port ?? 0, HOST, () => {
      next.removeListener('error', onListenError)
      // From here the server needs a permanent 'error' listener. An emitter
      // with none rethrows, so a failed accept() — EMFILE when the machine is
      // out of descriptors is the realistic one — would take down the whole
      // main process because a hook could not be received.
      next.on('error', (error) => console.error('[hook-server] server error:', error))
      resolve()
    })
  })

  const address = next.address() as AddressInfo | null
  if (!address) {
    next.close()
    throw new Error('hook server: could not determine the listening port')
  }

  live.port = address.port
  server = next
  endpoint = live
  return live
}

/**
 * Stop the endpoint and forget the token, so nothing can post into a dead run.
 *
 * Subscribers go with it. This is shutdown, not a pause: anything that wants
 * events from a later run has to subscribe to that run.
 */
export async function stopHookServer(): Promise<void> {
  // A stop that races a start would otherwise find `server` still null and
  // return, leaving the socket that start was about to publish listening.
  if (starting) {
    try {
      await starting
    } catch {
      // A start that failed left nothing to stop.
    }
  }

  const running = server
  server = null
  endpoint = null
  listeners.clear()
  if (!running) return
  await new Promise<void>((resolve) => {
    running.close(() => resolve())
    // Hook connections are short-lived, but a half-open one should not hold
    // app shutdown open.
    running.closeAllConnections?.()
  })
}
