/**
 * The server a phone talks to.
 *
 * HTTPS for the PWA, one WebSocket for the sessions, bound to nothing but this
 * machine's tailnet address. Four decisions carry the whole design.
 *
 * **It listens on the tailnet or it does not listen.** `0.0.0.0` would put a
 * terminal on every network this laptop ever joins, and a LAN address would put
 * one on the coffee shop's. `tailnet.ts` reads the address from the running
 * daemon; if it cannot, no socket is opened. There is no option to override
 * this, because an option is a thing someone eventually sets.
 *
 * That rule is about *listening*, and it is unchanged. What did change is that
 * listening is no longer the only way in: `relay-client.ts` dials **out** to a
 * rendezvous service and hands the channels it gets back to `attachTransport`
 * below, which is the same door a tailnet socket comes through. So a Mac with
 * no Tailscale is reachable, and a Mac with Tailscale is reachable faster,
 * without either path being able to open a port on this machine.
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
// Plain HTTP on loopback, not HTTPS. Tailscale terminates TLS in front of it;
// see ./tailscale-serve for why it cannot be done in-process.
import { stat } from 'node:fs/promises'
import { createServer as createPlainServer, type Server as LocalServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import { extname, join, normalize, resolve, sep } from 'node:path'
import type { IpcMain } from 'electron'
import { RemoteAuth, type Device, type PairingToken } from './device-auth'
import {
  CAPABILITIES,
  CAPABILITY,
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
import {
  MAX_STREAMS_TOTAL,
  createTunnelHub,
  streamBudget,
  type LocalhostMessage,
  type TunnelHub,
  type TunnelInfo,
  type TunnelPort,
} from './tunnel'
import {
  createUploadDesk,
  diskUploadStore,
  type UploadDesk,
  type UploadMessage,
} from './uploads'
import { scanDevPortsDetailed } from '../dev-ports'
import { machineNoun } from '../platform/host'
import { createRelayClient, relayEnabled, relayUrl, type RelayLink, type RelayState } from './relay-client'
import { loadHostIdentity } from './host-identity'
import { tailnetStatus, type TailnetStatus } from './tailnet'
import { serveOff, serveOn } from './tailscale-serve'
import { FrameReader, OPCODE, acceptKey, encodeFrame } from '../../shared/ws-frame'

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
 * What a phone asked for when it asked for a session.
 *
 * The shape `parseClientMessage` produced, minus the tag — this server does not
 * decide what any of it means. `cwd` is a folder the *phone* named and nothing
 * has checked yet; whether this Mac will start a session there is a question
 * only the session layer can answer, because only it can see the desktop's
 * project list.
 */
export interface CreateRequest {
  cwd?: string
  cols?: number
  rows?: number
}

/**
 * What the session layer says about a request to start one.
 *
 * A refusal carries its own code because the two refusals mean genuinely
 * different things to the person holding the phone. `unauthorized` is "this Mac
 * will not start a session in that folder", which is a policy answer and stays
 * true however many times it is retried. `unavailable` is "it would have, and
 * it could not" — a folder deleted since it was listed, a shell that will not
 * spawn — which is worth trying again. Collapsing them would send someone to
 * the pairing screen to fix a missing directory.
 */
export type CreateOutcome =
  | { ok: true; session: RemoteSession }
  | { ok: false; code: 'unauthorized' | 'unavailable'; message: string }

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
  /**
   * Start a session, or say why not. **Optional, and its absence is the switch.**
   *
   * A session layer that cannot start anything simply does not have this
   * method, and the `create` capability is then never advertised — so a phone
   * talking to such a host never draws a New Session button and never sends a
   * frame that would be refused. That is the whole of the negotiation, and it
   * is why this is optional rather than a method that always exists and
   * sometimes returns a refusal: a capability list assembled from a boolean
   * somebody has to remember to set is a capability list that will one day lie.
   *
   * Asynchronous because starting a real session is: the desktop resolves the
   * login shell's PATH and probes which agent CLIs are installed before it
   * spawns anything, and both of those are `execFile`.
   */
  create?(request: CreateRequest): Promise<CreateOutcome>
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
  /**
   * `peerPublicKey` is set only for a connection that arrived through a relay,
   * where a Noise handshake has already proved the far end holds the private
   * half. It is a second, independent fact about the caller — the credential
   * says *what* it knows, this says *which device it is* — and the authenticator
   * is expected to insist the two agree. Null on the tailnet, where there is no
   * handshake to have proved anything with.
   */
  authenticate(
    token: string,
    device: DeviceDescriptor,
    address: string,
    peerPublicKey?: Buffer | null,
  ): Promise<AuthOutcome>
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
  /**
   * Ports on this Mac this phone currently has a page open on.
   *
   * Listed for the same reason the sessions are: while a tunnel is live, a
   * browser on somebody's phone is talking to a server on this machine, and the
   * person at the machine should be able to see that and end it. Empty for
   * every phone that has not tapped a port, which is most of them.
   */
  tunnels: TunnelInfo[]
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
  /**
   * What is listening on this machine, for the `localhost` capability.
   *
   * Injected so the socket tests never spawn `lsof`, and so the one place that
   * decides which ports a phone may be offered is a function this file is
   * handed rather than a module it reaches for. Defaults to the real scan.
   *
   * Returns {@link TunnelPort}, which is `LocalPort` plus the address families
   * the tunnel dials by — optional, so a stand-in that only knows port numbers
   * still fits. What reaches the phone is trimmed back to `LocalPort` in
   * `tunnel.ts`; the extra field never leaves this process.
   */
  scanPorts?: () => Promise<readonly TunnelPort[]>
  /**
   * Ports this app is serving on itself, which it will not tunnel to.
   *
   * Tunnelling to our own listener would let a phone reach the desktop's static
   * file server through the connection it is already holding, which is a loop
   * with nothing on the other end of it.
   */
  reservedPorts?: number[]
  /**
   * Where files sent from a phone land. **Absent is the switch.**
   *
   * A host with no directory does not advertise the `upload` capability, so a
   * phone talking to it never draws a Send File button and never sends a frame
   * that would be refused — the same negotiation `SessionAccess.create` gets, and
   * for the same reason. It is a path rather than a boolean because there is no
   * sensible default this module could compute: `app.getPath('downloads')` needs
   * Electron, and a module that guessed at a folder in someone's home directory
   * would be the one place in this feature where a path is invented rather than
   * given. `registerRemoteIpc` fills it in.
   *
   * Created on the first upload, not here: a folder made at startup for a
   * feature nobody has used is litter in somebody's Downloads.
   */
  uploadsDir?: string
}

