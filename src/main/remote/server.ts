/**
 * The server a phone talks to.
 *
 * HTTPS for the PWA, one WebSocket for the sessions, bound to nothing but this
 * machine's tailnet address. Four decisions carry the whole design.
 *
 * **It listens on the tailnet or it does not listen.** `0.0.0.0` would put a
 * terminal on every network this laptop ever joins, and a LAN address would put
 * one on the coffee shop's. `tailnet.ts` reads the address from the running
 * daemon; if it cannot, `start()` returns the reason and no socket is opened.
 * There is no option to override this, because an option is a thing someone
 * eventually sets.
 *
 * **Nothing happens before `hello`.** A socket that has not authenticated may
 * not list sessions, may not attach and may not type, and it is closed outright
 * a few seconds after connecting if it has not said who it is. A device may
 * only write to a session it has attached to, so a remembered session id is not
 * a keyboard.
 *
 * **Attaching replays the scrollback first.** This is the feature. SSH from a
 * phone gives you a blank screen and a cursor: whatever the agent said while
 * you were walking to the car is gone, and you are reading a conversation from
 * the middle. Attaching here sends the session's existing buffer before any
 * live byte, so the phone opens on context.
 *
 * **The session layer is injected.** `PtyManager` reaches into node-pty and
 * Electron; a socket server that imports it can only be tested by starting an
 * app. This one is tested against a fake `SessionAccess` over a plain loopback
 * `http.Server`, with the real handshake, the real framing and the real
 * authentication path.
 *
 * `ws` is not a dependency of this project and this file may not add one, so
 * the RFC 6455 framing below is written out. It is deliberately the boring
 * subset — text frames, fragments, ping/pong, close — with no extensions and no
 * compression. Binary frames are refused outright: the protocol is JSON, and a
 * second decoder for a shape nothing sends is only somewhere else to be wrong.
 */

