import { randomBytes, timingSafeEqual } from 'node:crypto'
import { createReadStream, promises as fs } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo, Socket } from 'node:net'
import { extname, posix, resolve, sep } from 'node:path'
import { isBridgeChannel } from './registry'
import { decodeFromWire, encodeForWire } from './wire'

/**
 * The private loopback bridge between the native shell's web view and this
 * process — the native shell's whole view of the app.
 *
 * ## The contract, which three lanes code against
 *
 *  - `GET /?t=<token>` sets `td_native=<token>` (HttpOnly, SameSite=Strict,
 *    Path=/) and serves the renderer's `index.html` with
 *    `<script src="/__td/shim.js"></script>` as the first script in `<head>`.
 *  - Every other request needs that cookie or an `X-TD-Token` header, a `Host`
 *    of exactly `127.0.0.1:<port>`, and no foreign `Origin`. Anything else is a
 *    403 that says nothing more.
 *  - `POST /__td/invoke` `{channel, args}` → `{ok:true, value}` / `{ok:false, error}`.
 *  - `POST /__td/send` `{channel, args}` → 204.
 *  - `GET /__td/events` → Server-Sent Events, `data: {"channel":…,"args":[…]}`.
 *  - `GET /__td/shim.js` → the shim the web lane builds; a 404 that says so when
 *    it has not been built.
 *  - Anything else under `GET` → a file from the built renderer.
 *
 * `sendSync` has no route: the preload never calls it, so there is nothing for
 * it to carry. A request for it gets a 501 that says exactly that.
 *
 * ## Why every check is here and none is optional
 *
 * The listener is loopback-only, but loopback is shared by every process and
 * every web page on the machine. A page in a browser can aim requests at
 * `127.0.0.1:<port>`; the token stops it calling anything, the `Host` check
 * stops DNS rebinding from turning it into a same-origin page, and the
 * `Origin` / `Sec-Fetch-Site` checks refuse cross-site requests before the
 * token is even compared. JSON bodies only, so a plain HTML form cannot post
 * here at all.
 */

export interface BridgeServerOptions {
  /** The built renderer: `out/renderer`. */
  rendererDir: string
  /** The shim the web lane builds: `out/native-web/shim.js`. */
  shimFile: string
  /** Call the handler `ipcMain.handle(channel, …)` registered. */
  invoke(channel: string, args: unknown[]): Promise<unknown>
  /** Deliver to `ipcMain.on(channel, …)` listeners. */
  send(channel: string, args: unknown[]): void
  /** An event stream opened — a page loaded, or reconnected. */
  onClient?(): void
  /** Fixed token, for tests. 32 random bytes otherwise — fresh every launch, whatever the port. */
  token?: string
  /**
   * Where the port is remembered between launches — a file in the data folder.
   *
   * The web view keeps `localStorage` per *origin*, and the port is part of the
   * origin, so a port picked fresh at every launch would make the screens
   * forget every remembered panel, tab and width each time. The remembered
   * port is asked for first; if something else holds it, any free port is
   * taken instead and that one is remembered. Omitted: any free port.
   */
  portFile?: string
  /** Largest request body accepted. 64 MiB by default. */
  maxBodyBytes?: number
  /** How often an idle event stream gets a comment line. 15 s by default. */
  keepAliveMs?: number
  /** How far one event stream may fall behind before it is dropped. 32 MiB by default. */
  maxQueuedBytes?: number
  log?(message: string): void
}

export interface BridgeServer {
  readonly port: number
  readonly token: string
  readonly origin: string
  /** What the shell loads first: `http://127.0.0.1:<port>/?t=<token>`. */
  readonly url: string
  /** Push to every open event stream. True when at least one was open. */
  emit(channel: string, args: readonly unknown[]): boolean
  clientCount(): number
  close(): Promise<void>
}

/** The one line on stdout that says the bridge is serving. */
export function readyLine(url: string): string {
  return `TD_NATIVE_READY ${url}`
}