export interface RemoteEndpoint {
  handleRequest(req: IncomingMessage, res: ServerResponse): void
  handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void
  /**
   * Bring a connection into being over something that is not an HTTP upgrade.
   *
   * The relay's channels arrive this way. Everything past this call —
   * authentication, the hello timeout, attach, revocation — is the same code
   * that serves a phone on the tailnet, which is the entire reason the wire is
   * an interface rather than a socket.
   */
  attachTransport: AttachTransport
  connections(): RemoteConnection[]
  /** Close every socket held by one device. Returns how many were dropped. */
  dropDevice(deviceId: string): number
  /** Close one socket, leaving the device paired. False when it had already gone. */
  dropConnection(connectionId: string): boolean
  /** End one localhost tunnel from the Mac. False when it had already gone. */
  stopTunnel(connectionId: string, tunnelId: string): boolean
  closeAll(): void
}

export interface RemoteServerOptions extends RemoteEndpointOptions {
  /** Where `tailscale cert` keeps the PEM pair. */
  certDir: string
  port?: number
  /**
   * Puts a TLS proxy in front of the loopback listener. Injectable so tests do
   * not shell out to tailscale; defaults to the real one.
   */
  serve?: {
    on(httpsPort: number, localPort: number): Promise<{ ok: boolean; url?: string; message?: string }>
    off(httpsPort: number): Promise<void>
  }
  /** Test seams. Both default to the real thing in `tailnet.ts`. */
  readTailnet?: () => Promise<TailnetStatus>
  /**
   * The outbound link to a rendezvous relay, or nothing.
   *
   * Injected rather than built here, and absent by default, for two reasons that
   * point the same way: a relay needs this Mac's persisted identity and the
   * device trust store, neither of which this function has, and a server
   * constructed in a test must not dial the public internet. `registerRemoteIpc`
   * is where the real one is assembled, which is also the only place that knows
   * whether the user has switched the feature on.
   */
  relay?: RelayLink
}

/** What the server needs to open a listener: the PEM text, not the paths. */
export type CertLoad = { ok: true; cert: string; key: string } | { ok: false; message: string }

export interface RemoteStatus {
  running: boolean
  /**
   * What to open on the phone, for the direct path. Null when there is no
   * direct path — a relayed connection has no URL at all; the phone finds this
   * Mac by the host id in `relay`.
   */
  url: string | null
  address: string | null
  port: number
  /** Why nothing at all is running, in a sentence a person can act on. */
  reason: string | null
  /**
   * Why the *direct* tailnet path is not up, while something else is.
   *
   * Separate from `reason` on purpose: with a relay carrying the session, "this
   * Mac is signed out of Tailscale" is a note about a faster route, not a
   * failure, and printing it as one is how a panel teaches people to ignore it.
   */
  directReason: string | null
  /** The relay link, when one is running. Null when the feature is off or unconfigured. */
  relay: RelayState | null
  connections: RemoteConnection[]
}