import { createHash, randomUUID, timingSafeEqual } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import { createServer as createHttpsServer, type Server as HttpsServer } from 'node:https'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import { extname, join, normalize, resolve, sep } from 'node:path'
import type { IpcMain } from 'electron'
import { RemoteAuth, type Device, type PairingToken } from './device-auth'
import {
  CLOSE,
  MAX_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  chunkOutput,
  parseClientMessage,
  serialize,
  type ClientMessage,
  type DeviceDescriptor,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from './protocol'
import { ensureCert, tailnetStatus, type TailnetStatus } from './tailnet'

/* ------------------------------------------------------------------ types -- */

/**
 * A live subscription to one session.
 *
 * `replay` is on the handle rather than behind a separate `scrollback()` call
 * for an ordering reason: read-then-subscribe loses whatever arrived in
 * between, and subscribe-then-read sends it twice. Taking the snapshot at the
 * moment the subscription is made is the only version with no gap, and only the
 * session layer can do that atomically.
 */
export interface SessionHandle {
  readonly sessionId: string
  /** Everything the session had already printed when this handle was made. */
  readonly replay: string
}

/**
 * What this server needs from the session layer, and nothing more.
 *
 * `PtyManager` satisfies it through a small adapter in the main process; the
 * tests satisfy it with an object literal.
 */
export interface SessionAccess {
  list(): RemoteSession[]
  /** Null when there is no such session. Callbacks fire until `detach`. */
  attach(
    id: string,
    onData: (data: string) => void,
    onStatus: (status: string) => void,
    onExit: (exitCode: number) => void,
  ): SessionHandle | null
  write(id: string, data: string): void
  resize(id: string, cols: number, rows: number): void
  detach(handle: SessionHandle): void
}

/**
 * The half of `RemoteAuth` this server uses, as a seam.
 *
 * Not a duplicate of that module's job — the policy below is genuinely this
 * file's: which of the two secrets a `hello` is carrying, and what an
 * unapproved device is told. Keeping it behind one method means the socket
 * tests can run without spending 36ms of scrypt per connection, and that a
 * change to the trust store's shape lands in one adapter rather than in the
 * message loop.
 */
export interface RemoteAuthenticator {
  authenticate(token: string, device: DeviceDescriptor, address: string): Promise<AuthOutcome>
}

export type AuthOutcome =
  | { ok: true; deviceId: string; deviceName: string; credential: string | null }
  /**
   * `credential` is set when pairing succeeded but the device is not approved
   * yet: it has to reach the phone or the pairing was for nothing, and the
   * connection still ends here.
   */
  | { ok: false; message: string; credential?: string; deviceId?: string; deviceName?: string }

/** One phone, as the desktop lists it. */
export interface RemoteConnection {
  id: string
  deviceId: string
  deviceName: string
  /** What the phone said it was. Display only, and never checked against anything. */
  platform: string
  address: string
  connectedAt: number
  /** Sessions this phone is currently watching. */
  sessionIds: string[]
}

export interface RemoteEndpointOptions {
  sessions: SessionAccess
  auth: RemoteAuthenticator
  /** Directory holding the built PWA — `pwa/dist`. Injected, never derived here. */
  webRoot: string
  /**
   * Host headers to accept. Empty means "do not check", which is only safe
   * because the endpoint on its own does not know what it is bound to;
   * `createRemoteServer` always fills this in.
   */
  hosts?: string[]
  /** How long a socket may stay silent before it has authenticated. */
  helloTimeoutMs?: number
  /** Heartbeat interval. Zero turns it off, which is what the tests want. */
  pingIntervalMs?: number
  maxMessageBytes?: number
  /** Fires whenever a phone authenticates, attaches, detaches or leaves. */
  onConnections?: (connections: RemoteConnection[]) => void
}

export interface RemoteEndpoint {
  handleRequest(req: IncomingMessage, res: ServerResponse): void
  handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void
  connections(): RemoteConnection[]
  /** Close every socket held by one device. Returns how many were dropped. */
  dropDevice(deviceId: string): number
  /** Close one socket, leaving the device paired. False when it had already gone. */
  dropConnection(connectionId: string): boolean
  closeAll(): void
}

export interface RemoteServerOptions extends RemoteEndpointOptions {
  /** Where `tailscale cert` keeps the PEM pair. */
  certDir: string
  port?: number
  /** Test seams. Both default to the real thing in `tailnet.ts`. */
  readTailnet?: () => Promise<TailnetStatus>
  readCert?: (dnsName: string, dir: string) => Promise<CertLoad>
}

/** What the server needs to open a listener: the PEM text, not the paths. */
export type CertLoad = { ok: true; cert: string; key: string } | { ok: false; message: string }

export interface RemoteStatus {
  running: boolean
  /** What to open on the phone. Null when not running. */
  url: string | null
  address: string | null
  port: number
  /** Why it is not running, in a sentence a person can act on. */
  reason: string | null
  connections: RemoteConnection[]
}

export interface RemoteServer {
  start(): Promise<RemoteStatus>
  stop(): Promise<RemoteStatus>
  url(): string | null
  connections(): RemoteConnection[]
  dropDevice(deviceId: string): number
  dropConnection(connectionId: string): boolean
  status(): RemoteStatus
}

/* -------------------------------------------------------------- constants -- */

/** The one upgrade path. Everything else on this server is a static file. */
export const WS_PATH = '/ws'

/**
 * Fixed, not ephemeral.
 *
 * The phone stores this URL — it ends up on a home screen. A port chosen by the
 * OS would be a different URL after every restart, which is a feature that
 * works once.
 */
export const DEFAULT_PORT = 8443

const HELLO_TIMEOUT_MS = 8000
const PING_INTERVAL_MS = 30_000

/**
 * How much unsent output may pile up on one socket before it is dropped.
 *
 * A phone on a train cannot keep up with a build log, and the kernel's own
 * buffer stops absorbing it long before the app notices. Without this cap the
 * backlog lives in the main process's heap — the same heap the user's terminals
 * run in — so a bad connection becomes an out-of-memory crash of the desktop
 * app. Dropping the phone is the better failure.
 */
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024

/**
 * How long a closing socket is given to send its close frame and hear one back
 * before it is torn down. A peer that never answers must not hold a descriptor
 * open for the OS default, which is measured in minutes.
 */
const CLOSE_LINGER_MS = 1000

/**
 * How many sockets this server will hold at once.
 *
 * Nothing before `hello` costs an attacker anything: a peer on the tailnet can
 * open sockets as fast as it can dial, and each one buys a descriptor, a timer
 * and a parser for the length of the hello timeout. Without a ceiling that is a
 * file-descriptor exhaustion of the desktop app — the process running the
 * user's terminals — from any node on the tailnet, including one shared in from
 * somebody else's. A person uses two or three phones; sixty-four is far past
 * generous and still a number.
 */
const MAX_CONNECTIONS = 64

/**
 * How much scrollback an attach replays.
 *
 * `PtyManager` keeps 4,000 chunks, and a chunk out of a build log is kilobytes:
 * a session that has been running all afternoon can hold tens of megabytes.
 * Sent whole, that walks straight into the backpressure cap below and drops the
 * phone — which then reconnects, re-attaches and is dropped again, so the
 * sessions worth opening from a phone would be exactly the ones that never
 * open. It also serialises in one tick, on the thread drawing the desktop UI.
 *
 * The tail is what a phone screen can show and what the user was reading, so
 * the front is what goes. 64 chunks is 2 MB, or several thousand lines.
 */
const MAX_REPLAY_CHUNKS = 64

/**
 * Ceiling on the string that is chunked in the first place. Scanning 60 MB to
 * throw away all but the last 2 MB is still 60 MB of main-thread work, and the
 * only reason to look at the front of it would be to discard it.
 */
const MAX_REPLAY_CHARS = 4 * 1024 * 1024

/** Dropped-device markers kept for the race below. Devices are capped at 64. */
const MAX_DROPPED_TRACKED = 256

/* ------------------------------------------------------- RFC 6455 framing -- */

/** The magic string from RFC 6455 §1.3. Not a secret, just a constant. */
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

export function acceptKey(key: string): string {
  return createHash('sha1')
    .update(key + WS_GUID)
    .digest('base64')
}

const OPCODE = { continuation: 0x0, text: 0x1, binary: 0x2, close: 0x8, ping: 0x9, pong: 0xa } as const

/** Server frames are never masked (RFC 6455 §5.1); client frames always are. */
export function encodeFrame(opcode: number, payload: Buffer): Buffer {
  const length = payload.length
  let header: Buffer
  if (length < 126) {
    header = Buffer.alloc(2)
    header[1] = length
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  header[0] = 0x80 | opcode
  return Buffer.concat([header, payload])
}

interface WireHandlers {
  message(text: string): void
  closed(): void
}

/**
 * One WebSocket connection, in the subset this protocol uses.
 *
 * Everything that can go wrong on the wire ends the connection rather than
 * throwing. This runs on the `data` event of a socket inside the main process,
 * so an exception here takes the whole app down over a malformed frame from a
 * phone on a bad network.
 */
class WireSocket {
  private incoming: Buffer = Buffer.alloc(0)
  private fragments: Buffer[] = []
  private fragmentBytes = 0
  private fragmented = false
  private finished = false
  private awaitingPong = false
  private heartbeat: NodeJS.Timeout | null = null

  constructor(
    private readonly socket: Duplex,
    private readonly maxMessageBytes: number,
    private readonly handlers: WireHandlers,
  ) {
    // Keystrokes are one-byte writes; Nagle would hold each one waiting for an
    // ack and the phone would feel like a satellite link.
    if ('setNoDelay' in socket && typeof socket.setNoDelay === 'function') socket.setNoDelay(true)
    socket.on('data', (chunk: Buffer) => this.receive(chunk))
    socket.on('error', () => this.finish())
    socket.on('close', () => this.finish())
    // 'end' matters as much as 'close' here, and this was measured rather than
    // assumed: when a phone disappears — tunnel, force-quit, battery — the
    // server's half of an upgraded socket receives the FIN as 'end' and then
    // stays writable, so 'close' never fires. Listening only for 'close' left
    // the connection in the live map with its sessions still attached, for
    // every phone that ever vanished. A WebSocket has no half-open state, so a
    // FIN without a close frame means the peer is gone.
    socket.on('end', () => this.finish())
  }

  startHeartbeat(intervalMs: number): void {
    if (intervalMs <= 0) return
    this.heartbeat = setInterval(() => {
      if (this.finished) return
      // A phone that went into a tunnel keeps a TCP connection that looks open
      // for minutes, and with it an attached session.
      if (this.awaitingPong) {
        this.close(CLOSE.goingAway, 'no response to ping')
        return
      }
      this.awaitingPong = true
      this.write(OPCODE.ping, Buffer.alloc(0))
    }, intervalMs)
    this.heartbeat.unref?.()
  }

  send(text: string): void {
    if (this.finished) return
    if (this.socket.writableLength > MAX_BUFFERED_BYTES) {
      this.close(CLOSE.tryAgainLater, 'output backed up')
      return
    }
    this.write(OPCODE.text, Buffer.from(text, 'utf8'))
  }

  close(code: number, reason = ''): void {
    if (this.finished) return
    const body = Buffer.alloc(2 + Buffer.byteLength(reason, 'utf8'))
    body.writeUInt16BE(code, 0)
    body.write(reason, 2, 'utf8')
    try {
      // `end` rather than `write` + `destroy`: the close frame carries the
      // reason the phone shows its user, and destroying the socket in the same
      // tick discards it unsent. The peer answers with its own close and the
      // socket ends itself; the timer below is only for one that never does.
      this.socket.end(encodeFrame(OPCODE.close, body))
    } catch {
      /* Peer already gone; `finish` still has to run. */
    }
    this.finish()
  }

  private write(opcode: number, payload: Buffer): void {
    try {
      this.socket.write(encodeFrame(opcode, payload))
    } catch {
      this.finish()
    }
  }

  private finish(): void {
    if (this.finished) return
    this.finished = true
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.heartbeat = null
    // Free the parser's buffers: a connection that died mid-message would
    // otherwise hold its fragments until the object itself is collected.
    this.incoming = Buffer.alloc(0)
    this.fragments = []
    // End our own half — the peer may only have closed its writing side — and
    // tear the socket down if it never answers. Not `destroy()` on the spot:
    // `close()` has just queued a close frame carrying the reason the phone
    // shows its user, and destroying in the same tick discards it unsent.
    if (!this.socket.destroyed) {
      this.socket.end()
      const linger = setTimeout(() => this.socket.destroy(), CLOSE_LINGER_MS)
      linger.unref?.()
    }
    this.handlers.closed()
  }

  private fail(code: number, reason: string): void {
    this.close(code, reason)
  }

  private receive(chunk: Buffer): void {
    if (this.finished) return
    this.incoming = this.incoming.length === 0 ? chunk : Buffer.concat([this.incoming, chunk])

    for (;;) {
      if (this.finished) return
      const buf = this.incoming
      if (buf.length < 2) return

      const first = buf[0]
      const second = buf[1]
      if ((first & 0x70) !== 0) return this.fail(CLOSE.protocolError, 'reserved bits set')

      const fin = (first & 0x80) !== 0
      const opcode = first & 0x0f
      // Unmasked client frames are a protocol violation, and accepting them is
      // the classic cache-poisoning hole.
      if ((second & 0x80) === 0) return this.fail(CLOSE.protocolError, 'client frame was not masked')

      let length = second & 0x7f
      let offset = 2
      if (length === 126) {
        if (buf.length < offset + 2) return
        length = buf.readUInt16BE(offset)
        offset += 2
      } else if (length === 127) {
        if (buf.length < offset + 8) return
        const wide = buf.readBigUInt64BE(offset)
        offset += 8
        // Compared as BigInt: a 2^63 length would round to a plausible Number.
        if (wide > BigInt(this.maxMessageBytes)) return this.fail(CLOSE.messageTooBig, 'frame too large')
        length = Number(wide)
      }
      // Refused on the declared length, before the payload is buffered — the
      // point of a cap is not to hold the memory in the first place.
      if (length > this.maxMessageBytes) return this.fail(CLOSE.messageTooBig, 'frame too large')

      const total = offset + 4 + length
      if (buf.length < total) return

      const mask = buf.subarray(offset, offset + 4)
      const payload = Buffer.from(buf.subarray(offset + 4, total))
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i & 3]

      this.incoming = buf.subarray(total)
      this.frame(fin, opcode, payload)
    }
  }

  private frame(fin: boolean, opcode: number, payload: Buffer): void {
    if (opcode >= 0x8) {
      // Control frames cannot be fragmented and cannot exceed 125 bytes.
      if (!fin || payload.length > 125) return this.fail(CLOSE.protocolError, 'malformed control frame')
      if (opcode === OPCODE.close) return this.close(CLOSE.normal, '')
      if (opcode === OPCODE.ping) return this.write(OPCODE.pong, payload)
      if (opcode === OPCODE.pong) {
        this.awaitingPong = false
        return
      }
      return this.fail(CLOSE.protocolError, 'unknown control frame')
    }

    if (opcode === OPCODE.binary) {
      return this.fail(CLOSE.unsupportedData, 'binary frames are not accepted')
    }

    if (opcode === OPCODE.text) {
      if (this.fragmented) return this.fail(CLOSE.protocolError, 'interleaved message')
      if (fin) return this.deliver(payload)
      this.fragmented = true
      this.fragments = [payload]
      this.fragmentBytes = payload.length
      return
    }

    if (opcode === OPCODE.continuation) {
      if (!this.fragmented) return this.fail(CLOSE.protocolError, 'continuation without a start')
      this.fragmentBytes += payload.length
      // The cap is on the whole message, not on the frame: fragmenting is
      // otherwise a way to send any size at all.
      if (this.fragmentBytes > this.maxMessageBytes) return this.fail(CLOSE.messageTooBig, 'message too large')
      this.fragments.push(payload)
      if (!fin) return
      const whole = Buffer.concat(this.fragments)
      this.fragments = []
      this.fragmentBytes = 0
      this.fragmented = false
      return this.deliver(whole)
    }

    return this.fail(CLOSE.protocolError, `unsupported opcode ${opcode}`)
  }

  private deliver(payload: Buffer): void {
    try {
      this.handlers.message(payload.toString('utf8'))
    } catch (error) {
      // A handler that threw has already failed; the socket must still not take
      // the process down with it.
      console.error('[remote] message handler threw:', error)
      this.fail(CLOSE.internalError, 'internal error')
    }
  }
}

/* ----------------------------------------------------------- static files -- */

const CONTENT_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
}

