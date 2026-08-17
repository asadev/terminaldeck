/**
 * Where the copilot reaches the app: one loopback HTTP endpoint speaking MCP.
 *
 * ## Why HTTP and not a stdio server
 *
 * Claude Code spawns stdio MCP servers itself, as child processes. A child
 * process cannot see this app's state — the live PTYs, the project list, the
 * settings cache all live in the Electron main process — so a stdio server
 * would have to be a shim that turns round and talks to the main process
 * anyway. That is two processes and one extra hop to reach the same place a
 * single loopback listener reaches directly. The precedent is already in this
 * repository: `hook-server.ts` puts an HTTP endpoint on 127.0.0.1 for exactly
 * this reason, and this file follows its security posture line for line.
 *
 * ## The four things that guard it
 *
 *  1. **It binds to 127.0.0.1.** Nothing off this machine can reach it. That is
 *     the boundary that actually matters.
 *  2. **Every request carries a per-run bearer token**, compared in constant
 *     time. Regenerated at every start and never reused, so a config file left
 *     behind by a previous run authenticates nothing.
 *  3. **The Host header must be a loopback literal**, which refuses a DNS
 *     rebind, and **an `Origin` header at all is refused**. No command-line
 *     client sends one; every browser does. A page that has been pointed at
 *     127.0.0.1 therefore cannot reach this even before the token is checked.
 *  4. **`POST /mcp` and nothing else.** GET and DELETE — the streaming and
 *     session-teardown halves of the Streamable HTTP transport — are answered
 *     405, because this server is stateless and has no stream to resume.
 *
 * Be honest about what the token is worth, in the same terms `hook-server.ts`
 * uses: it lives in a file in the app's own data directory, written 0600, so
 * another *user* on the machine cannot read it, but another *process running as
 * this user* can. It stops confused software, a drive-by browser request and a
 * second application that happened to guess the port. It is not a defence
 * against a local attacker who is already reading your home directory — and
 * neither is anything else the app could do here, because that attacker can
 * read the settings and the transcripts directly.
 *
 * ## Why a new Server per request
 *
 * Stateless: each POST is parsed, answered and forgotten. That is the SDK's
 * documented stateless pattern, and the alternative — one long-lived transport
 * holding a session id — buys resumable streams this server has no use for
 * while adding a way for a reconnecting client to be told its session no longer
 * exists. Constructing a `Server` is registering two handlers; it costs
 * nothing next to the work the tools then do.
 *
 * ## Timeouts, and the one that has to be shorter than the other
 *
 * An alter-tier call blocks on a human, so its answer can be a minute away. Two
 * clocks are then running: this server waiting for the person, and the client
 * waiting for this server. If the client's fires first it stops listening while
 * the question is still on screen — and a person clicking Allow after that
 * would change something the model has already been told did not happen.
 *
 * Both halves of that are closed. {@link DEFAULT_CONSENT_TIMEOUT_MS} is set
 * well under any MCP client's default tool timeout, and a dropped connection
 * cancels the outstanding question outright: `res.on('close')` closes the
 * transport, the SDK aborts the in-flight handler's signal, and `control.ts`
 * turns that into a `caller-gone` refusal. An answer given after the caller has
 * gone changes nothing.
 */

import { randomBytes, timingSafeEqual } from 'node:crypto'
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { BRAND } from '../../shared/brand'
import { claimOwnPort, releaseOwnPort } from '../own-ports'
import { advertiseTool } from './catalogue'
import type { DeckControl } from './control'

/* -------------------------------------------------------------- constants -- */

const HOST = '127.0.0.1'

/** The single route. Anything else is a 404 before the token is even read. */
export const MCP_PATH = '/mcp'

/** How the MCP server introduces itself. The name the copilot's tools are prefixed with. */
export const SERVER_NAME = 'deck-control'

/**
 * A JSON-RPC envelope is small. Even a `settings.write` patch is a few hundred
 * bytes, and the largest thing a client can legitimately send here is a four
 * thousand character prompt for `sessions.send`.
 */
const MAX_BODY_BYTES = 256 * 1024