export interface RemoteServer {
  start(): Promise<RemoteStatus>
  stop(): Promise<RemoteStatus>
  url(): string | null
  connections(): RemoteConnection[]
  dropDevice(deviceId: string): number
  dropConnection(connectionId: string): boolean
  stopTunnel(connectionId: string, tunnelId: string): boolean
  status(): RemoteStatus
  /**
   * The machine woke from sleep. Re-dial the relay now instead of waiting.
   *
   * Driven by `powerMonitor.on('resume')` in `index.ts`, because an event that
   * already exists beats a timer that watches the clock hoping to infer it. A
   * link that slept through a suspend is usually dead and TCP will not say so
   * for minutes — minutes during which a phone cannot reach this Mac.
   */
  wake(): void
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

/**
 * The framing itself lives in `shared/ws-frame` because the relay decodes and
 * re-encodes the same frames. Re-exported here so this module stays the one
 * place the rest of the app looks for the remote wire.
 */
export { acceptKey, encodeFrame, OPCODE } from '../../shared/ws-frame'

export interface WireHandlers {
  message(text: string): void
  closed(): void
}

/**
 * How a carrier hands this server a new connection.
 *
 * `connect` is a factory rather than a finished wire because the wire needs the
 * handlers and the handlers need the connection — the two are mutually
 * recursive, and a factory is how that knot gets tied without a cast.
 *
 * Returns false when the server is full, in which case nothing was registered
 * and the carrier should close whatever it was holding. `peerPublicKey` is the
 * device's X25519 static key when the carrier has already authenticated one.
 */
export type AttachTransport = (
  address: string,
  connect: (handlers: WireHandlers) => RemoteWire,
  peerPublicKey?: Buffer,
) => boolean

/**
 * Everything a connection needs from whatever is carrying it.
 *
 * A `WireSocket` over TCP is one implementation. The relay transport is
 * another: the same protocol messages, sealed and posted through a rendezvous
 * server, with no HTTP upgrade and no socket of its own.
 *
 * Naming this interface is what lets the authentication, session and protocol
 * layers below stay completely unaware of how a phone got here — which is the
 * property that made adding the relay a new file rather than a second copy of
 * this one.
 */
export interface RemoteWire {
  send(text: string): void
  close(code: number, reason?: string): void
  /**
   * Start liveness checking, once the connection has said who it is.
   *
   * Optional because it is a property of the carrier, not of the protocol. A
   * TCP socket needs it — a phone that drives into a tunnel leaves a connection
   * that looks open for minutes, holding an attached session with it. A relayed
   * connection does not: the relay pings its own two sockets and tears the
   * channel down when either stops answering, so a second heartbeat inside the
   * first would only duplicate the work and the failure.
   */
  startHeartbeat?(intervalMs: number): void
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
  private readonly reader: FrameReader
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
    this.reader = new FrameReader(maxMessageBytes)
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
    this.reader.reset()
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
    const batch = this.reader.push(chunk)

    // Good frames are delivered even when the chunk ended in a bad one, and in
    // order, because the frame before a protocol error is usually the one that
    // explains it. `finished` is re-checked each pass: handing a message to the
    // app can close the connection, and the frames behind it are then moot.
    for (const { fin, opcode, payload } of batch.frames) {
      if (this.finished) return
      this.frame(fin, opcode, payload)
    }

    if (batch.ok || this.finished) return
    const { reason, detail } = batch.error
    this.fail(reason === 'too-large' ? CLOSE.messageTooBig : CLOSE.protocolError, detail)
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
  wire: RemoteWire
  address: string
  connectedAt: number
  deviceId: string | null
  deviceName: string
  platform: string
  /** Proved by the carrier's own handshake, before any of this ran. Null on the tailnet. */
  peerPublicKey: Buffer | null
  handles: Map<string, SessionHandle>
  /**
   * Made on the first `localhost` verb and not before.
   *
   * Most phones never tap a port, and a hub that exists for all of them is a
   * budget entry, a scan cache and a socket map per connection for a feature
   * nobody used.
   */
  tunnels: TunnelHub | null
  /**
   * Made on the first `upload` verb and not before, for the same reason.
   *
   * It also holds an open file descriptor while a file is arriving, which is the
   * stronger version of the argument: a desk per connection, made eagerly, would
   * be sixty-four objects on a machine where nobody has sent anything.
   */
  uploads: UploadDesk | null
  helloTimer: NodeJS.Timeout | null
  /**
   * Set while a `hello` is being checked. Verification is asynchronous — scrypt
   * takes tens of milliseconds — and the socket is still readable throughout,
   * so without this a client that sends two hellos in one segment gets both
   * checked at once, against a connection that is unauthenticated for both.
   */
  greeting: boolean
  /**
   * Set while a `create` is being served.
   *
   * Spawning is asynchronous and the socket keeps reading throughout, so
   * without this a double-tap on the phone's button — or a client that retries
   * because the first answer was slow — starts two shells on somebody's Mac and
   * only shows them one. The same reason `greeting` exists, for the same window.
   */
  creating: boolean
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
  const scanPorts = options.scanPorts ?? ((): Promise<readonly TunnelPort[]> => scanDevPortsDetailed())
  // One budget for the whole endpoint, handed to every hub it makes. Per-phone
  // caps alone would let sixty-four paired devices exhaust this process's
  // descriptors between them.
  const streams = streamBudget(MAX_STREAMS_TOTAL)

  /**
   * What this desktop tells a phone it can do, computed from what it can do.
   *
   * Read off the injected session layer rather than from a constant, so the
   * advertisement cannot outlive the thing it advertises. `scripts/remote-host.ts`
   * ran for weeks with a session layer that could not list, attach or start
   * anything; had `create` been a constant it would have offered a button that
   * could only ever produce a refusal.
   *
   * Computed once: the session layer is injected at construction and does not
   * grow methods afterwards, and a `welcome` is not a place to be doing work.
   */
  const advertised: string[] = CAPABILITIES.filter((name) => {
    if (name === CAPABILITY.create) return typeof options.sessions.create === 'function'
    // Same rule, same reason: the thing that makes the feature possible is the
    // thing that decides whether it is offered. A host with nowhere to put a file
    // must not draw a Send File button on somebody's phone.
    if (name === CAPABILITY.upload) return typeof options.uploadsDir === 'string' && options.uploadsDir !== ''
    return true
  })

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
        tunnels: connection.tunnels?.list() ?? [],
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

  /**
   * The tunnel hub for one phone, made on demand.
   *
   * Only ever called from the authenticated branch of `onMessage`, which is the
   * whole of the authorisation for this feature: a socket that has not said
   * hello, or whose device a human has not approved, never reaches the call.
   * See `tunnel.ts` for what the hub itself will and will not dial.
   */
  function hubFor(connection: LiveConnection): TunnelHub {
    if (connection.tunnels) return connection.tunnels
    const hub = createTunnelHub({
      scan: scanPorts,
      send: (message) => send(connection, message),
      reserved: options.reservedPorts,
      budget: streams,
      // The desktop's device list shows a phone's live tunnels next to its
      // sessions, so opening or closing one has to redraw it for the same
      // reason attaching does.
      onChange: announce,
    })
    connection.tunnels = hub
    return hub
  }