/**
 * Turn a request path into a file inside `root`, or null.
 *
 * The containment check is on the resolved path, not on the request string:
 * `%2e%2e%2f` and a bare `..` name the same file once decoded, and only one of
 * them looks like an attack.
 */
export function resolveStaticPath(root: string, requestPath: string): string | null {
  let decoded: string
  try {
    decoded = decodeURIComponent(requestPath)
  } catch {
    return null
  }
  if (decoded.includes('\0')) return null

  const rootPath = resolve(root)
  const trimmed = decoded === '/' || decoded === '' ? '/index.html' : decoded
  const target = resolve(join(rootPath, normalize(trimmed)))
  if (target !== rootPath && !target.startsWith(rootPath + sep)) return null

  // A path with no extension is a client-side route — the PWA's own router owns
  // it, so it gets the shell rather than a 404.
  if (extname(target) === '') return join(rootPath, 'index.html')
  return target
}

/**
 * May this file be cached forever?
 *
 * Only for a name that carries a content hash, which in this build means
 * `/assets/` and nothing else — `pwa/vite.config.ts` deliberately emits
 * `sw.js`, `manifest.webmanifest` and the icons at fixed URLs, because a
 * service worker's script and scope have to stay put across builds. Those are
 * the files whose *contents* change from build to build, so "immutable" on them
 * is exactly backwards: a phone would hold the manifest for a year, and the
 * worker's own install step would refill its cache from that stale copy. An
 * earlier version of this line asked whether the name ended in `.html`, which
 * put every one of them in the immutable bucket.
 */