/**
 * Header and request deadlines.
 *
 * The request one has to outlast a human answering a confirmation dialog, so it
 * is deliberately generous. The header one is not: a socket that opens and then
 * says nothing is either broken or probing, and Node's default would let it sit
 * for a minute.
 */
const HEADERS_TIMEOUT_MS = 10_000
const REQUEST_TIMEOUT_MS = 300_000

/* ------------------------------------------------------------------ types -- */

export interface DeckControlEndpoint {
  port: number
  /** Per-run secret. Regenerated on every start. */
  token: string
  /** The URL an MCP client is configured with. */
  url: string
}

export interface DeckControlServerOptions {
  control: DeckControl
  /** Fixed port, for tests. Zero (the default) takes whatever is free. */
  port?: number
}

/* --------------------------------------------------------------- guarding -- */

/**
 * Constant-time comparison that does not leak length either.
 *
 * Lifted in shape from `hook-server.ts`, which explains it: `timingSafeEqual`
 * throws on a length mismatch, so comparing raw buffers would make "wrong
 * length" a faster answer than "wrong bytes".
 */
function tokenMatches(supplied: unknown, expected: string): boolean {
  if (typeof supplied !== 'string') return false
  const offered = supplied.startsWith('Bearer ') ? supplied.slice('Bearer '.length) : supplied
  const a = Buffer.from(offered)
  const b = Buffer.from(expected)
  if (a.length !== b.length) {
    timingSafeEqual(b, b)
    return false
  }
  return timingSafeEqual(a, b)
}

function isLoopback(address: string | undefined): boolean {
  if (!address) return false
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
}

export function hostIsLocal(host: string | undefined, port: number): boolean {
  if (!host) return false
  return new Set([`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`]).has(host.toLowerCase())
}

class PayloadTooLarge extends Error {}

/**
 * Collect the request body with a cap, three ways to stop, and exactly one
 * settlement. The reasoning is `hook-server.ts`'s `readBody`, and it applies
 * unchanged: a body read that can hang is a request handler that can hang, and
 * this handler is holding the socket the copilot is blocked on.
 */
export function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let settled = false

    const finish = (error: Error | null, body?: string): void => {
      if (settled) return
      settled = true
      if (error) reject(error)
      else resolve(body ?? '')
    }

    req.on('data', (chunk: Buffer) => {
      if (settled) return
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        finish(new PayloadTooLarge('deck-control payload too large'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => finish(null, Buffer.concat(chunks).toString('utf8')))
    req.on('error', (error: Error) => finish(error))
    req.on('close', () => finish(new Error('deck-control request closed before its body arrived')))
  })
}

function deny(res: ServerResponse, code: number): void {
  if (res.writableEnded || res.destroyed) return
  /*
   * 403, never 401.
   *
   * A 401 with a `WWW-Authenticate` header is how an MCP client is told to go
   * and do OAuth, and Claude Code will start a browser-based authorisation
   * dance if it sees one. There is no authorisation server here and never will
   * be; a flat refusal is both true and the only answer that does not send
   * somebody's browser somewhere.
   */
  res.writeHead(code, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ error: code === 404 ? 'not found' : 'refused' }))
}

/* ------------------------------------------------------------- mcp plumbing -- */

/**
 * Turn a tool result into the MCP shape.
 *
 * Both the text block and `structuredContent` are filled. The text is what
 * every client can read — Claude Code shows it to the model — and the
 * structured copy is what a client with a schema-aware surface will prefer.
 * Sending only one of the two has burned people in both directions.
 */
function toolResult(value: unknown, error: string | null): {
  content: Array<{ type: 'text'; text: string }>
  structuredContent?: Record<string, unknown>
  isError?: boolean
} {
  if (error !== null) {
    return { content: [{ type: 'text', text: error }], isError: true }
  }
  const text = JSON.stringify(value ?? null, null, 2)
  return {
    content: [{ type: 'text', text }],
    ...(typeof value === 'object' && value !== null && !Array.isArray(value)
      ? { structuredContent: value as Record<string, unknown> }
      : {}),
  }
}