/** The one line on stdout that says it never will. Newlines would split it, so they go. */
export function failedLine(reason: string): string {
  const flat = reason.replace(/[\r\n]+/g, ' ').trim()
  return `TD_NATIVE_FAILED ${flat === '' ? 'unknown reason' : flat}`
}

export const COOKIE_NAME = 'td_native'
export const TOKEN_HEADER = 'x-td-token'
const SHIM_TAG = '<script src="/__td/shim.js"></script>'

/**
 * The production policy `applySecurityPolicy` in `index.ts` puts on the
 * window, copied rather than imported because that one is built inside a
 * function there. `frame-ancestors` is the one addition: the window could not
 * be framed by anything, and over HTTP that has to be said.
 */
const CONTENT_SECURITY_POLICY =
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.wasm': 'application/wasm',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
}

export function contentTypeFor(path: string): string {
  return CONTENT_TYPES[extname(path).toLowerCase()] ?? 'application/octet-stream'
}

/**
 * A request path, as a file under `root` — or null for anything that tries to
 * leave it.
 *
 * Refused rather than normalised: a `..` segment, encoded or not, a backslash,
 * a NUL, or bad percent-encoding. Normalising `/assets/../../x` to `/x` would
 * serve *something*, and no page this app builds ever asks for that. The
 * symlink half is {@link realFileUnder}.
 */
export function staticPathFor(root: string, pathname: string): string | null {
  let decoded: string
  try {
    decoded = decodeURIComponent(pathname)
  } catch {
    return null
  }
  if (!decoded.startsWith('/') || decoded.includes('\0') || decoded.includes('\\')) return null
  if (decoded.split('/').some((segment) => segment === '..')) return null
  const relative = posix.normalize(decoded).replace(/^\/+/, '')
  const full = resolve(root, relative)
  if (full !== root && !full.startsWith(root + sep)) return null
  return full
}

/** The real path of a regular file inside `realRoot`, or null — a symlink out of the tree is refused. */
async function realFileUnder(realRoot: string, path: string): Promise<{ path: string; size: number } | null> {
  try {
    const real = await fs.realpath(path)
    if (!real.startsWith(realRoot + sep)) return null
    const stat = await fs.stat(real)
    return stat.isFile() ? { path: real, size: stat.size } : null
  } catch {
    return null
  }
}

/** Put the shim in as the first script in `<head>`. Null when there is no `<head>` to put it in. */
export function injectShim(html: string): string | null {
  const head = /<head(\s[^>]*)?>/i.exec(html)
  if (head === null) return null
  const at = head.index + head[0].length
  return `${html.slice(0, at)}\n    ${SHIM_TAG}${html.slice(at)}`
}

function cookieValue(header: string | undefined, name: string): string | null {
  if (header === undefined) return null
  for (const part of header.split(';')) {
    const eq = part.indexOf('=')
    if (eq === -1) continue
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim()
  }
  return null
}

function sameSecret(given: string | null | undefined, token: string): boolean {
  if (typeof given !== 'string') return false
  const a = Buffer.from(given)
  const b = Buffer.from(token)
  return a.length === b.length && timingSafeEqual(a, b)
}

class BodyError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message)
  }
}