function immutable(root: string, file: string): boolean {
  return file.startsWith(join(resolve(root), 'assets') + sep)
}

async function serveStatic(root: string, req: IncomingMessage, res: ServerResponse): Promise<void> {
  const requestPath = (req.url ?? '/').split('?')[0]
  const file = resolveStaticPath(root, requestPath)
  if (!file) {
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' })
    res.end('bad path')
    return
  }

  let size: number
  try {
    const info = await stat(file)
    if (!info.isFile()) throw new Error('not a file')
    size = info.size
  } catch {
    // The PWA may simply not be built yet. Saying so beats a bare 404, which
    // reads as a broken server rather than a missing build step. Compared
    // against the resolved shell rather than by suffix, so a missing
    // `docs-index.html` is still an ordinary 404.
    const missingShell = file === join(resolve(root), 'index.html')
    res.writeHead(missingShell ? 503 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    res.end(missingShell ? 'The phone app has not been built into pwa/dist yet.' : 'not found')
    return
  }

  res.writeHead(200, {
    'content-type': CONTENT_TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream',
    'content-length': String(size),
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    // This page is a live terminal. Nothing may frame it: a tap the user thinks
    // lands on someone else's page must not land on their shell.
    'content-security-policy': "frame-ancestors 'none'",
    'x-frame-options': 'DENY',
    'cache-control': immutable(root, file) ? 'public, max-age=31536000, immutable' : 'no-cache',
  })
  if (req.method === 'HEAD') {
    res.end()
    return
  }

  const stream = createReadStream(file)
  stream.on('error', () => res.destroy())
  stream.pipe(res)
}

/* ------------------------------------------------------------- connections -- */

interface LiveConnection {
  id: string
  wire: WireSocket
  address: string
  connectedAt: number
  deviceId: string | null
  deviceName: string
  platform: string
  handles: Map<string, SessionHandle>
  helloTimer: NodeJS.Timeout | null
  /**
   * Set while a `hello` is being checked. Verification is asynchronous — scrypt
   * takes tens of milliseconds — and the socket is still readable throughout,
   * so without this a client that sends two hellos in one segment gets both
   * checked at once, against a connection that is unauthenticated for both.
   */
  greeting: boolean
}

function hostAllowed(host: string | undefined, hosts: string[]): boolean {
  if (hosts.length === 0) return true
  if (!host) return false
  return hosts.includes(host.toLowerCase())
}

/**
 * Whether a browser that sent this `Origin` may open the socket.
 *
 * `Host` is not enough here. A page on any site the phone visits can open a
 * WebSocket to a URL it knows, and the browser sends *our* host in `Host` —
 * that header says where the request went, never where it came from. Only
 * `Origin` says the second thing, and refusing a foreign one is what keeps a
 * random page from holding an open socket against this Mac.
 *
 * It cannot authenticate anything on its own, because it has no credential. The
 * point is that it should not get as far as trying.
 *
 * Absent is allowed: `Origin` is a browser header, and a native client or a
 * test harness sends none. A page cannot suppress it, so this is not a bypass.
 */
function originAllowed(origin: string | undefined, hosts: string[]): boolean {
  if (hosts.length === 0) return true
  if (origin === undefined || origin === '') return true
  // 'null' is what a sandboxed or file: page sends. It is not our origin.
  if (origin === 'null') return false
  try {
    return hosts.includes(new URL(origin).host.toLowerCase())
  } catch {
    return false
  }
}

function refuseUpgrade(socket: Duplex, code: number, text: string): void {
  try {
    socket.end(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
  } catch {
    socket.destroy()
  }
}

/**
 * The protocol, with no opinion about how the socket was obtained.
 *
 * Split out from `createRemoteServer` so the tests can hang it off a plain
 * loopback `http.Server` and exercise the real handshake, the real framing and
 * the real authentication without a tailnet or a certificate. A test that has
 * to mint a certificate is a test nobody runs.
 */
export function createRemoteEndpoint(options: RemoteEndpointOptions): RemoteEndpoint {
  const helloTimeoutMs = options.helloTimeoutMs ?? HELLO_TIMEOUT_MS
  const pingIntervalMs = options.pingIntervalMs ?? PING_INTERVAL_MS
  const maxMessageBytes = options.maxMessageBytes ?? MAX_MESSAGE_BYTES
  const hosts = (options.hosts ?? []).map((host) => host.toLowerCase())
  const live = new Map<string, LiveConnection>()

  /**
   * When each device was last swept off this server, and a counter to date it.
   *
   * A revoke does two things: it writes the trust store and it closes that
   * device's sockets. Neither reaches a `hello` that is in the middle of being
   * checked — the sweep cannot see the connection, because an unauthenticated
   * one has no `deviceId` yet, and the trust store cannot help either, because
   * the verification is already holding the device record it read before it
   * started hashing. Measured, not reasoned about: a `verifyCredential` whose
   * scrypt overlaps `revokeDevice` returns `ok`. The window is the length of one
   * hash, which is nothing to a person and everything to a phone reconnecting in
   * a loop, and what it wins is a session that survives the revocation for as
   * long as the app stays open.
   *
   * So an authentication that *started* before a sweep of that device is refused
   * when it lands. Dated rather than remembered, because `dropDevice` is also
   * the "get this phone off my machine" button, and a device that was kicked and
   * not revoked must still be able to connect again afterwards.
   */
  let sweep = 0
  const sweptAt = new Map<string, number>()

  function publicConnections(): RemoteConnection[] {
    const out: RemoteConnection[] = []
    for (const connection of live.values()) {
      // A socket that has not said hello is not a phone yet, and listing it
      // would put an unauthenticated stranger in the user's device list.
      if (!connection.deviceId) continue
      out.push({
        id: connection.id,
        deviceId: connection.deviceId,
        deviceName: connection.deviceName,
        platform: connection.platform,
        address: connection.address,
        connectedAt: connection.connectedAt,
        sessionIds: [...connection.handles.keys()],
      })
    }
    return out.sort((a, b) => a.connectedAt - b.connectedAt)
  }

  function announce(): void {
    try {
      options.onConnections?.(publicConnections())
    } catch (error) {
      console.error('[remote] connection listener threw:', error)
    }
  }

  function send(connection: LiveConnection, message: ServerMessage): void {
    connection.wire.send(serialize(message))
  }

  function refuse(connection: LiveConnection, code: ProtocolErrorCode, message: string, closeCode: number): void {
    send(connection, { t: 'error', code, message })
    connection.wire.close(closeCode, code)
  }

  function detachAll(connection: LiveConnection): void {
    for (const handle of connection.handles.values()) {
      try {
        options.sessions.detach(handle)
      } catch (error) {
        console.error('[remote] detach failed:', error)
      }
    }
    connection.handles.clear()
  }

  /**
   * The tail of a session's scrollback, in frames.
   *
   * Exported through `attach` rather than left to `chunkOutput` because the
   * whole buffer is not a safe thing to hand the sender: past
   * `MAX_BUFFERED_BYTES` the socket closes itself, and the phone reconnects into
   * the same attach and the same drop. Truncation is visible to the user as
   * scrollback that does not go back forever; the alternative is a session that
   * cannot be opened at all.
   */
  function replayOf(replay: string): string[] {
    let text = replay
    if (text.length > MAX_REPLAY_CHARS) {
      text = text.slice(-MAX_REPLAY_CHARS)
      // A cut at a fixed UTF-16 offset can land between the halves of a
      // surrogate pair, and a lone half is one replacement glyph at the top of
      // the screen for no reason.
      const first = text.charCodeAt(0)
      if (first >= 0xdc00 && first <= 0xdfff) text = text.slice(1)
    }
    const pieces = chunkOutput(text)
    return pieces.length > MAX_REPLAY_CHUNKS ? pieces.slice(-MAX_REPLAY_CHUNKS) : pieces
  }

  function attach(connection: LiveConnection, message: Extract<ClientMessage, { t: 'attach' }>): void {
    const id = message.id
    // Re-attaching is how a phone asks for its context again after a reconnect,
    // so it is not an error — it is a fresh subscription with a fresh replay.
    const existing = connection.handles.get(id)
    if (existing) {
      options.sessions.detach(existing)
      connection.handles.delete(id)
    }

    // Live output that arrives before the replay has been flushed is held back
    // rather than sent: out-of-order scrollback is worse than none, because it
    // reads as the agent having said things twice.
    let flushed = false
    const pending: string[] = []

    const handle = options.sessions.attach(
      id,
      (data) => {
        if (!flushed) {
          pending.push(data)
          return
        }
        for (const piece of chunkOutput(data)) send(connection, { t: 'output', id, data: piece })
      },
      (status) => send(connection, { t: 'status', id, status }),
      (exitCode) => send(connection, { t: 'exit', id, exitCode }),
    )

    if (!handle) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${id} is running.` })
      // The re-attach above already let go of the old subscription, so the
      // desktop's list of what this phone is watching has changed even though
      // the attach failed.
      if (existing) announce()
      return
    }

    connection.handles.set(id, handle)
    send(connection, { t: 'attached', id })
    for (const piece of replayOf(handle.replay)) {
      send(connection, { t: 'output', id, data: piece, replay: true })
    }
    flushed = true
    for (const held of pending) {
      for (const piece of chunkOutput(held)) send(connection, { t: 'output', id, data: piece })
    }

    // The size travels with the attach so the first screen arrives the right
    // shape. It reshapes the desktop's terminal too — there is one process and
    // one size — which is the honest behaviour of a shared session and the
    // reason a size is only ever applied when the phone actually sent one.
    if (message.cols !== undefined && message.rows !== undefined) {
      options.sessions.resize(id, message.cols, message.rows)
    }
    announce()
  }

  async function hello(connection: LiveConnection, message: Extract<ClientMessage, { t: 'hello' }>): Promise<void> {
    if (message.protocol !== PROTOCOL_VERSION) {
      refuse(
        connection,
        'version',
        `This phone app speaks protocol ${message.protocol}; the desktop speaks ${PROTOCOL_VERSION}. Update whichever is older.`,
        CLOSE.policyViolation,
      )
      return
    }

    const startedAt = sweep
    const outcome = await options.auth.authenticate(message.token, message.device, connection.address)
    // The socket can be gone by now: scrypt takes tens of milliseconds and the
    // hello timer keeps running through it.
    if (!live.has(connection.id)) return

    // And the device can have been revoked by now, in a sweep that could not see
    // this connection because it had not named itself yet. Same words as a plain
    // refusal: which of the two happened is not a remote caller's business.
    if (outcome.ok && (sweptAt.get(outcome.deviceId) ?? 0) > startedAt) {
      refuse(
        connection,
        'unauthorized',
        'This device is not allowed in. Pair it again from the Mac.',
        CLOSE.policyViolation,
      )
      return
    }

    if (!outcome.ok) {
      // A device that just paired still has to be approved at the Mac, and its
      // credential has to reach it or the pairing was for nothing. `welcome`
      // carries it with an empty session list, which is true: it has access to
      // none. The error frame and the close code say the rest.
      if (outcome.credential) {
        send(connection, {
          t: 'welcome',
          protocol: PROTOCOL_VERSION,
          deviceId: outcome.deviceId ?? '',
          deviceName: outcome.deviceName ?? message.device.name,
          token: outcome.credential,
          sessions: [],
        })
      }
      refuse(connection, 'unauthorized', outcome.message, CLOSE.policyViolation)
      return
    }

    connection.deviceId = outcome.deviceId
    connection.deviceName = outcome.deviceName
    // Taken from the hello rather than from the trust store: the store records
    // what the device called itself when it paired, and this is the phone in
    // front of you now. It is display text either way.
    connection.platform = message.device.platform
    if (connection.helloTimer) clearTimeout(connection.helloTimer)
    connection.helloTimer = null
    connection.wire.startHeartbeat(pingIntervalMs)
    send(connection, {
      t: 'welcome',
      protocol: PROTOCOL_VERSION,
      deviceId: outcome.deviceId,
      deviceName: outcome.deviceName,
      // Present exactly once, on the connection that paired.
      token: outcome.credential,
      sessions: options.sessions.list(),
    })
    announce()
  }

  function onMessage(connection: LiveConnection, raw: string): void {
    const parsed = parseClientMessage(raw)
    if (!parsed.ok) {
      refuse(connection, parsed.code, parsed.reason, CLOSE.protocolError)
      return
    }
    const message = parsed.message

    if (!connection.deviceId) {
      if (message.t !== 'hello') {
        // Not merely ignored: a client that talks before authenticating is
        // either broken or probing, and neither deserves a second try here.
        refuse(connection, 'unauthenticated', 'Say hello first.', CLOSE.policyViolation)
        return
      }
      if (connection.greeting) {
        refuse(connection, 'bad-message', 'One hello at a time.', CLOSE.protocolError)
        return
      }
      connection.greeting = true
      void hello(connection, message)
        .catch((error) => {
          console.error('[remote] hello failed:', error)
          refuse(connection, 'unauthorized', 'Could not check this device.', CLOSE.internalError)
        })
        .finally(() => {
          connection.greeting = false
        })
      return
    }

    switch (message.t) {
      case 'hello':
        // Already authenticated. A second hello would be a way to change
        // identity on a socket that is already attached to sessions.
        refuse(connection, 'bad-message', 'Already said hello.', CLOSE.protocolError)
        return
      case 'list':
        send(connection, { t: 'sessions', sessions: options.sessions.list() })
        return
      case 'attach':
        attach(connection, message)
        return
      case 'detach': {
        const handle = connection.handles.get(message.id)
        if (handle) {
          options.sessions.detach(handle)
          connection.handles.delete(message.id)
          announce()
        }
        send(connection, { t: 'detached', id: message.id })
        return
      }
      case 'input':
        // Attachment is the authorisation. Without this check a device could
        // type into any session whose id it guessed or remembered, including
        // ones it was never shown.
        if (!connection.handles.has(message.id)) {
          send(connection, {
            t: 'error',
            code: 'unauthorized',
            message: 'Attach to that session before typing into it.',
          })
          return
        }
        options.sessions.write(message.id, message.data)
        return
      case 'resize':
        if (!connection.handles.has(message.id)) {
          send(connection, {
            t: 'error',
            code: 'unauthorized',
            message: 'Attach to that session before resizing it.',
          })
          return
        }
        options.sessions.resize(message.id, message.cols, message.rows)
        return
      case 'ping':
        send(connection, { t: 'pong' })
        return
    }
  }

  function handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    const path = (req.url ?? '/').split('?')[0]
    if (path !== WS_PATH) return refuseUpgrade(socket, 404, 'Not Found')
    if (!hostAllowed(req.headers.host, hosts)) return refuseUpgrade(socket, 403, 'Forbidden')
    if (!originAllowed(req.headers.origin, hosts)) return refuseUpgrade(socket, 403, 'Forbidden')
    // Refused before the handshake rather than after: a socket that is over the
    // ceiling should never become one of the objects the ceiling is counting.
    if (live.size >= MAX_CONNECTIONS) return refuseUpgrade(socket, 503, 'Service Unavailable')

    const upgrade = String(req.headers.upgrade ?? '').toLowerCase()
    const key = req.headers['sec-websocket-key']
    const version = String(req.headers['sec-websocket-version'] ?? '')
    if (upgrade !== 'websocket' || typeof key !== 'string' || version !== '13') {
      return refuseUpgrade(socket, 400, 'Bad Request')
    }

    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n` +
        '\r\n',
    )

    const connection: LiveConnection = {
      id: randomUUID(),
      wire: undefined as unknown as WireSocket,
      address: req.socket.remoteAddress ?? 'unknown',
      connectedAt: Date.now(),
      deviceId: null,
      deviceName: '',
      platform: '',
      handles: new Map(),
      helloTimer: null,
      greeting: false,
    }

    connection.wire = new WireSocket(socket, maxMessageBytes, {
      message: (text) => onMessage(connection, text),
      closed: () => {
        if (!live.delete(connection.id)) return
        if (connection.helloTimer) clearTimeout(connection.helloTimer)
        connection.helloTimer = null
        const wasAuthenticated = connection.deviceId !== null
        detachAll(connection)
        if (wasAuthenticated) announce()
      },
    })

    // An unauthenticated socket costs a file descriptor and a slot; it does not
    // get to keep either indefinitely.
    connection.helloTimer = setTimeout(() => {
      if (connection.deviceId) return
      connection.wire.close(CLOSE.policyViolation, 'no hello')
    }, helloTimeoutMs)
    connection.helloTimer.unref?.()

    live.set(connection.id, connection)
    // Bytes that arrived in the same TCP segment as the handshake. Dropping
    // them loses the client's first message roughly one time in a hundred.
    if (head.length > 0) socket.unshift(head)
  }

  function handleRequest(req: IncomingMessage, res: ServerResponse): void {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { allow: 'GET, HEAD' })
      res.end()
      return
    }
    if (!hostAllowed(req.headers.host, hosts)) {
      res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' })
      res.end('forbidden')
      return
    }
    void serveStatic(options.webRoot, req, res).catch(() => {
      if (!res.headersSent) res.writeHead(500)
      res.end()
    })
  }

  return {
    handleRequest,
    handleUpgrade,
    connections: publicConnections,
    dropDevice(deviceId: string): number {
      sweep += 1
      sweptAt.set(deviceId, sweep)
      // Bounded: only a revoke reaches here, and the trust store caps devices
      // long before this. The oldest marker is the safest one to lose — it is
      // the one whose in-flight authentications have long since landed.
      while (sweptAt.size > MAX_DROPPED_TRACKED) {
        const oldest = [...sweptAt.entries()].sort((a, b) => a[1] - b[1])[0]
        if (!oldest) break
        sweptAt.delete(oldest[0])
      }

      let dropped = 0
      for (const connection of [...live.values()]) {
        if (connection.deviceId !== deviceId) continue
        connection.wire.close(CLOSE.policyViolation, 'access revoked')
        dropped += 1
      }
      return dropped
    },
    dropConnection(connectionId: string): boolean {
      const connection = live.get(connectionId)
      // Not a revoke: the device stays paired and may connect again. This is
      // the "get off my machine right now" button, which is a different thing
      // from "never again" and is why both exist.
      if (!connection) return false
      connection.wire.close(CLOSE.goingAway, 'disconnected from the desktop')
      return true
    },
    closeAll(): void {
      for (const connection of [...live.values()]) connection.wire.close(CLOSE.goingAway, 'server stopping')
    },
  }
}