  /**
   * The upload desk for one phone, made on demand.
   *
   * Reached only from the authenticated branch of `onMessage`, which is the whole
   * of the authorisation for writing a file to this Mac — the same gate that
   * guards typing into a terminal. Null when this host has nowhere to put a file,
   * in which case the capability was never advertised and the caller refuses.
   */
  function deskFor(connection: LiveConnection): UploadDesk | null {
    if (connection.uploads) return connection.uploads
    const dir = options.uploadsDir
    if (dir === undefined || dir === '') return null
    const desk = createUploadDesk({
      store: diskUploadStore(dir),
      send: (message) => send(connection, message),
    })
    connection.uploads = desk
    return desk
  }

  function detachAll(connection: LiveConnection): void {
    connection.tunnels?.closeAll()
    connection.tunnels = null
    // Before the handles, because this deletes half-written files. A partial
    // video left in someone's Downloads wearing a real name is the one piece of
    // state a dropped socket must not leave behind.
    connection.uploads?.closeAll()
    connection.uploads = null
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
    const outcome = await options.auth.authenticate(
      message.token,
      message.device,
      connection.address,
      connection.peerPublicKey,
    )
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
        'This device is not allowed in. Pair it again from the desktop app.',
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
          // Nothing is advertised to a device that is not in yet. What this
          // desktop can do is not a secret, but this connection is about to be
          // closed and a capability list would only invite it to try one.
          capabilities: [],
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
    connection.wire.startHeartbeat?.(pingIntervalMs)
    send(connection, {
      t: 'welcome',
      protocol: PROTOCOL_VERSION,
      deviceId: outcome.deviceId,
      deviceName: outcome.deviceName,
      // Present exactly once, on the connection that paired.
      token: outcome.credential,
      sessions: options.sessions.list(),
      capabilities: advertised,
    })
    announce()
  }