function readBody(req: IncomingMessage, limit: number): Promise<Buffer> {
  return new Promise((resolveBody, reject) => {
    const declared = Number(req.headers['content-length'])
    if (Number.isFinite(declared) && declared > limit) {
      reject(new BodyError(413, `The request body is over the ${limit}-byte limit.`))
      return
    }
    const chunks: Buffer[] = []
    let size = 0
    let over = false
    req.on('data', (chunk: Buffer) => {
      if (over) return
      size += chunk.length
      if (size > limit) {
        // Refused now and the rest drained, not kept: destroying the socket
        // here would cut off the 413 before the client could read it.
        over = true
        chunks.length = 0
        reject(new BodyError(413, `The request body is over the ${limit}-byte limit.`))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolveBody(Buffer.concat(chunks)))
    req.on('error', (error) => reject(error))
  })
}

/** `{channel, args}` out of a JSON body, or a sentence saying what is wrong with it. */
function parseCall(body: Buffer): { channel: string; args: unknown[] } | string {
  let parsed: unknown
  try {
    parsed = JSON.parse(body.toString('utf8'))
  } catch {
    return 'The body is not JSON.'
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return 'The body must be an object.'
  const { channel, args } = parsed as { channel?: unknown; args?: unknown }
  if (!isBridgeChannel(channel)) return 'That is not a channel the bridge carries.'
  if (args !== undefined && !Array.isArray(args)) return '`args` must be an array.'
  return { channel, args: (decodeFromWire(args ?? []) as unknown[]) }
}

function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message
  return typeof error === 'string' ? error : String(error)
}

/** The port a data folder was last served on, or null when there is none worth asking for. */
export async function rememberedPort(file: string): Promise<number | null> {
  try {
    const port = Number((await fs.readFile(file, 'utf8')).trim())
    return Number.isInteger(port) && port >= 1024 && port <= 65535 ? port : null
  } catch {
    return null
  }
}

async function rememberPort(file: string, port: number): Promise<void> {
  const next = `${file}.${process.pid}.tmp`
  await fs.writeFile(next, `${port}\n`, { mode: 0o600 })
  await fs.rename(next, file)
}

export async function startBridgeServer(options: BridgeServerOptions): Promise<BridgeServer> {
  const token = options.token ?? randomBytes(32).toString('base64url')
  const maxBody = options.maxBodyBytes ?? 64 * 1024 * 1024
  const keepAliveMs = options.keepAliveMs ?? 15_000
  const maxQueued = options.maxQueuedBytes ?? 32 * 1024 * 1024
  const log = options.log ?? (() => undefined)
  const rendererDir = resolve(options.rendererDir)
  const realRendererDir = await fs.realpath(rendererDir)

  const clients = new Set<ServerResponse>()
  const sockets = new Set<Socket>()
  let host = ''
  let origin = ''

  function common(res: ServerResponse, extra: Record<string, string> = {}): void {
    res.setHeader('X-Content-Type-Options', 'nosniff')
    res.setHeader('Referrer-Policy', 'no-referrer')
    res.setHeader('Cache-Control', 'no-store')
    for (const [name, value] of Object.entries(extra)) res.setHeader(name, value)
  }

  function plain(res: ServerResponse, status: number, text: string): void {
    common(res, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.statusCode = status
    res.end(text)
  }

  function json(res: ServerResponse, status: number, value: unknown): void {
    let text: string
    try {
      text = encodeForWire(value)
    } catch (error) {
      text = encodeForWire({ ok: false, error: `The answer could not be turned into JSON: ${messageOf(error)}` })
    }
    common(res, { 'Content-Type': 'application/json; charset=utf-8' })
    res.statusCode = status
    res.end(text)
  }

  /** Who may ask anything at all. The token is checked separately, after this. */
  function foreign(req: IncomingMessage): boolean {
    if (req.headers.host !== host) return true
    const from = req.headers.origin
    if (from !== undefined && from !== origin) return true
    const site = req.headers['sec-fetch-site']
    if (site !== undefined && site !== 'same-origin' && site !== 'none') return true
    return false
  }

  async function serveIndex(req: IncomingMessage, res: ServerResponse, setCookie: boolean): Promise<void> {
    let html: string
    try {
      html = await fs.readFile(resolve(rendererDir, 'index.html'), 'utf8')
    } catch {
      plain(res, 500, 'The renderer has not been built: out/renderer/index.html is missing.')
      return
    }
    const page = injectShim(html)
    if (page === null) {
      plain(res, 500, 'The renderer’s index.html has no <head> to load the shim from.')
      return
    }
    common(res, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': CONTENT_SECURITY_POLICY })
    if (setCookie) res.setHeader('Set-Cookie', `${COOKIE_NAME}=${token}; HttpOnly; SameSite=Strict; Path=/`)
    res.statusCode = 200
    res.end(req.method === 'HEAD' ? undefined : page)
  }

  async function serveFile(
    req: IncomingMessage,
    res: ServerResponse,
    file: { path: string; size: number },
    contentType: string,
  ): Promise<void> {
    common(res, { 'Content-Type': contentType, 'Content-Length': String(file.size), 'Cache-Control': 'no-cache' })
    res.statusCode = 200
    if (req.method === 'HEAD') {
      res.end()
      return
    }
    const stream = createReadStream(file.path)
    stream.on('error', () => res.destroy())
    stream.pipe(res)
  }

  async function serveShim(req: IncomingMessage, res: ServerResponse): Promise<void> {
    try {
      const stat = await fs.stat(options.shimFile)
      if (!stat.isFile()) throw new Error('not a file')
      await serveFile(req, res, { path: options.shimFile, size: stat.size }, 'text/javascript; charset=utf-8')
    } catch {
      plain(res, 404, 'The native shim has not been built: out/native-web/shim.js is missing. Build the native web bundle first.')
    }
  }

  function openEvents(req: IncomingMessage, res: ServerResponse): void {
    common(res, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    })
    res.statusCode = 200
    req.socket.setNoDelay(true)
    req.socket.setTimeout(0)
    res.flushHeaders()
    res.write(': connected\n\n')
    clients.add(res)
    const drop = (): void => {
      clients.delete(res)
    }
    req.on('close', drop)
    res.on('close', drop)
    try {
      options.onClient?.()
    } catch (error) {
      log(`a client hook threw: ${messageOf(error)}`)
    }
  }

  async function handleCall(req: IncomingMessage, res: ServerResponse, kind: 'invoke' | 'send'): Promise<void> {
    const type = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase()
    if (type !== 'application/json') {
      json(res, 415, { ok: false, error: 'The body must be sent as application/json.' })
      return
    }
    let body: Buffer
    try {
      body = await readBody(req, maxBody)
    } catch (error) {
      // The connection may still be carrying the rest of a refused body.
      res.setHeader('Connection', 'close')
      json(res, error instanceof BodyError ? error.status : 400, { ok: false, error: messageOf(error) })
      return
    }
    const call = parseCall(body)
    if (typeof call === 'string') {
      json(res, 400, { ok: false, error: call })
      return
    }
    if (kind === 'send') {
      try {
        options.send(call.channel, call.args)
      } catch (error) {
        // A listener that throws is the main process's problem, as it is for a
        // window's `send`: logged here, and the sender is not told.
        log(`a send listener on ${call.channel} threw: ${messageOf(error)}`)
      }
      common(res)
      res.statusCode = 204
      res.end()
      return
    }
    try {
      const value = await options.invoke(call.channel, call.args)
      json(res, 200, { ok: true, value })
    } catch (error) {
      json(res, 200, { ok: false, error: messageOf(error) })
    }
  }

  async function route(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (foreign(req)) {
      plain(res, 403, 'Forbidden.')
      return
    }
    const raw = req.url ?? '/'
    const question = raw.indexOf('?')
    const pathname = question === -1 ? raw : raw.slice(0, question)
    const query = new URLSearchParams(question === -1 ? '' : raw.slice(question + 1))
    const method = req.method ?? 'GET'

    const bootstrap = pathname === '/' && sameSecret(query.get('t'), token)
    const authorised =
      bootstrap ||
      sameSecret(cookieValue(req.headers.cookie, COOKIE_NAME), token) ||
      sameSecret(req.headers[TOKEN_HEADER] as string | undefined, token)
    if (!authorised) {
      plain(res, 403, 'Forbidden.')
      return
    }

    if (pathname.startsWith('/__td/')) {
      if (pathname === '/__td/invoke' && method === 'POST') return handleCall(req, res, 'invoke')
      if (pathname === '/__td/send' && method === 'POST') return handleCall(req, res, 'send')
      if (pathname === '/__td/send-sync') {
        json(res, 501, { ok: false, error: 'This app’s preload never uses sendSync, so the bridge does not carry it.' })
        return
      }
      if (pathname === '/__td/events' && method === 'GET') return openEvents(req, res)
      if (pathname === '/__td/shim.js' && (method === 'GET' || method === 'HEAD')) return serveShim(req, res)
      plain(res, 404, 'Not found.')
      return
    }

    if (method !== 'GET' && method !== 'HEAD') {
      res.setHeader('Allow', 'GET, HEAD')
      plain(res, 405, 'Method not allowed.')
      return
    }
    if (pathname === '/' || pathname === '/index.html') return serveIndex(req, res, bootstrap)

    const candidate = staticPathFor(rendererDir, pathname)
    const file = candidate === null ? null : await realFileUnder(realRendererDir, candidate)
    if (file === null) {
      plain(res, 404, 'Not found.')
      return
    }
    await serveFile(req, res, file, contentTypeFor(file.path))
  }

  const server: Server = createServer((req, res) => {
    route(req, res).catch((error: unknown) => {
      log(`a request failed: ${messageOf(error)}`)
      if (!res.headersSent) plain(res, 500, 'The bridge could not answer that.')
      else res.destroy()
    })
  })
  server.on('connection', (socket) => {
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
  })
  server.on('clientError', (_error, socket) => {
    socket.destroy()
  })

  const listen = (wanted: number): Promise<void> =>
    new Promise<void>((resolveListen, reject) => {
      server.once('error', reject)
      server.listen(wanted, '127.0.0.1', () => {
        server.removeListener('error', reject)
        resolveListen()
      })
    })
  const preferred = options.portFile === undefined ? null : await rememberedPort(options.portFile)
  if (preferred === null) {
    await listen(0)
  } else {
    try {
      await listen(preferred)
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'EADDRINUSE' && code !== 'EACCES') throw error
      log(`port ${preferred} is taken, so the bridge is served on another one (saved pages start over there)`)
      await listen(0)
    }
  }
  server.on('error', (error) => log(`the listener reported: ${messageOf(error)}`))

  const port = (server.address() as AddressInfo).port
  if (options.portFile !== undefined && port !== preferred) {
    try {
      await rememberPort(options.portFile, port)
    } catch (error) {
      log(`could not remember port ${port}: ${messageOf(error)}`)
    }
  }
  host = `127.0.0.1:${port}`
  origin = `http://${host}`

  const keepAlive = setInterval(() => {
    for (const client of clients) client.write(': keep-alive\n\n')
  }, keepAliveMs)
  keepAlive.unref()

  let closed = false
  return {
    port,
    token,
    origin,
    url: `${origin}/?t=${token}`,
    emit(channel, args) {
      if (closed || clients.size === 0) return false
      let frame: string
      try {
        frame = `data: ${encodeForWire({ channel, args })}\n\n`
      } catch (error) {
        log(`a push on ${channel} could not be turned into JSON: ${messageOf(error)}`)
        return false
      }
      let delivered = false
      for (const client of [...clients]) {
        if (client.writableLength > maxQueued) {
          // A page that stopped reading. Dropped rather than buffered without
          // end; its event stream reconnects and the page asks for the state
          // it missed, as a reloaded window does.
          log('an event stream fell too far behind and was dropped')
          clients.delete(client)
          client.destroy()
          continue
        }
        client.write(frame)
        delivered = true
      }
      return delivered
    },
    clientCount: () => clients.size,
    async close() {
      if (closed) return
      closed = true
      clearInterval(keepAlive)
      for (const client of clients) client.end()
      clients.clear()
      await new Promise<void>((resolveClose) => {
        server.close(() => resolveClose())
        for (const socket of sockets) socket.destroy()
      })
    },
  }
}