/* ---------------------------------------------------------------- adapters -- */

/**
 * The one pairing code that is on screen.
 *
 * `RemoteAuth` will happily keep sixteen live tokens at once, which is right
 * for a library and wrong for this UI: the panel shows one code, so exactly one
 * code should open the door. Narrowing it here is also what makes Cancel real —
 * the trust store has no way to un-mint a token, and a Cancel button that only
 * stops drawing the code is a button that lies.
 */
export interface PairingDesk {
  create(): PairingToken
  cancel(): void
  /** True only for the code currently on screen, and only before it expires. */
  offers(token: string): boolean
}

export function pairingDesk(auth: RemoteAuth, now: () => number = Date.now): PairingDesk {
  let live: { digest: Buffer; expiresAt: number } | null = null
  const digestOf = (value: string): Buffer => createHash('sha256').update(value).digest()

  return {
    create(): PairingToken {
      const minted = auth.createPairingToken()
      // Only the digest is kept, for the same reason `RemoteAuth` keeps only a
      // digest: nothing in this process should hold a live bearer secret after
      // the call that showed it has returned.
      live = { digest: digestOf(minted.token), expiresAt: minted.expiresAt }
      return minted
    },
    cancel(): void {
      live = null
    },
    offers(token: string): boolean {
      if (!live) return false
      if (now() >= live.expiresAt) {
        live = null
        return false
      }
      return timingSafeEqual(digestOf(token), live.digest)
    },
  }
}