/**
 * A fresh MCP server bound to the control layer.
 *
 * The handlers are two lines each because they must be: everything that decides
 * whether a call happens lives in `control.ts`, and a transport that could make
 * that decision differently would be a second gate to keep in step with the
 * first.
 */
export function createMcpServer(control: DeckControl): Server {
  const server = new Server(
    { name: SERVER_NAME, version: '1.0.0' },
    {
      capabilities: { tools: {} },
      instructions:
        `Tools for seeing and driving ${BRAND.name} itself: the sessions running in it, the projects it has ` +
        'open, their git state, its alerts and its settings. Reading is always allowed. Starting a session or ' +
        'typing into one you started is allowed and recorded. Changing a setting, or acting on a session the ' +
        'person started, is put to them as a confirmation first and refused if they do not answer. Every call ' +
        'you make here is written to the action log they can read.',
    },
  )

  /*
   * The shape comes from `catalogue.ts` rather than being written out here.
   *
   * Not tidiness: `catalogueCost()` measures this exact payload against the
   * token budget, and a second copy of the mapping would mean the budget was
   * pinned against a listing that is not the one the model receives. One
   * function, used by the transport and by the measurement.
   */
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: control.tools().map(advertiseTool),
  }))

  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    /*
     * `attended` is left at its default of true, and that is a claim worth
     * naming rather than letting a default make silently.
     *
     * This transport serves the pinned copilot session — the one a person is
     * looking at in the sidebar — so there genuinely is somebody who can answer
     * a confirmation, and if there is not, `ConsentBroker` answers
     * `no-approver` because no window has attached. The unattended path does not
     * come through here at all: a routine reaches the same tools through
     * `DeckControl.unattended()`, in process, with no socket.
     */
    const result = await control.call(request.params.name, request.params.arguments, {
      signal: extra.signal,
    })
    return toolResult(result.value, result.ok ? null : (result.error ?? 'the call failed'))
  })

  return server
}

/* --------------------------------------------------------------- lifecycle -- */

let server: HttpServer | null = null
let endpoint: DeckControlEndpoint | null = null
let starting: Promise<DeckControlEndpoint> | null = null

/** The live endpoint, or null when the server is not running. */
export function currentEndpoint(): DeckControlEndpoint | null {
  return endpoint
}