  /**
   * Start a session because a phone asked.
   *
   * Three gates, in this order, and the order is the point. The socket is
   * already authenticated — `onMessage` will not reach this for a connection
   * with no `deviceId`, and a device only has one after `RemoteAuth` matched a
   * credential *and* a human approved the device on the Mac. Then the
   * capability: a `create` arriving at a host that never advertised one is
   * refused here rather than passed on, because a client that sends an
   * unadvertised verb is not a client of ours. Then the session layer, which
   * owns the only question left — whether this Mac will start a session in the
   * folder that was named.
   *
   * Creating is at least as sensitive as typing, and it is more so in one
   * respect: `input` can only reach a session this device has attached to,
   * whereas this makes a *new* process. What keeps it honest is that the phone
   * cannot name anything the desktop has not already offered it — see
   * `CreateRequest`.
   */
  async function create(connection: LiveConnection, message: Extract<ClientMessage, { t: 'create' }>): Promise<void> {
    const start = options.sessions.create
    if (!start) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'Sessions cannot be started from a phone here.',
      })
      return
    }

    if (connection.creating) {
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: 'A session is already starting. Wait for it to appear.',
      })
      return
    }

    connection.creating = true
    let outcome: CreateOutcome
    try {
      outcome = await start({ cwd: message.cwd, cols: message.cols, rows: message.rows })
    } finally {
      connection.creating = false
    }
    // The phone can be gone by now: spawning resolves a login shell's PATH and
    // probes for agent CLIs, which is two `execFile` calls and tens of
    // milliseconds. The session is still real and still on the Mac — that is
    // the honest outcome of "start something", and it will be in the next
    // `list` — but there is no socket left to tell about it.
    if (!live.has(connection.id)) return

    if (!outcome.ok) {
      send(connection, { t: 'error', code: outcome.code, message: outcome.message })
      return
    }

    send(connection, { t: 'created', session: outcome.session })
    // Everyone else hears about it as an ordinary list refresh. `created` is a
    // capability frame and the phone that did not ask for it may never have
    // heard of it; `sessions` is v1 and every client back to the first one
    // understands it.
    const sessions = options.sessions.list()
    for (const other of live.values()) {
      if (other.id === connection.id || !other.deviceId) continue
      send(other, { t: 'sessions', sessions })
    }
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
      case 'create':
        // Not awaited: the message loop is the socket's data handler and must
        // not stop reading for the length of a spawn. A rejection is impossible
        // by contract and caught anyway — an unhandled rejection on this path
        // would be a main process that exits while a phone is holding a shell.
        void create(connection, message).catch((error) => {
          console.error('[remote] create failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That session could not be started.',
          })
        })
        return
      case 'ports':
      case 'tunnel.open':
      case 'tunnel.close':
      case 'net.open':
      case 'net.data':
      case 'net.ack':
      case 'net.close':
        // Listed one by one rather than caught by a default, so that adding a
        // verb to the protocol without deciding where it belongs stops the
        // build instead of quietly falling through to the tunnel hub.
        hubFor(connection).handle(message satisfies LocalhostMessage)
        return
      case 'upload.begin':
      case 'upload.data':
      case 'upload.end':
      case 'upload.cancel': {
        const desk = deskFor(connection)
        if (!desk) {
          // Refused here rather than passed on, for the same reason `create` is:
          // a client sending a verb this host never advertised is not a client of
          // ours. Answered on the upload's own id so the phone can end the right
          // progress bar rather than showing a banner about nothing.
          send(connection, {
            t: 'upload.failed',
            id: message.id,
            message: 'Files cannot be sent from a phone here.',
          })
          return
        }
        desk.handle(message satisfies UploadMessage)
        return
      }
    }
  }

  /**
   * Brings one authenticated-eventually connection into being, whatever carried it.
   *
   * Everything past this point is identical for a phone on the tailnet and a
   * phone on the far side of the relay, which is the point.
   *
   * The ceiling is checked here as well as at the HTTP upgrade, because the
   * upgrade is no longer the only door: a relay can open channels as fast as it
   * likes, and each one buys a slot, a timer and a parser for the length of the
   * hello timeout.
   */
  function attachTransport(
    address: string,
    connect: (handlers: WireHandlers) => RemoteWire,
    peerPublicKey?: Buffer,
  ): boolean {
    if (live.size >= MAX_CONNECTIONS) return false

    const connection: LiveConnection = {
      id: randomUUID(),
      wire: undefined as unknown as RemoteWire,
      address,
      connectedAt: Date.now(),
      deviceId: null,
      deviceName: '',
      platform: '',
      peerPublicKey: peerPublicKey ?? null,
      handles: new Map(),
      tunnels: null,
      uploads: null,
      helloTimer: null,
      greeting: false,
      creating: false,
    }

    connection.wire = connect({
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

    // An unauthenticated connection costs a slot; it does not get to keep one
    // indefinitely, whether or not it also costs a file descriptor.
    connection.helloTimer = setTimeout(() => {
      if (connection.deviceId) return
      connection.wire.close(CLOSE.policyViolation, 'no hello')
    }, helloTimeoutMs)
    connection.helloTimer.unref?.()

    live.set(connection.id, connection)
    return true
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

    attachTransport(req.socket.remoteAddress ?? 'unknown', (handlers) =>
      new WireSocket(socket, maxMessageBytes, handlers),
    )
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
    attachTransport,
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
    stopTunnel(connectionId: string, tunnelId: string): boolean {
      // The phone stays connected and its terminal sessions are untouched: this
      // ends one page, not the device's access. The sentence travels to the
      // phone, which takes the page down and says where the decision came from.
      return (
        live.get(connectionId)?.tunnels?.stop(tunnelId, 'Stopped from the desktop.') ?? false
      )
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
  /**
   * Is a code on screen right now?
   *
   * The relay asks, and only the relay: a device pairing for the first time has
   * no key this Mac has ever seen, so `isKnownDevice` would refuse its handshake
   * and it could never get as far as presenting the code. Opening the handshake
   * while a code is up is what makes first-time pairing possible at all, and it
   * grants nothing on its own — the device still has to produce the code, and a
   * human still has to approve it afterwards.
   *
   * The window is sixty seconds long and only exists because somebody pressed a
   * button on this Mac, which is a far smaller opening than the one the pairing
   * code itself already is.
   */
  open(): boolean
}

export function pairingDesk(auth: RemoteAuth, now: () => number = Date.now): PairingDesk {
  let live: { digest: Buffer; expiresAt: number } | null = null
  const digestOf = (value: string): Buffer => createHash('sha256').update(value).digest()
  const expired = (): boolean => {
    if (!live) return true
    if (now() < live.expiresAt) return false
    live = null
    return true
  }

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
      if (expired() || !live) return false
      return timingSafeEqual(digestOf(token), live.digest)
    },
    open(): boolean {
      return !expired()
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
    async authenticate(token, device, address, peerPublicKey): Promise<AuthOutcome> {
      if (token.includes('.')) {
        const verified = await auth.verifyCredential(token, address)
        if (verified.ok) {
          // Two proofs, one device. The handshake proved possession of a private
          // key and the credential proved possession of a bearer secret, and
          // nothing so far has said they belong to the same phone. Insisting
          // they do is what makes a credential copied off a phone — out of a
          // backup, off a screen, out of a bug — useless without the phone.
          // Refused in the same words as everything else here: which of the two
          // did not match is not a remote caller's business.
          if (peerPublicKey && !auth.deviceHoldsKey(verified.device.id, peerPublicKey)) {
            return { ok: false, message: 'This device is not allowed in. Pair it again from the desktop app.' }
          }
          return { ok: true, deviceId: verified.device.id, deviceName: verified.device.name, credential: null }
        }
        return {
          ok: false,
          message:
            verified.reason === 'pending'
              ? 'This device is waiting to be approved. Approve it in the desktop app, then reconnect.'
              : verified.reason === 'rate-limited'
                ? 'Too many failed attempts. Try again later.'
                : 'This device is not allowed in. Pair it again from the desktop app.',
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

      // The key goes in at pairing time or never: it is the one moment a device
      // and a person are both present, and every later connection is checked
      // against what was written here.
      const redeemed = await auth.redeemPairingToken(
        token,
        device.name,
        address,
        peerPublicKey ?? undefined,
      )
      if (!redeemed.ok) {
        return {
          ok: false,
          message:
            redeemed.reason === 'expired' || redeemed.reason === 'used'
              ? 'That pairing code has already been used or has expired. Create a new one in the desktop app.'
              : redeemed.reason === 'rate-limited'
                ? 'Too many failed attempts. Try again later.'
                : 'That pairing code is not right.',
        }
      }

      // The code has been spent, so the window it opened closes now rather than
      // when it would have expired. That window is not only about the code: while
      // it is up, the relay lets a device this Mac has never seen complete a
      // handshake, because a phone pairing for the first time has no key here to
      // be known by. Leaving it open for the rest of the minute would leave that
      // door open for a device that is no longer the one being paired.
      desk.cancel()

      // Paired, and deliberately not admitted: a token can be read over a
      // shoulder, so a human at the Mac approves the device before it opens
      // anything. The credential still has to travel, or the phone can never
      // come back.
      return {
        ok: false,
        message: 'Paired. Approve this device in the desktop app, then reconnect.',
        credential: redeemed.credential,
        deviceId: redeemed.device.id,
        deviceName: redeemed.device.name,
      }
    },
  }
}

/* --------------------------------------------------------------- lifecycle -- */

/**
 * The whole server: the two ways in, and the lifecycle around them.
 *
 * There are two, and neither is required:
 *
 *  - **Direct on the tailnet.** One hop, WireGuard, no third party, and a real
 *    certificate on a MagicDNS name. This is the better path and it is tried
 *    first, but it needs Tailscale installed, signed in and switched on, which
 *    is three steps before a phone sees anything.
 *  - **Through the relay.** An outbound socket to a rendezvous service that is
 *    treated as hostile and cannot read a byte of what it carries. No install,
 *    no login, works from a hotel wifi.
 *
 * Tailscale being absent used to mean remote access was off. It no longer does:
 * a missing tailnet blocks the direct listener and nothing else, and the reason
 * is reported as `directReason` rather than as *the* reason so that a panel does
 * not print an error next to a feature that is working.
 *
 * `start()` resolves with a status rather than throwing. Every way it can fail
 * is something the user fixes somewhere else, so it has to arrive as a sentence
 * the settings panel can show, not as a stack trace in a console nobody opens.
 *
 * The one thing that is not configurable, on either path, is what the listener
 * binds to. `0.0.0.0` would put a terminal on every network this laptop ever
 * joins; the socket is on loopback and Tailscale's own proxy is the only thing
 * in front of it. The relay does not change that — it never listens at all.
 */
export function createRemoteServer(options: RemoteServerOptions): RemoteServer {
  const port = options.port ?? DEFAULT_PORT
  const readTailnet = options.readTailnet ?? (() => tailnetStatus())

  const serve = options.serve ?? { on: serveOn, off: serveOff }
  const relay = options.relay ?? null
  let servers: LocalServer[] = []
  let endpoint: RemoteEndpoint | null = null
  let current: { url: string; address: string } | null = null
  let reason: string | null = null
  let directReason: string | null = null
  let relaying = false
  let starting: Promise<RemoteStatus> | null = null

  function snapshot(): RemoteStatus {
    const link = relaying ? (relay?.state() ?? null) : null
    return {
      running: servers.length > 0 || relaying,
      url: current?.url ?? null,
      address: current?.address ?? null,
      port,
      // Read live rather than remembered. With no listener, the honest answer to
      // "why can my phone not see this Mac" is whatever the relay is saying at
      // the moment somebody asks — a sentence recorded at `start()` would still
      // be describing a DNS failure long after the wifi came back.
      reason: servers.length > 0 ? null : (link ? link.reason : reason),
      directReason,
      relay: link,
      connections: endpoint?.connections() ?? [],
    }
  }

  function failure(message: string): RemoteStatus {
    reason = message
    directReason = message
    current = null
    return snapshot()
  }

  async function listenOn(server: LocalServer, address: string): Promise<void> {
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

  /** Everything the direct path needs, or the sentence saying why it has none. */
  type Direct =
    | { ok: true; hosts: string[]; url: string; address: string }
    | { ok: false; reason: string }

  function directPlan(tailnet: TailnetStatus): Direct {
    if (!tailnet.ready) return { ok: false, reason: tailnet.reason }
    if (!tailnet.magicDns || tailnet.dnsName === '') {
      return {
        ok: false,
        reason:
          `MagicDNS is off for this tailnet, so this ${machineNoun()} has no name a phone can trust a certificate for. Turn MagicDNS on in the Tailscale admin console, then try again.`,
      }
    }
    return {
      ok: true,
      hosts: [
        tailnet.dnsName,
        `${tailnet.dnsName}:${port}`,
        `${tailnet.address}:${port}`,
        ...(tailnet.address6 ? [`[${tailnet.address6}]:${port}`] : []),
      ],
      url: `https://${tailnet.dnsName}:${port}/`,
      address: tailnet.address,
    }
  }

  async function open(): Promise<RemoteStatus> {
    const direct = directPlan(await readTailnet())

    // Nothing to run and nothing to fall back on. Reported exactly as before:
    // the tailnet's own sentence, which names the switch to flick.
    if (!direct.ok && relay === null) return failure(direct.reason)

    // No certificate is loaded any more. Electron's Node is built against
    // BoringSSL, where `https.createServer` accepts the connection and then
    // never finishes the handshake — measured on this machine, same cert and
    // address, plain Node answered 200 and Electron answered nothing at all.
    // Tailscale terminates TLS instead, with the certificate it already
    // manages, and proxies to loopback.

    const hosts = options.hosts ?? (direct.ok ? direct.hosts : [])
    const live = createRemoteEndpoint({
      ...options,
      hosts,
      // This app's own listener is never a tunnel target. Only this function
      // knows which port that is, which is why the endpoint is told rather than
      // left to work it out.
      reservedPorts: [port, ...(options.reservedPorts ?? [])],
    })

    const opened: LocalServer[] = []
    let blocked: string | null = direct.ok ? null : direct.reason
    if (direct.ok) {
      // MagicDNS answers with both an A and an AAAA record, but nothing on the
      // tailnet reaches this socket directly: the only way in is through
      // Tailscale's proxy, which it scopes to the tailnet, so the listener is
      // loopback and nothing else.
      try {
        const server = createPlainServer(live.handleRequest)
        server.on('upgrade', live.handleUpgrade)
        // A phone that drops mid-handshake is routine, not a crash.
        server.on('clientError', (_error, socket) => socket.destroy())
        await listenOn(server, '127.0.0.1')
        opened.push(server)
        const proxied = await serve.on(port, port)
        if (!proxied.ok) {
          blocked = proxied.message ?? 'Tailscale could not put a proxy in front of this app.'
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        blocked = /EADDRINUSE/.test(message)
          ? `Port ${port} on the tailnet address is already in use by something else on this ${machineNoun()}.`
          : `Could not listen on the tailnet address: ${message}`
      }
      if (blocked !== null) {
        for (const server of opened) server.close()
        opened.length = 0
      }
    }

    // A relay with nothing else working is still remote access; a direct path
    // with no relay is what this was before. Only both failing is a failure.
    if (opened.length === 0 && relay === null) return failure(blocked ?? 'Remote access could not start.')

    if (relay !== null) {
      relay.start(live.attachTransport)
      relaying = true
    }

    servers = opened
    endpoint = live
    directReason = blocked
    // Not an error while something is serving. A panel that prints "Tailscale is
    // signed out" next to a working connection teaches people to ignore it.
    reason = opened.length === 0 && !relaying ? blocked : null
    current = opened.length > 0 && direct.ok ? { url: direct.url, address: direct.address } : null
    return snapshot()
  }

  return {
    async start(): Promise<RemoteStatus> {
      if (servers.length > 0 || relaying) return snapshot()
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
      // Stopped before the sockets are closed: the relay is an outbound link
      // that reconnects on its own, so a relay left running would dial straight
      // back in and hand out channels against an endpoint that is going away.
      if (relaying) relay?.stop()
      relaying = false
      const closing = servers
      servers = []
      current = null
      directReason = null
      // Tailscale stores the serve config in tailscaled, so it outlives this
      // process. Left behind, it advertises a URL that proxies to a port
      // nothing is listening on any more.
      await serve.off(port).catch(() => {})
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
    stopTunnel: (connectionId, tunnelId) => endpoint?.stopTunnel(connectionId, tunnelId) ?? false,
    status: snapshot,
    // No relay configured (`TERMINALDECK_RELAY=off`) means nothing to re-dial.
    wake: () => relay?.wake(),
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
  /**
   * Where files sent from a phone land, and the switch for the whole feature.
   *
   * Deliberately **not** under `storageDir`: that is application support, which
   * is somewhere a person never looks and which an uninstall removes. A file sent
   * from a phone is the user's file, so it goes where their downloads go —
   * `index.ts` passes `app.getPath('downloads')` joined with the product name.
   * Absent means this host does not offer the capability at all.
   */
  uploadsDir?: string
  port?: number
  /** Push an event at the renderer. `index.ts` already has exactly this function. */
  broadcast(channel: string, payload: unknown): void
  /**
   * Where the rendezvous relay lives, when it is not the default.
   *
   * `TERMINALDECK_RELAY_URL` overrides this and `TERMINALDECK_RELAY=off` turns
   * the relay off entirely; see `relay-client.ts` for why the environment wins.
   */
  relayUrl?: string | null
  /** False keeps the Mac off any relay, direct-on-tailnet only. */
  relayEnabled?: boolean
  /**
   * Whether to dial out as soon as the app launches. **Default true.**
   *
   * The requirement is that there is no online/offline switch to find — remote
   * access "just works". For a long time this file did the opposite: `start()`
   * ran only when someone pressed a button in Settings, nothing re-ran it on
   * the next launch, and so a Mac that had been restarted was simply not
   * reachable. Every phone paired to it saw a host that was never there.
   *
   * Dialling exposes nothing on its own. The relay learns that a host is
   * online and nothing else, and a phone still has to be paired *and* approved
   * before one frame is delivered — see `authenticatorFor`.
   *
   * False is what a person who turned it off gets. The caller owns
   * remembering that, through {@link onEnabledChange}; this flag is only the
   * answer it read back.
   */
  autoStart?: boolean
  /**
   * Told when remote access is switched on or off, so the caller can remember
   * the answer and hand it back as {@link autoStart} next launch.
   *
   * Not called for the launch dial itself — that is not a decision anyone made.
   */
  onEnabledChange?(on: boolean): void
  /**
   * Told when the launch dial does not come up, with the reason.
   *
   * There is no user waiting on a reply to it, which is exactly why it needs
   * somewhere to go: the last time a remote failure had no listener it was the
   * BoringSSL cipher throw, and it cost a day of every handshake failing with
   * nothing on the wire and nothing in any log.
   */
  onStartFailure?(reason: string): void
  /** Reads the environment. Injected so a test can set one without setting one. */
  env?: NodeJS.ProcessEnv
  /**
   * The same two test seams `createRemoteServerOptions` carries, forwarded.
   *
   * They matter more here than they do there. Registering the IPC now dials on
   * its own, so a test that constructs this on a developer's Mac would bind a
   * loopback port and ask the real Tailscale for a real proxy — a unit test
   * reaching into the machine it runs on. Overriding them is how a test says
   * "no tailnet" without unplugging one.
   */
  readTailnet?: RemoteServerOptions['readTailnet']
  serve?: RemoteServerOptions['serve']
}

export interface RemoteIpc {
  server: RemoteServer
  auth: RemoteAuth
}

/**
 * The relay link for a real app: this Mac's identity, and who may handshake.
 *
 * Built lazily, on the first `start()`. Registering the IPC happens on every
 * launch and turning remote access on does not, and `loadHostIdentity` writes a
 * private key: minting key material on disk for a feature nobody switched on is
 * the kind of thing this panel exists to not do.
 *
 * A failure to keep that identity turns the relay off rather than throwing. A
 * private key that exists only in memory works until the next launch and then
 * hands every paired phone a host id that no longer exists — so the honest
 * answer is no relay, a sentence in the status, and a tailnet path that is
 * untouched by any of it.
 */
function relayFor(storageDir: string, url: string, auth: RemoteAuth, desk: PairingDesk): RelayLink {
  let link: RelayLink | null = null
  let broken: string | null = null

  return {
    start(attachTransport): void {
      if (link === null && broken === null) {
        try {
          link = createRelayClient({
            url,
            identity: loadHostIdentity(storageDir),
            // Two ways in, and both are narrow. A device this Mac already knows,
            // by a key it stored when that device paired — or any device at all,
            // but only while a pairing code is on screen, because a phone
            // pairing for the first time has no key here to be known by. Neither
            // grants access: the hello that follows still needs a credential,
            // and a human still has to approve.
            isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
          })
        } catch (error) {
          console.error('[relay] could not keep this host’s relay identity:', error)
          broken =
            `This ${machineNoun()} could not save the key it needs to be reachable through the relay. Check that its application-support folder is writable, then turn remote access off and on again.`
        }
      }
      link?.start(attachTransport)
    },
    stop: () => link?.stop(),
    // Harmless before the link exists: a Mac that has never started the relay
    // has nothing to reconnect on waking.
    wake: () => link?.wake(),
    state: () =>
      link?.state() ?? {
        url,
        hostId: '',
        publicKey: '',
        fingerprint: '',
        connected: false,
        channels: 0,
        reason: broken ?? 'The relay has not been started yet.',
        retryAt: null,
      },
  }
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
  const env = deps.env ?? process.env

  // Built here rather than inside the server, because this is the only place
  // that holds the trust store and the storage directory. Building it dials
  // nothing and writes no key on its own — `start()` at the bottom of this
  // function is what does both, on every launch unless this Mac was switched
  // off.
  const relay = relayEnabled(env, deps.relayEnabled)
    ? relayFor(deps.storageDir, relayUrl(env, deps.relayUrl), auth, desk)
    : null

  const server = createRemoteServer({
    sessions: deps.sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: deps.webRoot,
    certDir: deps.storageDir,
    ...(deps.uploadsDir ? { uploadsDir: deps.uploadsDir } : {}),
    port: deps.port,
    onConnections: (connections) => deps.broadcast(REMOTE_CONNECTIONS_CHANNEL, connections),
    ...(relay ? { relay } : {}),
    ...(deps.readTailnet ? { readTailnet: deps.readTailnet } : {}),
    ...(deps.serve ? { serve: deps.serve } : {}),
  })

  ipcMain.handle('remote:status', (): RemoteStatus => server.status())
  ipcMain.handle('remote:start', async (): Promise<RemoteStatus> => {
    const status = await server.start()
    // Only a start that took is worth remembering. Recording the press instead
    // would arm the next launch to retry something that has already been told
    // it cannot work.
    if (status.running) deps.onEnabledChange?.(true)
    return status
  })
  ipcMain.handle('remote:stop', async (): Promise<RemoteStatus> => {
    const status = await server.stop()
    deps.onEnabledChange?.(false)
    return status
  })

  // On unless the user turned it off. See `autoStart` for why this is not a
  // switch anybody has to find, and why dialling out exposes nothing by itself.
  //
  // Not awaited: `open()` shells out to Tailscale and dials a relay across the
  // internet, and the window must not wait on either. Both branches report —
  // a rejected promise and a resolved-but-not-running status are the same
  // failure to a person, and neither has a caller to return to.
  if (deps.autoStart !== false) {
    void server.start().then(
      (status) => {
        if (!status.running) {
          deps.onStartFailure?.(status.reason ?? 'Remote access did not start, and did not say why.')
        }
      },
      (error: unknown) => {
        deps.onStartFailure?.(error instanceof Error ? error.message : String(error))
      },
    )
  }

  ipcMain.handle('remote:pair', (): PairingToken => desk.create())
  ipcMain.handle('remote:pair:cancel', (): { cancelled: true } => {
    desk.cancel()
    return { cancelled: true }
  })

  ipcMain.handle('remote:connection:disconnect', (_event, id: unknown): RemoteConnection[] => {
    if (typeof id === 'string') server.dropConnection(id)
    return server.connections()
  })

  // The other half of "killable from either end". Not destructive enough to
  // confirm — it closes a web page, and the phone can reopen it with one tap —
  // but the phone is told why, so nobody is left looking at a dead page
  // wondering whether their wifi dropped.
  ipcMain.handle(
    'remote:tunnel:stop',
    (_event, connectionId: unknown, tunnelId: unknown): RemoteConnection[] => {
      if (typeof connectionId === 'string' && typeof tunnelId === 'string') {
        server.stopTunnel(connectionId, tunnelId)
      }
      return server.connections()
    },
  )

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