/**
 * The policy that turns `RemoteAuth` into a `hello` answer.
 *
 * Which secret is in the field is decided by shape, not by trust: a credential
 * is `<deviceId>.<secret>` and a pairing token is base64url of 32 random bytes,
 * so the dot separates them with no ambiguity. Guessing wrong would only send
 * the value down the other path, where it fails the same way — the shape check
 * saves a scrypt run per pairing, it does not decide anything.
 *
 * Failure text is deliberately vague where the real reason is not. `RemoteAuth`
 * distinguishes unknown from revoked from rate-limited for the desktop's log;
 * telling a remote caller which one it hit is a free oracle.
 */
export function authenticatorFor(auth: RemoteAuth, desk: PairingDesk): RemoteAuthenticator {
  return {
    async authenticate(token, device, address): Promise<AuthOutcome> {
      if (token.includes('.')) {
        const verified = await auth.verifyCredential(token, address)
        if (verified.ok) {
          return { ok: true, deviceId: verified.device.id, deviceName: verified.device.name, credential: null }
        }
        return {
          ok: false,
          message:
            verified.reason === 'pending'
              ? 'This device is waiting to be approved. Approve it on the Mac, then reconnect.'
              : verified.reason === 'rate-limited'
                ? 'Too many failed attempts. Try again later.'
                : 'This device is not allowed in. Pair it again from the Mac.',
        }
      }

      // Checked before redeeming rather than after, so a cancelled code cannot
      // create a device row on its way to being refused. It costs the rate
      // limiter a sighting of the guess, which is a trade this token can
      // afford: it is 256 bits from `randomBytes`, not something a person
      // chose, so guessing it is infeasible whether or not anyone is counting.
      // The limiter still sees every attempt on the path an attacker actually
      // has, which is `verifyCredential` above.
      if (!desk.offers(token)) {
        return { ok: false, message: 'That pairing code is not right.' }
      }

      const redeemed = await auth.redeemPairingToken(token, device.name, address)
      if (!redeemed.ok) {
        return {
          ok: false,
          message:
            redeemed.reason === 'expired' || redeemed.reason === 'used'
              ? 'That pairing code has already been used or has expired. Create a new one on the Mac.'
              : redeemed.reason === 'rate-limited'
                ? 'Too many failed attempts. Try again later.'
                : 'That pairing code is not right.',
        }
      }

      // Paired, and deliberately not admitted: a token can be read over a
      // shoulder, so a human at the Mac approves the device before it opens
      // anything. The credential still has to travel, or the phone can never
      // come back.
      return {
        ok: false,
        message: 'Paired. Approve this device on the Mac, then reconnect.',
        credential: redeemed.credential,
        deviceId: redeemed.device.id,
        deviceName: redeemed.device.name,
      }
    },
  }
}

