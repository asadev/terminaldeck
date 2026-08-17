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
// The one method of `IpcMain` this file uses, named rather than imported. That
// is the whole of the "unpick ipcMain" step in HEADLESS.md: the headless daemon
// registers these same handlers against a desk that keeps them in a Map, and its
// CLI invokes them by the same channel names the preload uses — one
// implementation of pairing, folders and status, two callers. See ../ipc-seam.
import type { InvokeRegistrar } from '../ipc-seam'
import { MAX_FAILED_ATTEMPTS, RemoteAuth, type Device, type PairingToken } from './device-auth'
// Type-only, deliberately. The store is built by `index.ts` and handed to
// `registerRemoteIpc`; importing the class here would put a second constructor
// for the same file in the one module that must not own it.
import type { DeviceFolderGrant, FolderGrants } from './folder-grants'
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
  type DevServerReport,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from './protocol'
// The one comparison this app has for "are these two paths the same folder",
// borrowed rather than restated. A second idea of folder equality here would be
// a device granted `/Users/asad/proj` being refused `/Users/asad/proj/`, and on
// Windows a folder visibly on the list being refused over a drive letter's case.
// `session-create.ts`'s only runtime dependency in this direction is a type, so
// there is no cycle.
import { sameFolder } from './session-create'
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
// Type-only, like `FolderGrants` above and for the same reason: the proxy is
// built by `index.ts`, which needs it before this function is called — the
// session spawn path closes over it — so constructing one here would give the
// sockets a different object from the one sessions are keyed against.
import type { CredentialMessage, CredentialProxy } from './credentials'
// Type-only for the same reason again, plus one of its own: `dev-server.ts`
// reads `package.json` files off the disk, and a socket server whose module
// graph reaches `node:fs` is a socket server that has to be tested with a
// filesystem. The instance is injected; nothing here constructs one.
import type { DevServerState, DevServers, SessionOpener } from '../dev-server'
import { scanDevPortsDetailed } from '../dev-ports'
import { ownPorts } from '../own-ports'
import { currentPlatform, machineNoun } from '../platform/host'
import { createRelayClient, relayEnabled, relayUrl, type RelayLink, type RelayState } from './relay-client'
import { loadHostIdentity } from './host-identity'
// The rendezvous half of a pairing code. It is imported *here*, into the desk
// that mints codes, because that is what makes "a code this product shows" and
// "a code another machine can find" the same thing — see `PairingDesk.show`.
import { offerFrom, startBeacon, type Beacon, type MachineOffer } from './machines/rendezvous'
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
  /**
   * Which device is asking. Not optional, and that is the point.
   *
   * The connection has known this since `hello` — a device only has an id after
   * `RemoteAuth` matched its credential and a human approved it — and for a long
   * time the request travelled down to the session layer without it. So the only
   * question that layer could answer was "will this desktop start a session in
   * that folder", never "will it start one for *this phone*", and every paired
   * device necessarily got the same answer. Required rather than optional so the
   * compiler asks at each call site instead of a reviewer having to notice.
   *
   * It is this server's word, taken from the authenticated connection, and never
   * a field off the wire. A device id a client could name would be a client
   * choosing whose folders it gets.
   */
  deviceId: string
  cwd?: string
  cols?: number
  rows?: number
  /**
   * Which agent CLI the client asked for, unchecked.
   *
   * A `string` rather than a `ProviderId` on purpose, and it is the same
   * argument `cwd` makes one line up: this is a value off the wire, and typing
   * it as the narrow union here would be this server *claiming* to have checked
   * something it has not looked at. The provider table lives in the session
   * layer, so that is where a name becomes an agent or a refusal — see
   * `remote/session-create.ts`.
   *
   * Absent is the ordinary case and means "whatever this desktop would have
   * started", which is what every client shipped before the field existed sends
   * and what the desktop's own New Session button does.
   */
  provider?: string
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
  /**
   * The folders one device may start a session in, most relevant first.
   *
   * Sent to the device on `welcome` and again whenever the list changes, so its
   * picker offers what it may use rather than a set it inferred. This is the
   * *same* call `create` checks against — `remoteSessionStart` in
   * `session-create.ts` hands both out of one starter — because a picker built
   * from a second source is a picker that eventually offers a folder the rule
   * refuses, which is unexplainable from a phone.
   *
   * Optional alongside `create` and absent with it: a host that cannot start
   * sessions has no list to advertise, and one that can must be able to say what
   * is on it.
   */
  folders?(deviceId: string): string[]
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
  /**
   * Where a git login is asked for. **Absent is the switch**, as everywhere else.
   *
   * A host with no proxy does not advertise the `credential` capability, so a
   * client never draws a GitHub screen for it and this server never sends it a
   * frame it would have to ignore — the same negotiation `uploadsDir` and
   * `SessionAccess.create` get.
   *
   * The direction of this one is the other way round from every other capability
   * and that is the interesting part: nothing here *serves* a verb. This server
   * holds the sockets, so it is the only thing that can put a question to a
   * device, and the proxy is the only thing that knows which question. Handing
   * it {@link DevicePost} at construction is how those two facts are joined
   * without either module importing the other.
   */
  credentials?: CredentialProxy
  /**
   * Starting a project's dev server. **Absent is the switch**, as everywhere else.
   *
   * A host with no dev-server module does not advertise the `devserver`
   * capability, so a client never draws a Start button for it and never sends a
   * verb this server would refuse. Same negotiation as `uploadsDir` and
   * `SessionAccess.create`, same reason.
   *
   * It is injected rather than constructed here for a reason that is not merely
   * symmetry: the module has to be handed the *same* one the desktop window is
   * driving, or a phone and the window would each be watching their own idea of
   * whether a project's server is up. There is one dev server per project, so
   * there is one state per project, and it lives with the sessions rather than
   * with a socket.
   *
   * Typed as an import so this file cannot drift from the module — but a **type**
   * import, so nothing about the dev-server module, its `node:fs` reads or its
   * Electron typings ends up in the module graph of a server that is tested over
   * a plain loopback socket.
   */
  devServers?: DevServers
  /**
   * The most this host is willing to advertise, whatever it is able to do.
   *
   * Absent means "everything you can serve", which is what a desktop and an
   * ordinary headless install want and is why this is not a required field.
   *
   * It exists for one host: the public demo box, where a stranger who has never
   * met the owner gets a shell. Every other capability on the list is a hole in
   * that arrangement — `localhost` is a byte pipe to whatever is listening on
   * loopback, `upload` is a way to fill a disk, `credential` is a proxy for
   * credentials a demo must not hold — and the demo advertises `create` alone.
   *
   * A *ceiling*, deliberately, rather than the list itself. The rules below
   * still decide what this build can actually serve, and intersecting the two
   * means a host cannot use this field to promise something it does not have:
   * naming `upload` here with no `uploadsDir` still advertises nothing, so the
   * failure mode is a button that never appears rather than one that appears and
   * is refused.
   */
  offer?: readonly string[]
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
  /**
   * Send one device its folder list again, because it changed on the desktop.
   * Returns how many of its connections were told, which is zero when it is not
   * connected — a normal outcome, not a failure.
   */
  foldersChanged(deviceId: string): number
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
  /** Re-send one device's folder list. Zero when it is not connected. */
  foldersChanged(deviceId: string): number
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
  /**
   * What this client said it can do, from `hello`.
   *
   * Read before anything is *sent* to it, never before something is accepted
   * from it: a claim here grants nothing, it only stops this server from putting
   * a question to a client that has no code to answer it — which would be a
   * request that times out instead of one that was never asked.
   */
  capabilities: string[]
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
  /**
   * Project folders this connection has asked about, in the desktop's own
   * spelling.
   *
   * A subscription list, and the only reason `dev.state` can be pushed rather
   * than polled. A client sends `dev.status` or `dev.start` for a folder and
   * then hears about every change to it for as long as the socket lives — which
   * is what makes a two-minute cold start readable on a phone without a timer
   * asking "is it up yet" forty times.
   *
   * Only ever holds folders that passed the grant check, so a device cannot use
   * it to learn that something happened in a folder it was never given. Capped,
   * because it is a per-connection allocation driven by a message.
   */
  devFolders: Set<string>
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
    // The ceiling first, so a host that named a shorter list gets it whatever
    // the rules below would have allowed. `localhost` is the reason this test
    // has to come first: it is the one capability with no object behind it —
    // every host can serve it, so nothing else in this filter can ever take it
    // away, and the public demo host must not offer a stranger a byte pipe to
    // its own loopback.
    if (options.offer !== undefined && !options.offer.includes(name)) return false
    if (name === CAPABILITY.create) return typeof options.sessions.create === 'function'
    // Same rule, same reason: the thing that makes the feature possible is the
    // thing that decides whether it is offered. A host with nowhere to put a file
    // must not draw a Send File button on somebody's phone.
    if (name === CAPABILITY.upload) return typeof options.uploadsDir === 'string' && options.uploadsDir !== ''
    // Same rule again. A host with no proxy would otherwise tell a phone it may
    // be asked for a GitHub login and then never ask, which is a screen in
    // somebody's app for a thing that cannot happen.
    if (name === CAPABILITY.credential) return options.credentials !== undefined
    /*
     * Three conditions, and all three are load-bearing.
     *
     * The module is the obvious one. `create` is there because starting a dev
     * server *is* starting a session — this feature has no process-spawning path
     * of its own, on purpose — so a host that cannot start a session cannot start
     * one of these either. And `folders` is there because it is the entire
     * authorisation: without a per-device folder list there is nothing to check a
     * request against, and the correct behaviour for a host that cannot answer
     * "may this device use this folder" is to not offer the feature rather than
     * to answer it optimistically.
     */
    if (name === CAPABILITY.devserver) {
      return (
        options.devServers !== undefined &&
        typeof options.sessions.create === 'function' &&
        typeof options.sessions.folders === 'function'
      )
    }
    return true
  })

  /**
   * Push a folder's new state to every connection that has asked about it.
   *
   * Subscribed once for the endpoint rather than once per connection, because
   * there is one dev server per project and its state does not depend on who is
   * watching. Compared with `sameFolder` and not with `Set.has`, so a device that
   * asked about `/p` and a window that started `/p/` are looking at one project.
   */
  const stopDevWatch =
    options.devServers?.onChange((state) => {
      for (const connection of live.values()) {
        if (!connection.deviceId) continue
        let watching = false
        for (const folder of connection.devFolders) {
          if (sameFolder(folder, state.folder)) {
            watching = true
            break
          }
        }
        if (!watching) continue
        send(connection, { t: 'dev.state', state: devReport(state) })
      }
    }) ?? null

  /**
   * The desktop's dev-server state, trimmed to what the wire carries.
   *
   * Rebuilt field by field rather than passed through, for exactly the reason
   * `offerPorts` in `tunnel.ts` rebuilds a `LocalPort`: `DevServerState` is the
   * desktop's own type and `DevServerReport` is a contract with three clients, so
   * whatever this copies becomes what they are allowed to see. A field added to
   * the module reaches a phone only when somebody writes a line here.
   */
  function devReport(state: DevServerState): DevServerReport {
    const report: DevServerReport = { folder: state.folder, status: state.status }
    if (state.script !== undefined) report.script = state.script
    if (state.command !== undefined) report.command = state.command
    if (state.sessionId !== undefined) report.sessionId = state.sessionId
    if (state.port !== undefined) report.port = state.port
    if (state.url !== undefined) report.url = state.url
    if (state.note !== undefined) report.note = state.note
    if (state.message !== undefined) report.message = state.message
    return report
  }

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
      /*
       * The endpoint's own reserved list, plus every other port this app is
       * currently serving on.
       *
       * Read here rather than folded in when the endpoint was created, because
       * this runs when a phone connects and that is always after every listener
       * has started. `own-ports.ts` says what is in it and why the list stopped
       * being one entry long — the short version is that `deck-control` is the
       * copilot's whole tool surface on a loopback port, and a phone being
       * offered a tunnel to it would be a way around the per-device grant.
       */
      reserved: [...(options.reservedPorts ?? []), ...ownPorts()],
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
    // Absent means "nothing past version 1", which is what every client shipped
    // before the field says. Empty rather than a guess: the one thing this list
    // decides is what gets *sent*, and inventing a capability for a client that
    // did not claim one is how a request ends up waiting on code that is not there.
    connection.capabilities = message.capabilities ?? []
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
      hostPlatform: currentPlatform(),
      // Spread rather than sent as `undefined`, so a host that cannot start
      // sessions sends no key at all — the same shape a desktop from before this
      // field sends, which is what an older client is already correct about.
      ...foldersFrame(outcome.deviceId),
    })
    announce()
  }

  /**
   * This device's folder list, in the shape a message spreads.
   *
   * One helper because two frames carry it — the `welcome` above and the push
   * below — and they must not be able to disagree about what "no list" looks
   * like on the wire.
   */
  function foldersFrame(deviceId: string): { folders?: string[] } {
    const list = options.sessions.folders?.(deviceId)
    return list ? { folders: list } : {}
  }

  /**
   * Tell one device its folders changed, without waiting for it to reconnect.
   *
   * Driven by the settings panel: a person removing a folder on the desktop
   * expects the phone in their other hand to stop offering it. The *rule* is
   * already live without this — `folders()` is consulted on every `create` — so
   * this only keeps the picker honest, which is why a device with no live
   * connection is not an error and simply counts zero.
   */
  function tellFolders(deviceId: string): number {
    let told = 0
    for (const connection of live.values()) {
      if (connection.deviceId !== deviceId) continue
      const frame = foldersFrame(deviceId)
      if (frame.folders === undefined) continue
      send(connection, { t: 'folders', folders: frame.folders })
      told += 1
    }
    return told
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
  /**
   * Folders one connection may be subscribed to at once.
   *
   * A person looks at one project, occasionally two. The cap is here because the
   * set is a per-connection allocation driven by a message, and every one of
   * those needs a ceiling whether or not anybody would reach it.
   */
  const MAX_DEV_FOLDERS = 8

  /**
   * Look at, or start, one project's dev server.
   *
   * ## Where the folder grant is enforced — both times
   *
   * **Here, first, before anything touches the disk.** `folders(deviceId)` is the
   * same call `create` is checked against and the same array the device was sent
   * in its `welcome`, so a folder on the phone's screen is a folder that works
   * and nothing else is. The check comes before the `package.json` is read
   * because the answer to `dev.status` is *derived from that file*: a desktop
   * that read first and authorised second would let a paired phone ask whether
   * any path on the machine is a Node project and what its scripts are called.
   * That is a small disclosure and it is a disclosure, and it costs one
   * comparison to not have.
   *
   * **Then again, underneath, by the code that already owns the question.** The
   * session is opened through `SessionAccess.create`, which is
   * `remoteSessionCreator` in `session-create.ts` — so the folder is checked a
   * second time by the function that has always checked it, and the session that
   * results is confined to the folder and given a guest git identity exactly like
   * every other session a device starts. There is deliberately no second
   * spawning path: this feature cannot start a process that an ordinary `create`
   * could not.
   *
   * What travels onward is **the desktop's spelling of the folder**, taken from
   * its own list, never the string the client sent. The two can differ by a
   * trailing separator or by case on Windows and still be the same directory —
   * `sameFolder` is what says so — and passing the desktop's copy means nothing
   * downstream has to trust a path off the network.
   */
  async function devServe(
    connection: LiveConnection,
    // Passed in rather than read off the connection inside, for the reason
    // `create` spells out: this is the value that decides whose folders apply,
    // and it has to come from the authenticated socket at the call site.
    deviceId: string,
    message: Extract<ClientMessage, { t: 'dev.status' | 'dev.start' }>,
  ): Promise<void> {
    const servers = options.devServers
    const start = options.sessions.create
    if (!servers || !start) {
      // A client sending a verb this host never advertised is not a client of
      // ours — the same refusal `create` and the uploads give, for the same
      // reason.
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'Dev servers cannot be started from a phone here.',
      })
      return
    }

    const offered = options.sessions.folders?.(deviceId) ?? []
    const granted = offered.find((folder) => sameFolder(folder, message.folder))
    if (granted === undefined) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        // The folder is not echoed back, for the reason `session-create.ts`
        // gives: it came off the network and this sentence is drawn on a phone.
        message:
          `This ${machineNoun(currentPlatform())} is not offering that folder to this device. ` +
          'Pick one from the list it sent.',
      })
      return
    }

    // Subscribed only after the grant passed, so the set cannot be used to learn
    // that something happened in a folder this device was never given.
    if (connection.devFolders.size < MAX_DEV_FOLDERS) connection.devFolders.add(granted)

    if (message.t === 'dev.status') {
      send(connection, { t: 'dev.state', state: devReport(servers.status(granted)) })
      return
    }

    /*
     * One start at a time per connection, sharing `create`'s own flag.
     *
     * Shared rather than a second one of its own, because they are the same
     * resource: both end in a spawned session, and a client that alternated
     * between the two verbs could otherwise start as many processes as it liked
     * on somebody's machine while each individual guard was satisfied.
     */
    if (connection.creating) {
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: 'A session is already starting. Wait for it to appear.',
      })
      return
    }

    connection.creating = true
    let state: DevServerState
    try {
      state = await servers.start(granted, devOpener(deviceId, start))
    } finally {
      connection.creating = false
    }
    // The phone can be gone by now — starting reads the disk, scans the ports
    // and spawns a shell. The dev server is still real and still on this
    // machine, which is the honest outcome of "start something"; there is just
    // no socket left to tell.
    if (!live.has(connection.id)) return
    send(connection, { t: 'dev.state', state: devReport(state) })
  }

  /**
   * How a dev server's session is opened for a device: through `create`, and
   * through nothing else.
   *
   * `provider: 'shell'` because the command is typed into a shell — see
   * `dev-server.ts` — and naming it explicitly rather than letting the desktop's
   * default apply matters: a desktop whose default provider is `claude` would
   * otherwise start an agent and have `pnpm run dev` typed into its prompt.
   *
   * No `cols`/`rows`. The frame does not carry a size and should not: this
   * session is a server that will be read occasionally rather than typed into,
   * and a client that attaches to it sends a `resize` with its real viewport at
   * that moment. Inventing a size here would be inventing it twice.
   */
  function devOpener(deviceId: string, start: NonNullable<SessionAccess['create']>): SessionOpener {
    return async (folder: string) => {
      const outcome = await start({ deviceId, cwd: folder, provider: 'shell' })
      // The refusal is passed through as written. It is the only layer that knows
      // whether the folder was ungranted, deleted, or could not be confined, and
      // it has already written the sentence for each.
      return outcome.ok
        ? { ok: true as const, sessionId: outcome.session.id }
        : { ok: false as const, message: outcome.message }
    }
  }

  async function create(
    connection: LiveConnection,
    // Passed in rather than read off `connection` inside, because this is the
    // one value here that decides whose folders apply and it must come from the
    // authenticated connection at the call site — `onMessage` has already
    // refused anything with no device id, and taking it there means this
    // function cannot be called with a device this socket did not prove it is.
    deviceId: string,
    message: Extract<ClientMessage, { t: 'create' }>,
  ): Promise<void> {
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
      // Every field the frame carried, forwarded by name, and the list has to be
      // kept complete by hand. That is worth saying out loud because this is the
      // line the provider went missing on: a field arrived, this hand-off did
      // not mention it, and nothing anywhere reported a dropped value. There is
      // no type that catches it — `ClientMessage` is wider than `CreateRequest`
      // by design — so `server.test.ts` asserts the round trip instead, driving a
      // real socket and reading what the session layer was handed, which is the
      // only thing that can fail when the next field is added and forgotten.
      outcome = await start({
        deviceId,
        cwd: message.cwd,
        cols: message.cols,
        rows: message.rows,
        provider: message.provider,
      })
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
        // `connection.deviceId` is a `string` here and not `string | null`: the
        // guard at the top of this function returned for anything that had not
        // said hello, and nothing between reassigns it.
        void create(connection, connection.deviceId, message).catch((error) => {
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
      case 'dev.status':
      case 'dev.start':
        // Not awaited, for the same reason `create` is not: this reads a
        // `package.json`, scans the machine's ports and may spawn a session, and
        // the message loop is the socket's data handler. It must not stop reading
        // for the length of any of that.
        void devServe(connection, connection.deviceId, message).catch((error) => {
          console.error('[remote] dev server request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That dev server could not be looked at.',
          })
        })
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
      case 'credential.ack':
      case 'credential.answer':
      case 'credential.deny': {
        const proxy = options.credentials
        if (!proxy) {
          // Refused rather than dropped, for the same reason `create` is: a
          // client answering a question this host never asked is not a client of
          // ours. It is also the one refusal here that cannot be answered on the
          // feature's own id, because without a proxy there is no request to
          // name.
          send(connection, {
            t: 'error',
            code: 'unauthorized',
            message: 'Nothing here asked this device for a login.',
          })
          return
        }
        // `connection.deviceId` is a `string` here and not `string | null`: the
        // guard at the top of this function returned for anything that had not
        // said hello. Passing it rather than letting the desk read it off a
        // connection is the same argument `create` makes — whose answer this is
        // must come from the authenticated socket, never from the frame.
        proxy.handle(connection.deviceId, message satisfies CredentialMessage)
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
      capabilities: [],
      handles: new Map(),
      tunnels: null,
      uploads: null,
      devFolders: new Set(),
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
        const deviceId = connection.deviceId
        detachAll(connection)
        if (deviceId !== null) {
          // After the delete above, so the proxy's own "is it still reachable"
          // check cannot see the socket that has just gone. A git waiting on a
          // phone that closed its app is the case this exists for: without it the
          // request would sit until a timer expired rather than failing the
          // moment the last way to reach that device disappeared.
          options.credentials?.connectionClosed(deviceId)
          announce()
        }
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

  /**
   * How the credential proxy reaches a device: every live socket it has that
   * said it can answer.
   *
   * Every socket rather than one, because a person can have the app open on a
   * phone and a tablet and either may be the one in their hand. Whichever
   * answers first wins and the desk drops the rest, which is the same shape as
   * the prompt itself — one question, several places it can be seen.
   *
   * The capability check is what keeps this from being a hang: a client that has
   * never heard of `credential.request` is not counted as reachable, so a push
   * from a device running an older app is refused in milliseconds with a sentence
   * instead of waiting out a deadline for code that does not exist.
   */
  function canAnswer(connection: LiveConnection, deviceId: string): boolean {
    return connection.deviceId === deviceId && connection.capabilities.includes(CAPABILITY.credential)
  }

  options.credentials?.serve({
    ask(deviceId: string, message: ServerMessage): number {
      let heard = 0
      for (const connection of live.values()) {
        if (!canAnswer(connection, deviceId)) continue
        send(connection, message)
        heard += 1
      }
      return heard
    },
    reachable(deviceId: string): boolean {
      for (const connection of live.values()) {
        if (canAnswer(connection, deviceId)) return true
      }
      return false
    },
  })

  return {
    handleRequest,
    handleUpgrade,
    attachTransport,
    connections: publicConnections,
    dropDevice(deviceId: string): number {
      // Before the sockets go, so anything waiting on this device is answered
      // with "no longer allowed" rather than with "not reachable" — a revoke and
      // a phone in a tunnel are different facts and the person at the terminal
      // is owed the right one.
      options.credentials?.forget(deviceId)
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
    foldersChanged: tellFolders,
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
      // Before the sockets, so a state change that lands mid-teardown cannot try
      // to send on a wire that is going away.
      stopDevWatch?.()
      for (const connection of [...live.values()]) connection.wire.close(CLOSE.goingAway, 'server stopping')
    },
  }
}

/* ---------------------------------------------------------------- adapters -- */

/** A code that is on screen, and whether six typed digits can find it. */
export interface ShownCode {
  code: PairingToken
  /**
   * Is this machine sitting in the rendezvous slot the code names?
   *
   * False means the code still works for a client that already knows this
   * machine's address — which, now that there is no QR and no link, is only the
   * browser client this machine serves on its own tailnet — and does not work
   * for anybody typing it into a phone or a second desktop, because there is
   * nothing at the relay for them to look the address up in.
   */
  findable: boolean
}

/**
 * What `remote:pair` answers with: the code, and whether anything can look it up.
 *
 * A flatter shape than {@link ShownCode} on purpose. This one crosses the
 * preload, where it is `unknown` and has to be narrowed field by field by the
 * renderer, and a nested `code` object would mean two narrowings for one answer
 * — which is how the field this type exists to carry got dropped the first time.
 *
 * `findable` is the difference between a code a phone can use and six digits
 * that only the browser client this machine serves on its own tailnet can
 * redeem. The panel must be able to tell those apart, because they look
 * identical on screen and the failure they produce lands sixty seconds later on
 * a different device, where nothing can explain it.
 */
export interface ShownPairingCode extends PairingToken {
  findable: boolean
}

/**
 * The one pairing code that is on screen.
 *
 * `RemoteAuth` will happily keep sixteen live tokens at once, which is right
 * for a library and wrong for this UI: the panel shows one code, so exactly one
 * code should open the door. Narrowing it here is also what makes Cancel real —
 * the trust store has no way to un-mint a token, and a Cancel button that only
 * stops drawing the code is a button that lies.
 *
 * ## Why the rendezvous lives on the desk
 *
 * It did not, and the result was two codes that looked identical and behaved
 * differently. `machines:code` minted from this desk *and* started a beacon at
 * the relay; the phone pairing on the Remote panel minted from this same desk
 * and started nothing. Both screens showed six digits in the same shape,
 * and only one of them could be typed into another machine — the other fell
 * through to a direct attempt that most users have no route for. The failure
 * read as "the relay is broken", three metres from the machine that could have
 * explained.
 *
 * So minting and publishing are one call now, {@link show}, and there is
 * deliberately no second way to publish a beacon. The slot's life is the code's
 * life: every path that ends a code here — cancelled, redeemed, expired, or out
 * of guesses — takes the slot down with it, because a slot that outlives its
 * code is a machine advertising an address that will refuse whoever dials it.
 */
export interface PairingDesk {
  /**
   * Mint the one code, without publishing it anywhere.
   *
   * Kept for the tests, which mint codes against fixtures that have no relay to
   * publish to. Nothing that ships may call it: a second minting path is how the
   * two codes drifted apart in the first place, and `published-code.test.ts`
   * fails the build if one appears.
   */
  create(): PairingToken
  /**
   * Mint the one code and sit in the rendezvous slot it names until it dies.
   *
   * `offer` is this machine's address as {@link offerFrom} reads it off the
   * relay link, or null when the link is not up. Null is not a refusal: the code
   * is still minted and still redeemable by anything holding the address
   * already, which is what keeps the tailnet-served browser client working on a
   * machine with no relay. It comes back with `findable: false`, and it is the
   * caller's business whether that is worth refusing over.
   *
   * Resolves only once the slot is claimed, or once it is clear it will not be.
   * A code shown before its slot lands is a code that answers "no machine is
   * showing that" to anybody quick enough to type it.
   */
  show(offer: MachineOffer | null): Promise<ShownCode>
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

/**
 * @param publish The rendezvous seam. Replaced in tests, and only in tests: a
 * unit test that minted a code would otherwise open a WebSocket to the public
 * relay from whatever machine it ran on.
 */
export function pairingDesk(
  auth: RemoteAuth,
  now: () => number = Date.now,
  publish: typeof startBeacon = startBeacon,
): PairingDesk {
  let live: { digest: Buffer; expiresAt: number; misses: number } | null = null
  /** The slot this machine is sitting in for the code above, if it published. */
  let slot: Beacon | null = null
  let slotTimer: ReturnType<typeof setTimeout> | null = null
  const digestOf = (value: string): Buffer => createHash('sha256').update(value).digest()

  /**
   * Leave the rendezvous slot, and disarm the timer that would have.
   *
   * Every one of the four ways a code can end goes through `forget` below, which
   * goes through here — and that funnel is the point. The bug this arrangement
   * exists to prevent is a beacon still answering for a code the desk has
   * already thrown away, which is what a second, separate stop always eventually
   * produces: one of the two gets forgotten.
   */
  const takeDown = (): void => {
    if (slotTimer !== null) clearTimeout(slotTimer)
    slotTimer = null
    slot?.stop()
    slot = null
  }

  /** The code is over — cancelled, redeemed, expired, or out of guesses. */
  const forget = (): void => {
    live = null
    takeDown()
  }

  const expired = (): boolean => {
    if (!live) return true
    if (now() < live.expiresAt) return false
    forget()
    return true
  }

  const mint = (): PairingToken => {
    // A second code replaces the first, so the first one's slot goes now. Left
    // behind, it would answer for a code the trust store no longer honours.
    takeDown()
    const minted = auth.createPairingToken()
    // Only the digest is kept, for the same reason `RemoteAuth` keeps only a
    // digest: nothing in this process should hold a live bearer secret after
    // the call that showed it has returned.
    live = { digest: digestOf(minted.token), expiresAt: minted.expiresAt, misses: 0 }
    return minted
  }

  return {
    create: mint,
    async show(offer: MachineOffer | null): Promise<ShownCode> {
      const code = mint()
      // Captured by identity rather than by value. `mint` makes a fresh record
      // per code, so this is how everything below asks "is the code I minted
      // still the code on the desk" after an await that a cancel, a redemption
      // or a second press can land inside.
      const mine = live
      if (offer === null) return { code, findable: false }

      const beacon = publish({ code: code.token, offer, relayUrl: offer.relayUrl })
      // Null means the beacon could not even be constructed, which `startBeacon`
      // has already written to the log with the reason. There is nothing to add
      // here that the caller's sentence will not say better.
      if (beacon === null) return { code, findable: false }
      slot = beacon

      const claimed = await beacon.ready()
      if (live !== mine) {
        // The code died while the slot was being claimed. Whoever ended it has
        // already run `takeDown`, so this beacon is not `slot` any more and
        // nothing else will ever stop it.
        beacon.stop()
        return { code, findable: false }
      }
      if (!claimed) {
        takeDown()
        return { code, findable: false }
      }

      /*
       * One timer, tied to the life of the code that created it.
       *
       * Not a poll: it fires once, at the moment the thing it is waiting for
       * happens, and every other way the code can end clears it. It is needed
       * even though `expired()` above checks the clock, because that check only
       * runs when somebody asks — and on a machine nobody is pairing with, the
       * next question may be minutes away while the slot answers all of it.
       */
      slotTimer = setTimeout(() => {
        slotTimer = null
        if (live === mine) forget()
      }, Math.max(0, code.expiresAt - now()))
      slotTimer.unref?.()
      return { code, findable: true }
    },
    cancel(): void {
      forget()
    },
    offers(token: string): boolean {
      if (expired() || !live) return false
      if (timingSafeEqual(digestOf(token), live.digest)) return true
      /*
       * A wrong answer costs the code one of five lives.
       *
       * `RemoteAuth` already limits guesses per source address, and on the
       * tailnet that is the guesser's IP. Through the relay it is not: there is
       * no address to have, so `relay-client.ts` uses the device's authenticated
       * public key instead — a far better identity for a *device*, and no
       * identity at all for somebody guessing, who mints a fresh key per attempt
       * and lands in a fresh bucket every time.
       *
       * That did not matter while the token was 256 bits from `randomBytes`,
       * which is why the caller below is allowed to refuse a wrong code without
       * ever reaching the limiter. It matters enormously now that the token is
       * **six digits**. So the count lives with the code itself, where the
       * guesser cannot get away from it: five wrong answers and the code is
       * dead, whoever sent them and from wherever.
       *
       * This counter is the single line that makes the arithmetic in
       * `shared/short-code.ts` come out at 5 × 10⁻⁶ rather than at "as many
       * tries as you like against a million". Delete it and the format is
       * indefensible; there is no second counter anywhere behind it that would
       * catch a guesser who mints a fresh key per attempt.
       */
      live.misses += 1
      if (live.misses >= MAX_FAILED_ATTEMPTS) forget()
      return false
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
export function authenticatorFor(
  auth: RemoteAuth,
  desk: PairingDesk,
  /**
   * Told when a code is spent and a device row exists, before it is approved.
   *
   * Optional and ignored by every caller but one. See
   * {@link RemoteIpcDeps.onDevicePaired} for why a callback beats the loop it
   * replaces.
   */
  onPaired?: (device: Device) => void,
): RemoteAuthenticator {
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
      // create a device row on its way to being refused — and, far more
      // importantly, so that every wrong answer is counted. `desk.offers` is
      // where the five-guesses-per-code limit lives, and it is the only thing
      // between six digits and unlimited attempts: `redeemPairingToken`'s own
      // limiter keys on the source address, which through the relay is a public
      // key a guesser mints fresh for every try. Returning early here without
      // asking the desk would hand an attacker a free retry, so this call must
      // stay on the path of every guess, wrong ones included.
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

      /*
       * Say it happened, before the refusal is written.
       *
       * Ordering matters and it is not cosmetic: the message below tells the
       * device to come back once it is approved, and on a host that approves
       * automatically the device does exactly that — immediately. A listener
       * called after the frame had gone out would be racing the reconnect it
       * caused, and the reconnect would lose, leaving a device that paired,
       * was refused, and then found itself still pending.
       *
       * Thrown errors are swallowed on purpose. This is a notification, and a
       * listener that fails must not turn a completed pairing into a refusal
       * with no credential — that would strand the device permanently, since
       * the code has already been burned and cannot be redeemed twice.
       */
      if (onPaired) {
        try {
          onPaired(redeemed.device)
        } catch (error) {
          console.error('[remote] a listener for a new pairing threw:', error)
        }
      }

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
    // Nothing to tell when the server is not up: the device is not connected,
    // and it reads the new list in its `welcome` the next time it is.
    foldersChanged: (deviceId) => endpoint?.foldersChanged(deviceId) ?? 0,
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
  /**
   * Which folders each device may start a session in.
   *
   * Passed in rather than constructed here, even though the trust store beside
   * it is constructed here, and the reason is which end of the app reads it.
   * `index.ts` needs this object *before* this function is called — the folder
   * rule it hands to `SessionFanout` closes over it — so building a second one
   * here would give the panel a store that writes the same file as the one
   * sessions are checked against and holds a different copy of it in memory. One
   * instance, owned by the caller that needs it first.
   */
  folders: FolderGrants
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
  /**
   * The GitHub credential proxy, when this build has one running.
   *
   * Passed in for the same reason `folders` is: `index.ts` needs it *before* this
   * function is called, because the session spawn path closes over it to put a
   * key into each guest session's environment. Building a second one here would
   * mean sockets routed to one desk and sessions keyed against another.
   */
  credentials?: CredentialProxy
  /**
   * The dev-server module, when this build has one.
   *
   * Passed in for the same reason `folders` and `credentials` are: `index.ts`
   * builds it before this function is called, because the desktop's own start
   * page drives the same object. One instance, or a phone and the window each
   * watch their own idea of whether a project's server is up.
   */
  devServers?: DevServers
  /**
   * The ceiling on what this host advertises. See {@link RemoteEndpointOptions.offer}.
   *
   * Forwarded rather than recomputed, because the thing that knows a host is a
   * public demo box is the assembly that built it, and this function is the only
   * road from there to the endpoint.
   */
  offer?: readonly string[]
  port?: number
  /** Push an event at the renderer. `index.ts` already has exactly this function. */
  broadcast(channel: string, payload: unknown): void
  /**
   * Told the moment a device redeems a pairing code, with the row that was
   * created for it. **It is not yet approved when this runs**, and that is the
   * whole reason the hook exists.
   *
   * Until now the only way to find out was to ask: `terminaldeck pair` prints a
   * code and then asks a *person* to press Enter once the phone says it is
   * waiting, and its own comment explains why — there was no event to subscribe
   * to, and the standing rule here is events, not polling. A person is a fine
   * event when there is one standing at the keyboard. There is not one at a demo
   * box, and a broker that looped asking "has anything paired yet" would break
   * the rule for a worse reason than the one it was written for.
   *
   * So the daemon says so, once, at the moment it already knows. The desk's
   * `remote:device:next` channel is what turns it back into an answer, and
   * `terminaldeck pair` loses its "press Enter" step for everybody as a result.
   *
   * Deliberately *not* a place to approve from in the general case: approval is
   * the second of the two gates and a human owns it. The public demo host is the
   * one assembly that replaces that human with the broker's allocation, and it
   * does so in its own file where the trade can be read in one place — see
   * `src/headless/public-host.ts`.
   */
  onDevicePaired?(device: Device): void
  /**
   * Told whenever the relay link connects or drops.
   *
   * Nothing with a window needs it — a panel reads `remote:status` when it
   * draws. A headless host does: the public demo container has to tell the
   * broker that started it when it is genuinely reachable, and "the process is
   * up" is not that. The first real allocation on the demo box failed exactly
   * here, with *"this host is not on the relay (no relay at all)"*, because the
   * container announced itself the moment its control socket was listening and
   * the relay dial had not finished.
   */
  onRelayState?(state: RelayState): void
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
  /**
   * The one code that is on screen, whoever put it there.
   *
   * Handed out because pairing a second *desktop* needs the same code and the
   * same window as pairing a phone, and there is deliberately only one of each.
   * `remote/machines.ts` publishes a rendezvous while a code is live and takes
   * it down again the moment the code is spent or cancelled, and it can only do
   * that if it is looking at the same desk this file's `remote:pair` handler
   * writes to. A second desk would mean two codes could be open at once and
   * only one of them would be believed — which is the shape of a pairing screen
   * that says a code is valid while the machine refuses it.
   */
  desk: PairingDesk
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
function relayFor(
  storageDir: string,
  url: string,
  auth: RemoteAuth,
  desk: PairingDesk,
  onState?: (state: RelayState) => void,
): RelayLink {
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
            ...(onState ? { onState } : {}),
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
export function registerRemoteIpc(ipcMain: InvokeRegistrar, deps: RemoteIpcDeps): RemoteIpc {
  const auth = new RemoteAuth(deps.storageDir)
  const desk = pairingDesk(auth)
  const env = deps.env ?? process.env

  // Built here rather than inside the server, because this is the only place
  // that holds the trust store and the storage directory. Building it dials
  // nothing and writes no key on its own — `start()` at the bottom of this
  // function is what does both, on every launch unless this Mac was switched
  // off.
  const relay = relayEnabled(env, deps.relayEnabled)
    ? relayFor(deps.storageDir, relayUrl(env, deps.relayUrl), auth, desk, deps.onRelayState)
    : null

  const server = createRemoteServer({
    sessions: deps.sessions,
    auth: authenticatorFor(auth, desk, deps.onDevicePaired),
    webRoot: deps.webRoot,
    certDir: deps.storageDir,
    ...(deps.uploadsDir ? { uploadsDir: deps.uploadsDir } : {}),
    ...(deps.credentials ? { credentials: deps.credentials } : {}),
    // Spread rather than passed as possibly-undefined, like everything else that
    // is a switch: absent means this host does not advertise `devserver` at all.
    ...(deps.devServers ? { devServers: deps.devServers } : {}),
    ...(deps.offer ? { offer: deps.offer } : {}),
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

  /**
   * The code the Remote panel shows a phone, published the same way every other
   * code this product shows is published.
   *
   * It used to be `desk.create()` and nothing else, and that one missing half is
   * worth writing down. The panel used to offer two ways to use the same code:
   * scan a QR that carried this machine's relay address inside a link, or type
   * the code into something that has no address at all. The second only works if
   * this machine is sitting in the rendezvous slot the code names — and nothing
   * here ever put it there. The characters were valid, the screen was right, and
   * the other end reported that no machine was showing that code.
   *
   * There is no QR and no link any more, so typing is the only way in and the
   * rendezvous is no longer one path of two — it is the path. This still does
   * not refuse when there is no address to publish, and that is now a narrower
   * claim than it used to be: the one client a `findable: false` code still
   * works for is the browser client served *by this machine* over the tailnet,
   * where the page's own origin is the address and no lookup is needed. Every
   * other client — iOS, Android, a second desktop — needs the slot.
   *
   * ## Why the answer carries `findable`, and why that is not optional
   *
   * `desk.show` computes it on four separate paths — no address to publish, a
   * beacon that could not be constructed, a slot that did not come up inside
   * `BEACON_READY_TIMEOUT_MS`, and a code that died while the slot was being
   * claimed — and this handler used to throw it away and answer with the
   * code alone. Every one of those paths therefore produced the same screen as
   * success: six digits and a countdown, on a machine that nothing could look
   * up. The person types them into a phone, the phone finds an empty slot, and
   * the only sentence anybody sees is the phone's "no machine is showing that
   * code" — sixty seconds later, on the wrong device, blaming the wrong end.
   *
   * So it travels. The panel refuses to present an unfindable code as one a
   * phone can use, which is the only place that failure can be reported while
   * somebody is still standing in front of the machine that caused it. This
   * stays true even after every cause is fixed: a relay that is down, a network
   * that blocks it, or a laptop that woke up on a captive-portal wifi all land
   * here again, and silence is the one answer that must not be possible.
   */
  ipcMain.handle('remote:pair', async (): Promise<ShownPairingCode> => {
    const shown = await desk.show(offerFrom(server.status().relay))
    return { ...shown.code, findable: shown.findable }
  })
  ipcMain.handle('remote:pair:cancel', (): { cancelled: true } => {
    // Both halves. `cancel` leaves the rendezvous slot as well as forgetting the
    // code, or Close would be a button that only stops drawing it.
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
      // And its folder list goes with it. Revocation is permanent — a returning
      // phone pairs again and is issued a *new* device id — so the row left
      // behind could never be reached by anything again.
      deps.folders.forget(id)
    }
    return auth.listDevices()
  })

  /**
   * Which folders each device may use, and the one write that changes them.
   *
   * Both answer with the whole list, the same way the device channels above
   * answer with the whole roster: the panel then renders what the main process
   * says rather than what it just asked for, which is the rule this screen is
   * built on — nothing on it may claim an outcome it has not read back.
   *
   * Devices with no chosen list simply do not appear. That is the fallback
   * state, and inventing a row for it here would make "not chosen" and "chosen,
   * and it happens to be everything this desktop has open" look identical in
   * the panel when they behave differently the moment a project is closed.
   */
  ipcMain.handle('remote:folders', (): DeviceFolderGrant[] => deps.folders.list())
  ipcMain.handle(
    'remote:folders:set',
    (_event, id: unknown, folders: unknown): DeviceFolderGrant[] => {
      if (typeof id !== 'string' || !Array.isArray(folders)) return deps.folders.list()
      deps.folders.set(id, folders)
      // The rule is already live for the next request — `folders()` is read per
      // `create` — so this is only about the picker on the phone, which would
      // otherwise keep offering a folder that has been taken away until someone
      // reconnected it.
      server.foldersChanged(id)
      return deps.folders.list()
    },
  )

  return { server, auth, desk }
}