async function handle(
  req: IncomingMessage,
  res: ServerResponse,
  live: DeckControlEndpoint,
  control: DeckControl,
): Promise<void> {
  if (!isLoopback(req.socket.remoteAddress)) return deny(res, 403)
  if (!hostIsLocal(req.headers.host, live.port)) return deny(res, 403)
  /*
   * Any Origin at all is a browser.
   *
   * The MCP specification asks servers to validate `Origin` against an
   * allowlist. There is no legitimate browser client for this endpoint, so the
   * allowlist is empty and the rule collapses to "refuse anything that has
   * one". Cheaper than a list and impossible to get subtly wrong later by
   * adding an entry to it.
   */
  if (typeof req.headers.origin === 'string') return deny(res, 403)

  // Token before path, so an unauthenticated caller learns nothing about which
  // routes exist.
  if (!tokenMatches(req.headers.authorization, live.token)) return deny(res, 403)

  const path = (req.url ?? '').split('?')[0]
  if (path !== MCP_PATH) return deny(res, 404)
  if (req.method !== 'POST') return deny(res, 405)

  let body: string
  try {
    body = await readBody(req)
  } catch (error) {
    return deny(res, error instanceof PayloadTooLarge ? 413 : 400)
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch {
    return deny(res, 400)
  }

  const mcp = createMcpServer(control)
  const transport = new StreamableHTTPServerTransport({
    // Stateless: no session id, nothing to resume, nothing to expire.
    sessionIdGenerator: undefined,
    // Plain JSON rather than an SSE stream. There is one request and one
    // answer; a stream would be an event source with a single event in it.
    enableJsonResponse: true,
  })

  /*
   * The caller hanging up has to reach the tool call.
   *
   * Closing the transport makes the SDK's `Protocol` abort every in-flight
   * request handler's signal, which is the signal `control.ts` hands to the
   * consent broker. Without this line an alter-tier call whose client had
   * already given up would keep a dialog on screen, and approving it would
   * change something nobody was still waiting to hear about.
   */
  let closed = false
  const onClose = (): void => {
    if (closed) return
    closed = true
    void transport.close().catch(() => undefined)
  }
  res.once('close', onClose)

  try {
    await mcp.connect(transport)
    await transport.handleRequest(req, res, parsed)
  } catch (error) {
    console.error('[deck-control] request failed:', error)
    if (!res.headersSent) deny(res, 500)
    else if (!res.writableEnded) res.end()
  } finally {
    res.off('close', onClose)
    // `mcp.close()` closes the transport with it. Both are per-request and
    // holding either past the answer would leak one object per call.
    await mcp.close().catch(() => undefined)
  }
}

/**
 * Start the endpoint.
 *
 * Safe to call twice: the second caller joins the first start rather than
 * opening a second socket. Modelled on `startHookServer`, including the shared
 * in-flight promise — two callers arriving before `listen` resolves would
 * otherwise both build a server, and the first would be left listening on a
 * port nobody holds a reference to for the life of the process.
 */
export async function startDeckControlServer(
  options: DeckControlServerOptions,
): Promise<DeckControlEndpoint> {
  if (endpoint) return endpoint
  if (starting) return starting

  starting = openServer(options)
  try {
    return await starting
  } finally {
    starting = null
  }
}

async function openServer(options: DeckControlServerOptions): Promise<DeckControlEndpoint> {
  const token = randomBytes(32).toString('hex')
  const live: DeckControlEndpoint = { port: 0, token, url: '' }

  const next = createServer((req, res) => {
    void handle(req, res, live, options.control).catch((error) => {
      console.error('[deck-control] handler threw:', error)
      if (!res.headersSent) deny(res, 500)
      else if (!res.writableEnded) res.end()
    })
  })

  next.on('clientError', (_error, socket) => socket.destroy())
  next.headersTimeout = HEADERS_TIMEOUT_MS
  next.requestTimeout = REQUEST_TIMEOUT_MS

  await new Promise<void>((resolve, reject) => {
    const onListenError = (error: Error): void => {
      next.close()
      reject(error)
    }
    next.once('error', onListenError)
    // Port 0: a fixed port would collide with whatever else on this machine
    // already wanted it, and a second copy of the app would fail to start.
    next.listen(options.port ?? 0, HOST, () => {
      next.removeListener('error', onListenError)
      // A permanent error listener from here on. An emitter with none rethrows,
      // so a failed accept — EMFILE when the machine is out of descriptors —
      // would take down the main process because a tool call could not be
      // received.
      next.on('error', (error) => console.error('[deck-control] server error:', error))
      resolve()
    })
  })

  const address = next.address() as AddressInfo | null
  if (!address) {
    next.close()
    throw new Error('deck-control: could not determine the listening port')
  }

  live.port = address.port
  live.url = `http://${HOST}:${address.port}${MCP_PATH}`
  /*
   * Say out loud that this port is ours, so a phone is never offered a tunnel
   * to it.
   *
   * `remote/tunnel.ts` will happily dial any loopback port something on this
   * machine is serving — that is the feature — and `dev-ports.ts` deliberately
   * keeps this app's own ports in the list it shows. Without this claim the
   * copilot's entire tool surface appears in a phone's port list, one tap away
   * from being reachable by anything on that phone that has the token. See
   * `own-ports.ts`; the bearer token is not the layer this should rest on.
   */
  claimOwnPort(address.port)
  server = next
  endpoint = live
  return live
}

/** Stop the endpoint and forget the token, so nothing can call into a dead run. */
export async function stopDeckControlServer(): Promise<void> {
  if (starting) {
    try {
      await starting
    } catch {
      /* a start that failed left nothing to stop */
    }
  }
  const running = server
  // Released before the close completes: the port goes back to the operating
  // system, and a stale claim would refuse somebody a tunnel to a dev server
  // that happened to be handed the same number.
  if (endpoint) releaseOwnPort(endpoint.port)
  server = null
  endpoint = null
  if (!running) return
  await new Promise<void>((resolve) => {
    running.close(() => resolve())
    running.closeAllConnections?.()
  })
}