/** `tailscale cert` hands back paths; a TLS server needs the bytes. */
async function loadCert(dnsName: string, dir: string): Promise<CertLoad> {
  const issued = await ensureCert(dnsName, dir)
  if (!issued.ok) return { ok: false, message: issued.message }
  try {
    const [cert, key] = await Promise.all([
      readFile(issued.certPath, 'utf8'),
      readFile(issued.keyPath, 'utf8'),
    ])
    return { ok: true, cert, key }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error)
    return { ok: false, message: `Tailscale issued a certificate but it could not be read: ${detail}` }
  }
}

/* --------------------------------------------------------------- lifecycle -- */

/**
 * The whole server: tailnet address, certificate, HTTPS, WebSocket.
 *
 * `start()` resolves with a status rather than throwing. Every way it can fail —
 * Tailscale off, signed out, HTTPS not enabled on the tailnet, port taken — is
 * something the user fixes somewhere else, so it has to arrive as a sentence
 * the settings panel can show, not as a stack trace in a console nobody opens.
 */
export function createRemoteServer(options: RemoteServerOptions): RemoteServer {
  const port = options.port ?? DEFAULT_PORT
  const readTailnet = options.readTailnet ?? (() => tailnetStatus())
  const readCert = options.readCert ?? loadCert

  let servers: HttpsServer[] = []
  let endpoint: RemoteEndpoint | null = null
  let current: { url: string; address: string } | null = null
  let reason: string | null = null
  let starting: Promise<RemoteStatus> | null = null

  function snapshot(): RemoteStatus {
    return {
      running: servers.length > 0,
      url: current?.url ?? null,
      address: current?.address ?? null,
      port,
      reason,
      connections: endpoint?.connections() ?? [],
    }
  }

  function failure(message: string): RemoteStatus {
    reason = message
    current = null
    return snapshot()
  }

  async function listenOn(server: HttpsServer, address: string): Promise<void> {
    await new Promise<void>((settle, fail) => {
      const onError = (error: Error): void => {
        server.close()
        fail(error)
      }
      server.once('error', onError)
      server.listen(port, address, () => {
        server.removeListener('error', onError)
        // From here the server needs a permanent error listener: an emitter
        // without one rethrows, and a failed accept would take the app down.
        server.on('error', (error) => console.error('[remote] server error:', error))
        settle()
      })
    })
  }

  async function open(): Promise<RemoteStatus> {
    const tailnet = await readTailnet()
    if (!tailnet.ready) return failure(tailnet.reason)
    if (!tailnet.magicDns || tailnet.dnsName === '') {
      return failure(
        'MagicDNS is off for this tailnet, so this Mac has no name a phone can trust a certificate for. Turn MagicDNS on in the Tailscale admin console, then try again.',
      )
    }

    const cert = await readCert(tailnet.dnsName, options.certDir)
    if (!cert.ok) return failure(cert.message)

    const hosts =
      options.hosts ??
      [
        tailnet.dnsName,
        `${tailnet.dnsName}:${port}`,
        `${tailnet.address}:${port}`,
        ...(tailnet.address6 ? [`[${tailnet.address6}]:${port}`] : []),
      ]
    const live = createRemoteEndpoint({ ...options, hosts })

    // MagicDNS answers with both an A and an AAAA record. Binding only the IPv4
    // address leaves a v6-preferring phone waiting for Happy Eyeballs to give up
    // on every single connection, so both tailnet addresses get a listener — and
    // still only tailnet addresses.
    const addresses = tailnet.address6 ? [tailnet.address, tailnet.address6] : [tailnet.address]
    const opened: HttpsServer[] = []
    try {
      for (const address of addresses) {
        const server = createHttpsServer({ cert: cert.cert, key: cert.key }, live.handleRequest)
        server.on('upgrade', live.handleUpgrade)
        // A phone that drops mid-handshake is routine, not a crash.
        server.on('clientError', (_error, socket) => socket.destroy())
        await listenOn(server, address)
        opened.push(server)
      }
    } catch (error) {
      for (const server of opened) server.close()
      const message = error instanceof Error ? error.message : String(error)
      return failure(
        /EADDRINUSE/.test(message)
          ? `Port ${port} on the tailnet address is already in use by something else on this Mac.`
          : `Could not listen on the tailnet address: ${message}`,
      )
    }

    servers = opened
    endpoint = live
    reason = null
    current = { url: `https://${tailnet.dnsName}:${port}/`, address: tailnet.address }
    return snapshot()
  }

  return {
    async start(): Promise<RemoteStatus> {
      if (servers.length > 0) return snapshot()
      // Two clicks on Start would otherwise each bind a socket, and the second
      // set is left listening with nothing holding a reference to it.
      if (starting) return starting
      starting = open().finally(() => {
        starting = null
      })
      return starting
    },

    async stop(): Promise<RemoteStatus> {
      if (starting) {
        try {
          await starting
        } catch {
          /* A start that failed left nothing to stop. */
        }
      }
      endpoint?.closeAll()
      const closing = servers
      servers = []
      current = null
      await Promise.all(
        closing.map(
          (server) =>
            new Promise<void>((settle) => {
              server.close(() => settle())
              // A phone holding an idle connection must not hold up shutdown.
              server.closeAllConnections?.()
            }),
        ),
      )
      endpoint = null
      return snapshot()
    },

    url: () => current?.url ?? null,
    connections: () => endpoint?.connections() ?? [],
    dropDevice: (deviceId) => endpoint?.dropDevice(deviceId) ?? 0,
    dropConnection: (connectionId) => endpoint?.dropConnection(connectionId) ?? false,
    status: snapshot,
  }
}

