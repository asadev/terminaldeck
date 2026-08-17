/**
 * The endpoint provider hooks call back into.
 *
 * An agent CLI hook is a shell command. Ours POSTs the event JSON the CLI
 * writes to its stdin at this server, which turns it into a typed event the
 * rest of the app can act on without scraping terminal output.
 *
 * ## Why this is a unix socket and not a loopback port
 *
 * It was a TCP listener on `127.0.0.1:0` — an ephemeral port — and that one
 * decision broke the whole feature, silently, on every single launch. The port
 * is baked into the command written into the user's `~/.claude/settings.json`,
 * so the moment the app restarted every installed hook pointed at a port this
 * run does not own. All three providers sat permanently on "Needs reinstalling",
 * the user had to press Reinstall three times per launch, and if they did not,
 * every lifecycle event — including session-finished — went nowhere. Nothing was
 * in an error state anywhere; it just did not work.
 *
 * A filesystem socket fixes the cause rather than the symptom, because a path is
 * something we choose and a port is something the kernel hands out:
 *
 *  - **The address is stable.** `<userData>/hook.sock` is the same string on
 *    every launch, so the command written into a provider config in March is
 *    still correct in August. Nothing goes stale, so nothing needs repairing.
 *  - **It cannot be inherited by a stranger.** A recycled port number is the
 *    quiet hazard of the old design: a hook firing while the app is closed would
 *    POST an agent's tool input at whatever had since bound that number. A path
 *    we own cannot be handed to unrelated software.
 *  - **It is unreachable from a network stack at all.** There is no port to
 *    scan, no interface to bind wrongly, and — the reason the old design needed
 *    a Host check — no way for a page in a browser to open one. `fetch`, `XHR`
 *    and `WebSocket` cannot address a unix socket, so DNS rebinding stops being
 *    a threat model rather than being defended against.
 *  - **Access control becomes the filesystem's.** The socket is `chmod 0600`
 *    inside the app's own data directory, so the kernel refuses another user
 *    before a single byte is read.
 *
 * ## The token, and where it now lives
 *
 * Every request still carries a per-run token compared in constant time, but it
 * is no longer written into the hook command — which is the second half of the
 * staleness fix and, separately, a real improvement. The old design put a 48-hex
 * secret directly into `~/.gemini/settings.json` and `~/.codex/hooks.json`, both
 * mode 0644. Now the token goes into {@link HookEndpoint.configPath}, a curl
 * config file written 0600 beside the socket, and the hook command reads it at
 * call time with `curl -K`. So the hook command holds two stable paths and no
 * secret, and the secret is readable only by this user.
 *
 * Be honest about what the token is still worth: another process running as this
 * user can read that file, and can also just connect to the socket. It stops
 * confused software posting nonsense at us; it is not a defence against a local
 * attacker who is already inside the home directory. The filesystem permissions
 * are the boundary that does the work now.
 */

import { randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { connect } from 'node:net'
import { join } from 'node:path'
import { BRAND } from '../shared/brand'

/* ------------------------------------------------------------------ types -- */

export interface HookEndpoint {
  /** The unix socket hooks connect to. Stable for the life of an install. */
  socketPath: string
  /**
   * The curl config file a hook reads the token out of, at call time.
   *
   * Stable like the socket, and rewritten with a fresh token on every start.
   * That indirection is the whole reason an installed hook survives a restart.
   */
  configPath: string
  /** Per-run secret. Regenerated on every start; lives only in `configPath`. */
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
  /**
   * The directory the socket and its config file are created in.
   *
   * Required rather than defaulted, for the reason `platform/paths.ts` refuses
   * to default: the Electron shell and the headless shell keep their files in
   * different places, and a default would let one of them silently serve hooks
   * from the other's directory. Every caller states it — `src/main/index.ts`
   * and `src/headless/host.ts` from their own user-data directory, tests from a
   * temporary one.
   */
  dir: string
}

/* -------------------------------------------------------------- constants -- */

/** Names inside {@link HookServerOptions.dir}. Stable across runs on purpose. */
export const SOCKET_FILE = 'hook.sock'
export const CONFIG_FILE = 'hook-endpoint.conf'

/**
 * The longest a unix socket path may be.
 *
 * `sun_path` is 104 bytes on macOS and 108 on Linux, and going over it does not
 * produce a helpful error — `bind` fails with ENAMETOOLONG or, worse, silently
 * truncates on some platforms. The real path is about 64 bytes
 * (`~/Library/Application Support/Terminal Deck/hook.sock`), so this is a guard
 * against a future data directory nobody measured, and it fails with a sentence
 * rather than with an errno.
 */
const MAX_SOCKET_PATH_BYTES = 100

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

/**
 * Reject a Host header that names somebody else's server.
 *
 * This used to be the DNS-rebinding guard and it no longer has to be: a page in
 * a browser cannot open a unix socket by any API, so there is nothing to rebind.
 * What is left is a cheap sanity check that the caller believes it is talking to
 * us — a proxy or a confused tool that reused the socket while addressing
 * `example.com` is not a hook, and answering it would be answering a question
 * nobody asked us.
 *
 * The port is stripped rather than matched, because there is no longer a port to
 * match against: curl over `--unix-socket http://localhost/…` sends
 * `Host: localhost`, and a client that spells the default port out sends
 * `localhost:80`. Both are the same claim.
 */
export function hostIsLocal(host: string | undefined): boolean {
  if (!host) return false
  const name = host.toLowerCase().replace(/:\d+$/, '')
  return name === 'localhost' || name === '127.0.0.1' || name === '[::1]' || name === '::1'
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
  // No check on the peer address, and none is possible: a unix socket has no
  // remote address, because the peer is on this machine by construction. The
  // old `isLoopback(remoteAddress)` guard was answering the question "is this
  // connection from this machine", and the transport now answers it.
  if (req.method !== 'POST') return deny(res, 405)
  if (!hostIsLocal(req.headers.host)) return deny(res, 403)

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
 *  - `hooks:server` (invoke) → { address, running } — the token is deliberately
 *    not exposed to the renderer. The renderer never needs to call the endpoint,
 *    and a secret that reaches page code is a secret one XSS away from leaving.
 *
 * Returns the endpoint so the caller can install hooks against it. Calling it
 * twice returns the running one rather than starting a second server.
 */
export async function registerHookServer(
  ipcMain: Electron.IpcMain,
  options: HookServerOptions,
): Promise<HookEndpoint> {
  if (options.onEvent) listeners.add(options.onEvent)

  // This function promises to be safe to call twice, and `ipcMain.handle`
  // throws on a channel that already has a handler — so the promise has to be
  // kept here too, not just for the socket below.
  ipcMain.removeHandler('hooks:server')
  ipcMain.handle('hooks:server', () => ({
    address: endpoint?.socketPath ?? null,
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
export async function startHookServer(options: HookServerOptions): Promise<HookEndpoint> {
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

/**
 * Does something answer on this path right now?
 *
 * A socket file left behind by a crash looks exactly like a socket file being
 * served, and the difference decides between "clean up and bind" and "another
 * copy of the app owns this". The only way to tell them apart is to try: a live
 * server accepts the connection, an abandoned inode refuses it with ECONNREFUSED.
 * Nothing is sent — the connection is opened and immediately dropped.
 */
function socketAnswers(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = connect(socketPath)
    const settle = (answer: boolean): void => {
      probe.destroy()
      resolve(answer)
    }
    probe.once('connect', () => settle(true))
    probe.once('error', () => settle(false))
  })
}

/**
 * Make the path free, or explain why it is not.
 *
 * The "two copies of the app" case ends here, and it ends by refusing rather
 * than by stealing. Unlinking a socket somebody else is serving would not stop
 * them serving it — their listener keeps the open inode — but it *would* take
 * every hook on the machine away from them and give it to us, invisibly, with
 * their sessions silently losing their events. A second copy that cannot have
 * the endpoint is a second copy whose Settings pane says so, which is a state a
 * person can act on.
 *
 * In practice `app.requestSingleInstanceLock()` in `src/main/index.ts` already
 * stops a second copy of the *same* install, so what reaches here is a dev build
 * meeting a packaged one — two different data directories, two different socket
 * paths, and therefore no contention at all. This exists for the case that is
 * left: a crash that left the file behind.
 */
async function clearStaleSocket(socketPath: string): Promise<void> {
  if (!existsSync(socketPath)) return
  if (await socketAnswers(socketPath)) {
    throw new Error(
      `hook server: ${socketPath} is already being served, so another copy of ${BRAND.name} owns it`,
    )
  }
  unlinkSync(socketPath)
}

/**
 * Write the curl config a hook reads its token out of.
 *
 * 0600 before anything is written into it, not after: a file created 0644 and
 * tightened a moment later has a window in which the token is world-readable,
 * and the whole point of moving the secret out of the provider configs was that
 * those are 0644. `writeFileSync`'s mode is masked by the process umask, so it
 * is set explicitly afterwards as well — the same belt-and-braces `hooks.ts`
 * uses for the same reason.
 *
 * The values are quoted in curl's own config syntax. The socket path genuinely
 * contains a space on macOS ("Application Support"), so an unquoted line here
 * would be a feature that works on every machine except a real one.
 */
function writeEndpointConfig(configPath: string, socketPath: string, token: string): void {
  const body = [
    `# Written by ${BRAND.name} on every start. The token changes; the path does not.`,
    `unix-socket = ${curlConfigValue(socketPath)}`,
    `header = ${curlConfigValue(`${TOKEN_HEADER}: ${token}`)}`,
    '',
  ].join('\n')
  writeFileSync(configPath, body, { mode: 0o600 })
  chmodSync(configPath, 0o600)
}

/** A double-quoted curl config value, with the two characters it escapes. */
function curlConfigValue(value: string): string {
  return `"${value.split('\\').join('\\\\').split('"').join('\\"')}"`
}

async function openServer(options: HookServerOptions): Promise<HookEndpoint> {
  const socketPath = join(options.dir, SOCKET_FILE)
  if (Buffer.byteLength(socketPath) > MAX_SOCKET_PATH_BYTES) {
    throw new Error(
      `hook server: ${socketPath} is too long for a unix socket (${Buffer.byteLength(socketPath)} bytes, the limit is ${MAX_SOCKET_PATH_BYTES})`,
    )
  }

  const token = randomBytes(24).toString('hex')
  const live: HookEndpoint = { socketPath, configPath: join(options.dir, CONFIG_FILE), token }

  mkdirSync(options.dir, { recursive: true })
  await clearStaleSocket(socketPath)

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
    // A path, not a port. See the header: this is the whole staleness fix — the
    // address a hook was installed with is the address it still is next week.
    next.listen(socketPath, () => {
      next.removeListener('error', onListenError)
      // From here the server needs a permanent 'error' listener. An emitter
      // with none rethrows, so a failed accept() — EMFILE when the machine is
      // out of descriptors is the realistic one — would take down the whole
      // main process because a hook could not be received.
      next.on('error', (error) => console.error('[hook-server] server error:', error))
      resolve()
    })
  })

  // Only this user may connect. `listen` creates the socket with the process
  // umask applied, which on a default macOS account is 0755 — every other
  // account on the machine could open it. The kernel enforces this before a
  // single byte is read, which is a stronger boundary than the token inside.
  chmodSync(socketPath, 0o600)
  writeEndpointConfig(live.configPath, socketPath, token)

  // Nothing is claimed in `own-ports.ts` any more, and that is the point: this
  // endpoint no longer holds a loopback port, so there is no longer a way for
  // `remote/tunnel.ts` to offer a phone a tunnel to it by accident. A control
  // plane that cannot be addressed over the network needs no list keeping it
  // off one.
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
  const dead = endpoint
  server = null
  endpoint = null
  listeners.clear()

  /*
   * The config file goes first, and it goes even if the close below throws.
   *
   * It is the only copy of this run's token, so deleting it is what makes the
   * promise in this function's name true — a hook that fires after the app has
   * quit presents no credential to anything. The socket file is removed with it
   * so the next start finds a clean path rather than having to probe a corpse;
   * `clearStaleSocket` handles the case where a crash meant this never ran.
   */
  if (dead) {
    forget(dead.configPath)
  }

  if (running) {
    await new Promise<void>((resolve) => {
      running.close(() => resolve())
      // Hook connections are short-lived, but a half-open one should not hold
      // app shutdown open.
      running.closeAllConnections?.()
    })
  }

  // After the close, not before: Node unlinks the socket itself as part of
  // closing a unix-socket server, and removing it first would leave the next
  // start's freshly bound socket looking like ours to delete.
  if (dead) forget(dead.socketPath)
}

/** Remove a file we own, treating "already gone" as success. */
function forget(path: string): void {
  try {
    unlinkSync(path)
  } catch {
    // ENOENT is the ordinary case — Node removes the socket on close, and a
    // config file may never have been written if the start failed early.
  }
}