/* --------------------------------------------------------------------- ipc -- */

/** Main → renderer. Fires when a phone authenticates, attaches, detaches or leaves. */
export const REMOTE_CONNECTIONS_CHANNEL = 'remote:connections'

export interface RemoteIpcDeps {
  sessions: SessionAccess
  /** Built PWA directory. */
  webRoot: string
  /** Directory for the device trust file and the certificate pair, under userData. */
  storageDir: string
  port?: number
  /** Push an event at the renderer. `index.ts` already has exactly this function. */
  broadcast(channel: string, payload: unknown): void
}

export interface RemoteIpc {
  server: RemoteServer
  auth: RemoteAuth
}

/**
 * One registration for the whole feature.
 *
 * Every channel here is `handle`/`invoke`. There is deliberately no `on`/`send`
 * channel: each call wants an answer — did it start, what is the code, did the
 * revoke land — and a fire-and-forget send that silently routes nowhere is the
 * bug this codebase keeps re-finding.
 */
export function registerRemoteIpc(ipcMain: IpcMain, deps: RemoteIpcDeps): RemoteIpc {
  const auth = new RemoteAuth(deps.storageDir)
  const desk = pairingDesk(auth)
  const server = createRemoteServer({
    sessions: deps.sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: deps.webRoot,
    certDir: deps.storageDir,
    port: deps.port,
    onConnections: (connections) => deps.broadcast(REMOTE_CONNECTIONS_CHANNEL, connections),
  })

  ipcMain.handle('remote:status', (): RemoteStatus => server.status())
  ipcMain.handle('remote:start', (): Promise<RemoteStatus> => server.start())
  ipcMain.handle('remote:stop', (): Promise<RemoteStatus> => server.stop())

  ipcMain.handle('remote:pair', (): PairingToken => desk.create())
  ipcMain.handle('remote:pair:cancel', (): { cancelled: true } => {
    desk.cancel()
    return { cancelled: true }
  })

  ipcMain.handle('remote:connection:disconnect', (_event, id: unknown): RemoteConnection[] => {
    if (typeof id === 'string') server.dropConnection(id)
    return server.connections()
  })

  ipcMain.handle('remote:devices', (): Device[] => auth.listDevices())
  ipcMain.handle('remote:device:approve', (_event, id: unknown): Device[] => {
    if (typeof id === 'string') auth.approveDevice(id)
    return auth.listDevices()
  })
  ipcMain.handle('remote:device:revoke', (_event, id: unknown): Device[] => {
    if (typeof id === 'string' && auth.revokeDevice(id)) {
      // A revoke that only applied to the next connection would not be one:
      // the phone that is already attached has to lose the socket it is
      // holding, now.
      server.dropDevice(id)
    }
    return auth.listDevices()
  })

  return { server, auth }
}
