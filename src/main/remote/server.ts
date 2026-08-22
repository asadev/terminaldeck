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
import { createEnrollAccess, type EnrollAccess } from './enroll'
// Type-only, deliberately. The store is built by `index.ts` and handed to
// `registerRemoteIpc`; importing the class here would put a second constructor
// for the same file in the one module that must not own it.
import type { DeviceFolderGrant, FolderGrants } from './folder-grants'
// The second grant store, type-only for the reason `FolderGrants` above is:
// `host-core.ts` owns the one instance, because the session fanout's predicate
// closes over it before this function is ever called.
import type { DeviceSessionGrant, SessionGrants } from './session-grants'
// The third grant store, type-only for the reason the two above are: `host-core.ts`
// owns the one instance, because the endpoint's own filter closes over it before
// this function is ever called.
import type { AccountGrants, DeviceAccountGrant } from './account-grants'
import type { WindowGrants } from './window-grants'
import type { WindowAskDesk } from './window-asks'
// `asDeviceKind` is a value because the approve handler has to narrow whatever
// came across the bridge, and it is three comparisons over a string literal
// union — importing it pulls in the store's module but not its file, and the
// store itself stays type-only for the reason `FolderGrants` above does.
import { asDeviceKind, type DeviceKindRecord, type DeviceKinds } from './device-kind'
// Type-only for the same reason `FolderGrants` is: `index.ts` owns the one
// instance, and `copilotFrameAllowed` is a pure function over a table, so
// importing it pulls in nothing but `protocol.ts` — which this file already has.
import { copilotFrameAllowed, type CopilotRemote, type CopilotSink } from './copilot-remote'
// Type-only, for the reason `FolderGrants` above is: `index.ts` owns the one
// instance of this store, and a class import here would be a second constructor
// for a file whose whole point is that there is one copy of it in memory.
import type { CopilotAccess, CopilotReach } from './copilot-access'
import {
  CAPABILITIES,
  CAPABILITY,
  CLOSE,
  MAX_CHAT_ROWS,
  MAX_COPILOT_LOG_ROWS,
  MAX_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  chunkOutput,
  parseClientMessage,
  serialize,
  type ClientMessage,
  type CopilotChatMessage,
  type CopilotLinkWire,
  type ControlName,
  type ControlReadingWire,
  type AccountWire,
  type ControlsReadingWire,
  type DeviceDescriptor,
  type DevServerReport,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
  type UsageAnswerWire,
} from './protocol'
// The one comparison this app has for "are these two paths the same folder",
// borrowed rather than restated. A second idea of folder equality here would be
// a device granted `/Users/asad/proj` being refused `/Users/asad/proj/`, and on
// Windows a folder visibly on the list being refused over a drive letter's case.
// `session-create.ts`'s only runtime dependency in this direction is a type, so
// there is no cycle.
import { isAbsoluteFolder, sameFolder, withinFolder } from './session-create'
/*
 * The scheme gate, from `browser-url.ts` and deliberately **not** from
 * `link-open.ts`.
 *
 * `routeGuestLink` is the rule this wants and it lives in a module that imports
 * Electron, and this file may not: it is bundled by `scripts/remote-host.sh` and
 * by the headless build, both of which run under plain Node. Importing it cost
 * exactly that — `Dynamic require of "fs" is not supported`, from an
 * `electron/index.js` that had been dragged into an esbuild bundle by one
 * import. The predicate underneath is the same one either way: `routeGuestLink`
 * *is* `isNavigationAllowed`, and that is pure by design so it can be tested
 * without a window.
 */
import { BLANK_URL, isNavigationAllowed } from '../browser-url'
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
  type UploadStore,
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
import { describeThisMachine } from './machines/guest'
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
  /**
   * May this device see and touch this session at all?
   *
   * **Optional, and absent means this host has no per-device rule** — see
   * `SessionFanout`'s `reach`, which is what its presence is derived from. A
   * host with a session layer and no notion of who is asking (the demo box,
   * `scripts/remote-host.ts`) supplies neither and behaves as it always did.
   *
   * Consulted at every door in this file that names a session — the welcome
   * frame, `list`, `attach`, every `input`/`resize`, `close`, both `controls`
   * verbs, `usage.read` and `session.send` — rather than once at attach. That is
   * not belt-and-braces, it is the difference between a folder being taken back
   * now and being taken back at the next reconnection: a device holding a handle
   * would otherwise keep a keyboard on a session in a folder somebody had just
   * removed, and the person removing it would have no way to tell.
   *
   * It is also the *only* door two of those verbs have. `controls.apply` and
   * `session.send` both write into a pty with no attach anywhere in their path,
   * on purpose — see `sendServe` for the argument — so this rule is not a second
   * check behind a handle for them, it is the check.
   */
  visible?(deviceId: string, sessionId: string): boolean
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
   * End a session. **Optional, and its absence is the switch**, exactly as
   * {@link create}'s is.
   *
   * A session layer that cannot end anything simply does not have this method,
   * the `close` capability is then never advertised, and a client talking to
   * such a host never draws a Close button and never sends a frame that would be
   * refused. `scripts/remote-host.ts` is the host that makes the split real
   * rather than theoretical: it can start a session for a stranger and must not
   * offer that stranger a way to end somebody else's.
   *
   * Returns whether a session was actually ended. False means there was no such
   * session — already exited, or never there — and the caller turns it into the
   * same sentence an unknown id gets on `attach`. It is **not** the refusal path:
   * whether this device may touch this session is decided by {@link visible}
   * before this is ever called, because a method that answered both questions
   * with one boolean would make "you may not" and "it is gone" the same fact.
   *
   * Synchronous, unlike `create`. Ending a session is signalling a process this
   * app already holds a handle to and forgetting it; nothing here resolves a
   * PATH or probes for a CLI, and a promise would only be a promise the caller
   * has to remember not to leave unhandled on a socket's data handler.
   */
  close?(id: string): boolean
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
  /**
   * Read and set a session's model, effort and fast mode. **Optional, and its
   * absence is the switch**, exactly as {@link create}'s and {@link close}'s are.
   *
   * A session layer that cannot read a screen simply does not have this, the
   * `controls` capability is then never advertised, and a client talking to such
   * a host draws the sentence it drew before this existed rather than a menu
   * whose every press is refused. `scripts/remote-host.ts` and the public demo
   * box are both in that position: they have terminals and no shadow emulator to
   * read one off.
   *
   * One object rather than two methods, and that is the point of it. Reading and
   * setting are useless apart — a menu that can write and not read shows
   * "Unknown" for ever with no tick in it, and one that can read and not write is
   * a label — so a host either has both or advertises neither, and there is no
   * arrangement of flags that can produce half a feature.
   *
   * Both are asynchronous because both really are: reading waits for the
   * emulator to finish parsing what the pty has written, and setting types a
   * command and waits for the CLI to answer it, which is seconds.
   */
  controls?: RemoteControlsAccess
  /**
   * What this session's account has spent and how full its context window is.
   * **Optional, and its absence is the switch**, exactly as {@link controls}'s
   * is.
   *
   * A host with no usage layer — `scripts/remote-host.ts`, the public demo box —
   * simply does not have this, the `usage` capability is never advertised, and
   * the window on the far side keeps saying what it said before rather than
   * drawing a bar that answers nothing. The same additive rule every capability
   * on this wire follows.
   *
   * One object rather than three methods for the reason {@link controls} is one:
   * the three readings are one feature, a bar that could read a context window
   * and not a plan limit is half a bar, and there is no arrangement of flags
   * that should be able to produce that.
   */
  usage?: RemoteUsageAccess
  /**
   * That session's conversation, as bubbles.
   *
   * **Optional, and its absence is the switch**, exactly as {@link controls}'s
   * and {@link usage}'s are: a host with no transcript reader — the demo box,
   * the stub — simply does not have this, `CAPABILITY.chat` is never advertised,
   * and a client draws a terminal and no chat toggle rather than a toggle whose
   * every press comes back empty.
   */
  chat?: RemoteChatAccess
  /**
   * Whose login a session is on, which logins this machine has, and running a
   * session as a different one. **Optional, and its absence is the switch**,
   * exactly as {@link controls}'s and {@link usage}'s are.
   *
   * Separate from {@link controls} because it is a different act. Those four are
   * a slash command typed into a session that survives it; this stops the agent
   * and starts another under a different config directory, so the session it
   * produces has a **new id** — which is why {@link RemoteAccountAccess.switch}
   * answers with one and why a host that can read a screen is not automatically
   * a host that can do this. `scripts/remote-host.ts` has terminals and no
   * account store; the headless build has an account store and no session
   * lifecycle to replace one through.
   *
   * One object rather than two methods for the reason {@link controls} is one: a
   * chip that could switch and not read has nothing to put a tick beside, and
   * one that could read and not switch is a label.
   */
  account?: RemoteAccountAccess
  /**
   * This machine's logins with no session in the question, and signing one of
   * them in here. **Optional, and its absence is the switch**, exactly as
   * {@link account}'s is.
   *
   * Separate from {@link account} because it is a different question with a
   * different door. That one is *whose login is this terminal running as* and is
   * answered for anybody who may touch the terminal; this one is *what logins
   * does this computer have* and is answered only for one of the owner's own
   * devices. A host can perfectly well have the first and not the second — the
   * stub host has neither, and a build with an account store but no session
   * lifecycle can list logins and start nothing.
   */
  logins?: RemoteLoginsAccess
}

/**
 * The far end of `logins.read` and `logins.signin`.
 *
 * A courier's interface like {@link RemoteAccountAccess}, and one object for the
 * same reason: a pane that could start a sign-in and not read the list would
 * have nothing to offer the sign-in *for*, and one that could read and not sign
 * in is the pane this replaces — which said, in a `Notice`, that it could only
 * read.
 *
 * Neither method may throw for an ordinary refusal. An account this machine does
 * not have, a session layer that would not start a terminal — those are answers
 * with sentences in them, and `server.ts` turns a rejected promise into a bare
 * `unavailable` that says nothing useful.
 */
export interface RemoteLoginsAccess {
  /**
   * Every login on this machine, as its own Accounts screen lists them.
   *
   * The same reader `RemoteAccountAccess.read` uses for its list half, so the
   * pane and the chip cannot come to disagree about what this computer has.
   */
  read(): Promise<AccountWire[]>
  /**
   * Start signing that login in, on this machine.
   *
   * `session` is the terminal that was opened for it — the agent CLIs
   * authenticate interactively, so there is nothing that could be done silently
   * and the honest act is to open the same session the window at this desk
   * opens — and null when none was, which is every refusal.
   *
   * It does not claim the login succeeded. Whether it did is a question for the
   * next {@link read}, which reads this machine's own probe.
   */
  signIn(accountId: string): Promise<{ ok: boolean; message: string; session: string | null }>
}

/**
 * The far end of `account.read` and `account.switch`.
 *
 * A courier's interface, like {@link RemoteControlsAccess}: it takes a session
 * id and hands back what this machine's own account store and its own switch
 * said. The desktop that assembles it wires `switch` to the same operation the
 * window at that desk performs from its own account chip — one mechanism, two
 * callers — because two implementations of "run this session as somebody else"
 * is how one of them comes to skip the conversation guard.
 *
 * Neither method may throw for an ordinary refusal. A session that is gone, an
 * account that has never signed in, an agent that cannot be started at all —
 * those are answers with sentences in them, and `server.ts` turns a rejected
 * promise into a bare `unavailable` that says nothing useful.
 */
export interface RemoteAccountAccess {
  /**
   * Whose login this session is on, and what else this machine has.
   *
   * `current` is null when that could not be established — a session this app
   * did not start, an agent that reported nothing — and null must stay null. A
   * chip naming the default account over a session that is on a different one
   * is the defect the whole area exists to remove.
   */
  read(sessionId: string): Promise<{ current: AccountWire | null; accounts: AccountWire[] }>
  /**
   * Run that session as another of this machine's logins.
   *
   * `session` is the id the session has afterwards — the same one on a refusal,
   * a new one on a success — so the asking client can follow the tab it is
   * already looking at instead of holding a handle to a process that is gone.
   */
  switch(
    sessionId: string,
    accountId: string,
  ): Promise<{ ok: boolean; message: string; session: string | null }>
}

/**
 * The far end of `usage.read`.
 *
 * A courier's interface like {@link RemoteControlsAccess}, and split into three
 * methods for one reason: **they cost wildly different amounts and the split is
 * what keeps the dear one out of the cheap one's code path.** A single
 * `read(want)` would put all three behind one call site, and the first time
 * somebody wired that call site to a mount the host would boot an agent CLI per
 * tab.
 *
 * Every method answers with the record that host's *own* window is handed for
 * the same session. Nothing is re-shaped for the wire — see `UsageAnswerWire` —
 * so a machine one version ahead reports what its own build reports.
 *
 * None of them may throw for an ordinary absence. A session that is gone, an
 * account with no limits, an agent that writes no token counts — all of those
 * are readings with sentences in them, and `server.ts` turns a rejected promise
 * into a bare `unavailable` that says nothing useful.
 */
/**
 * The far end of `chat.read`.
 *
 * A courier's interface like {@link RemoteControlsAccess} and, like it, a
 * *second caller* of an existing reader rather than a second implementation:
 * `chat-transcript.ts` collapses the JSONL an agent is already writing into
 * bubbles, and `chat:load`/`chat:tail` is the window at this desk asking the
 * same two questions. What is new here is only that the questions can be asked
 * from somewhere else.
 *
 * It may not throw for an ordinary absence — a session that is gone, a folder
 * with no transcript, a conversation nothing has written to yet. `server.ts`
 * turns a rejected promise into a bare `unavailable` that says nothing useful,
 * and "there is no transcript" is a state a chat view knows how to draw.
 */
export interface RemoteChatAccess {
  /**
   * That session's conversation, or what has changed since the last read.
   *
   * `tail` false is the whole conversation and answers `reset: true`; true is
   * the difference since *this viewer's* last read.
   *
   * `viewer` is the device id, and it is here rather than left implicit because
   * a cursor is per reader and a shared one loses messages silently. The local
   * `chat:tail` keys its readers by transcript path, which is right for one
   * process drawing its own windows; over a wire it would mean two phones on one
   * session, or a phone and the Mac's own chat view, consuming each other's new
   * bubbles — each seeing half a conversation with nothing on screen to say so.
   *
   * `found` is false when there is no transcript for the folder at all, which is
   * a different empty state from a session that has not spoken yet.
   */
  read(
    sessionId: string,
    tail: boolean,
    viewer: string,
  ): Promise<{ rows: CopilotChatMessage[]; reset: boolean; found: boolean }>
}

export interface RemoteUsageAccess {
  /**
   * What this machine already knows about that session's subscription windows.
   *
   * **Free, and it has to stay free.** Memory, plus one file for a Codex login.
   * This is what a bar mounting over a remote session asks for, so anything that
   * made it spawn would put the expensive reading on the cheap one's schedule —
   * which is the single constraint this whole capability was designed around.
   */
  plan(sessionId: string): Promise<Record<string, unknown>>
  /**
   * Go and find out — the reading that costs.
   *
   * Boots Claude Code on this machine: 725 MB peak, about three seconds,
   * measured on 2026-08-19. Reached only because a person opened the panel on
   * the far window or pressed the retry inside it, which is the same event that
   * spends the same amount locally.
   *
   * `force` is that person overriding rather than this app looking: it reaches
   * past the five-minute throttle the CLI keeps on its own figure and past a
   * login already settled on "no subscription limits".
   *
   * Answers with the refresh outcome *and* the report it produced, in one
   * record. The local path gets the second half over a push channel; there is no
   * push on this wire, and a second round trip to collect a number this machine
   * is already holding would be a second chance for the answer to go missing.
   */
  refresh(sessionId: string, force: boolean): Promise<Record<string, unknown>>
  /**
   * How full that session's context window is, read off the transcript.
   *
   * A bounded tail read of a file the agent is already writing — 2–17 ms — so it
   * may be asked for on the same events the local figure is re-read on.
   */
  context(sessionId: string): Promise<Record<string, unknown>>
}

/**
 * The far end of `controls.read` and `controls.apply`.
 *
 * Deliberately a courier's interface and not a controls implementation. It takes
 * a session id, a control name and a value and hands back what
 * `src/main/agent-controls.ts` said — the desktop that assembles this wires it
 * straight to that module against its own PTY manager, which is the same call
 * the window on that machine makes for its own bar. One mechanism, two callers.
 *
 * Neither method may throw for an ordinary refusal. A session that is gone, an
 * account that may not have that model, a session mid-turn — all of those are
 * answers with sentences in them, and `server.ts` turns a rejected promise into
 * a bare `unavailable` that says nothing.
 */
export interface RemoteControlsAccess {
  /**
   * What that session's controls say right now. Passive: nothing is typed.
   *
   * `live: false` in the answer is how "there is no such session" arrives, so a
   * caller never has to tell a missing session from a broken read.
   */
  read(sessionId: string): Promise<ControlsReadingWire>
  /**
   * Set one, and report what the CLI said about it.
   *
   * The value is a string that has already been through the parser's character
   * class — see `controls.apply` — and it is still not trusted to be *a* value:
   * the far end checks it against the CLI's own accepted list before typing
   * anything, which is where a model name nobody has heard of is refused in the
   * CLI's words rather than this app's.
   */
  apply(
    sessionId: string,
    control: ControlName,
    value: string,
  ): Promise<{ ok: boolean; message: string; reading: ControlReadingWire }>
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
   * Sessions running on **that device's** own computer, as it announced them.
   *
   * Empty for every phone, and that is the ordinary case rather than a gap: a
   * browser tab has no ptys and nothing to announce. Non-empty only for another
   * desktop running this app, which sends `sessions.mine` on `hostWindows`.
   *
   * Here rather than on its own channel because it changes exactly when the rest
   * of this row does and travels on the push that already exists — and because
   * the one screen that needs it, the browser's attach menu, needs the device's
   * *name* in the same breath to label the rows with.
   *
   * Never confuse it with {@link sessionIds} above, which is this machine's
   * sessions that device is watching. Opposite computers, opposite directions.
   */
  sessions: RemoteSession[]
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
  /**
   * Sign-in, when this host serves it. **Absent is the switch**, as everywhere.
   *
   * With no access here an `enroll` frame is refused `unavailable` — the demo box
   * and any build with sign-in off are exactly that. Present, it turns a login to
   * this machine's own sshd into a pre-approved device over the sealed channel;
   * the connection still authenticates through the ordinary `hello` afterwards,
   * so this grants nothing on its own.
   */
  enroll?: EnrollAccess
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
   * The desk holding this machine's questions to a device about a browser
   * window it is showing.
   *
   * **Absent is the switch**, as everywhere else here: with no desk the
   * `windows` capability is not advertised, a device never says it can serve
   * one, and a session started for a device is launched without the browser
   * verbs and told why — rather than holding six tools whose every call would
   * end in a timeout.
   *
   * Injected rather than constructed here because the same desk is what
   * `deck-control`'s browser tools reach when they forward a verb: one desk, or
   * the frame goes out on a socket and the answer is matched against a table
   * nobody sent from.
   */
  windows?: WindowAskDesk
  /**
   * Serving a browser verb that arrived **from** a device, against a window in
   * this app.
   *
   * The mirror of {@link windows} above, and the two are not the same feature
   * read twice: `windows` is this machine asking a device to move a browser it
   * holds, this is a device asking this machine to move one *here*. Which of the
   * two a given link needs depends only on which end the person is sitting at,
   * and a desktop that dialled another desktop can need both at once.
   *
   * **Absent is the switch**, as everywhere else here: with no server the
   * `hostWindows` capability is not advertised, so a device never sends the
   * frame and never waits on an answer that is not coming.
   *
   * Nothing about the decision is here. The grant is read per call in
   * `window-grants.ts`, the allow-list is `ELSEWHERE_TOOLS` — the session grant
   * minus the tools whose answers are files on this computer — the window is
   * resolved inside that session's own binding, and the answer is cut to fit by
   * `fitAnswer` — all of it in `machines/window-serve.ts`, which is the same
   * function the machine links serve their asks through. One decider, or the two
   * come to allow what each other refuses.
   */
  serveWindows?(
    deviceId: string,
    call: { sessionId: string; tool: string; args: string },
  ): Promise<{ ok: boolean; body: string }>
  /**
   * Which of **that device's** sessions this app is holding a browser window
   * for, asked whenever the answer has to be sent.
   *
   * The other half of {@link serveWindows}, and the half without which it would
   * never fire: a session over there cannot address a window here unless it has
   * been told there is one. A window attached in this app is a relation in *this*
   * process — `browser-binding.ts` — and the machine the pty is on has no way to
   * derive it.
   *
   * A function rather than a list, read at the moment of sending, because the
   * answer changes every time somebody attaches or detaches a window; and per
   * device, because a link may only be told about its own — the sessions of one
   * paired computer are not facts the next one gets to hear.
   */
  windowsHeldFor?(deviceId: string): readonly string[]
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
   * The copilot, as a paired device may touch it. **Absent is the switch.**
   *
   * A host with no copilot layer does not advertise the `copilot` capability, so
   * a phone talking to it never draws a Copilot tab and this server never
   * receives a verb it would have to refuse — the same negotiation `uploadsDir`,
   * `credentials` and `devServers` get, and for the same reason.
   *
   * It matters more here than for any of those, because of who the other hosts
   * are. `scripts/remote-host.ts` and the headless daemon have sessions and no
   * copilot; the public demo box hands a shell to a stranger who has never met
   * the owner. Asad's constraint on this feature was explicit — *"we don't want
   * to give this copilot to others to see how we use it. This will be only
   * ours."* — and a capability that appeared on a demo box would be exactly the
   * thing he said not to build.
   *
   * The **grant** is a separate question from the capability and is read
   * per-message through {@link CopilotRemote.granted}; see `copilot-remote.ts`
   * for why the two must not be folded together.
   */
  copilot?: CopilotRemote
  /**
   * May this particular device be offered the copilot at all?
   *
   * **Optional, and absent means every paired device may** — which is what every
   * host written before device kinds existed does, and what the tests and
   * `scripts/remote-host.ts` still supply. A desktop that knows about kinds
   * answers it `kind === 'mine'`.
   *
   * This is his sentence, and it is the reason the answer is *absence* rather
   * than a grant defaulted off:
   *
   *   > **Guest** — You choose what they can reach. The copilot is never shared.
   *
   * So an ineligible device is not sent the `copilot` capability, is not sent a
   * `copilot` key in its welcome, and is refused `copilot.connect` outright. It
   * has no frame it can send that measures whether this machine has a copilot,
   * and its client draws no tab, no switch and no greyed-out row — because a
   * greyed-out row still advertises the feature and invites the ask, and the
   * answer to the ask is always no.
   *
   * It is a callback rather than a set for the reason `folders` is: the kind is
   * decided when a device is approved, which can happen while another device is
   * connected, and a snapshot taken at construction would be answering about a
   * roster that has changed.
   */
  copilotEligible?(deviceId: string): boolean
  /**
   * Which of this machine's coding logins this particular device may use.
   *
   * **Optional, and absent means every device may use every login** — which is
   * what every host written before account grants existed does, and what
   * `scripts/remote-host.ts` and the tests still supply. A desktop that keeps the
   * store hands `AccountGrants` straight in.
   *
   * The two questions are separate on purpose and both are used here:
   * {@link AccountGrants.any} decides whether the device is told the `account`
   * capability exists at all, so a device granted **none** draws no chip rather
   * than an empty one; {@link AccountGrants.shares} filters the list and refuses
   * a switch, so a grant narrowed while a machine is connected takes effect on
   * the next frame rather than on the next reconnection.
   *
   * A callback-shaped object rather than a snapshot, for the reason
   * {@link copilotEligible} is one: the choice is made when a device is approved
   * and edited afterwards from the settings panel, both of which can happen
   * while that device is connected.
   */
  accountAccess?: {
    shares(deviceId: string, accountId: string): boolean
    any(deviceId: string): boolean
  }
  /**
   * Is this device one of the owner's own, rather than a guest?
   *
   * **Optional, and absent means yes**, like {@link copilotEligible} — which is
   * the same fact asked by a different feature, and they are deliberately two
   * options rather than one shared predicate: folding them together would mean a
   * host that wanted to withhold one had silently withheld the other, and the
   * next person to add a third would have no way to tell which of the two
   * meanings they were extending.
   *
   * It gates `CAPABILITY.logins`: listing every login a machine has, and
   * starting a login flow on it, are acts on the **machine** rather than on a
   * folder somebody was lent. A guest gets the session-scoped chip its account
   * grant allows and nothing that manages the computer.
   */
  ownDevice?(deviceId: string): boolean
  /**
   * May this device name any folder on this machine, or only the ones offered?
   *
   * **Optional, and absent means no** — which is the fail-closed answer every
   * host written before this existed gets, and the right one: a host that cannot
   * tell its own laptop from a stranger's phone should treat both as the phone.
   * A desktop that knows about device kinds answers `kind === 'mine'`, which is
   * `reachFor`'s rule in `device-reach.ts` and not a second idea of it.
   *
   * It exists for one field, `upload.begin.dir`. {@link SessionAccess.folders}
   * is the enforced list for a guest and only a list of *suggestions* for one of
   * your own — `device-reach.ts` says so in as many words — so enforcing
   * containment against it for every device would mean a second laptop of your
   * own could only ever receive a file into a folder that happened to have a
   * project open in it. That is not a boundary, it is an accident of what was on
   * screen.
   *
   * A callback rather than a set, for the reason {@link copilotEligible} is: a
   * kind is decided when a device is approved, which can happen while that
   * device is connected.
   */
  unrestrictedFolders?(deviceId: string): boolean
  /**
   * Open a page on this machine, and say whether a window took it.
   *
   * **Optional, and absent is the switch** — the same negotiation `uploadsDir`,
   * `credentials`, `devServers` and `copilot` get. A host with no window has
   * nowhere to put a page, so it never advertises `web` and never receives the
   * verb; the Electron shell supplies `openAppLink` against its own window,
   * which is what makes the page appear as a tab of this app's browser rather
   * than as a launch of somebody's default browser.
   *
   * Synchronous and boolean, because the honest answer is available immediately:
   * the shell either had a window to push the URL to or it did not. What happens
   * to the page after that is the browser's business and not this socket's.
   */
  openUrl?(url: string): boolean
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
  /**
   * The sessions on this machine changed, because somebody at *this* keyboard
   * started or ended one. Tell every device. Returns how many were told.
   *
   * ## Why it did not exist, and what that cost
   *
   * A fresh `sessions` frame went out from exactly four places — a device's own
   * `create`, a device's own `close`, `tellFolders`, and the reply to `list` —
   * every one of which is a *device* doing something. Nothing fired when a
   * session was opened at the Mac's own keyboard, which is how nearly all of
   * them are opened. So the phone's list, a paired laptop's sidebar and its
   * session picker were a snapshot taken at connect time, and stayed that way
   * until something reconnected.
   *
   * Measured before it was fixed: the far machine went 2 → 5 → 7 sessions, and
   * the reaching machine said 2 for sixty seconds and through fifteen more of
   * polling; disconnecting and reconnecting moved it to 5 in under a second.
   * Asad, on the picker: *"It's not updated right away. Anyways, maybe we need
   * to refresh."* There is no refresh, and there should not need to be one —
   * this is the event that already exists, pushed rather than polled.
   *
   * Per connection rather than one shared list, for the reason `create` states:
   * two devices watching one machine are entitled to two different lists, and a
   * single value computed once and sent to everybody is a leak the moment a
   * per-device rule exists.
   */
  sessionsChanged(): number
  /**
   * A browser window in this app was attached to, or detached from, a session on
   * a device. Re-send the holdings to every connection that can hear them.
   *
   * The mirror of `MachinesIpc.announceWindows`, and the same shape of answer:
   * how many were told, which is zero when nobody is connected or when no
   * connected build knows the frame. Nothing is lost by that zero — the set is
   * re-stated on every welcome, which is the moment the far end's table is empty
   * anyway.
   */
  windowsHeldChanged(): number
  /**
   * One device's copilot grant changed on the desktop. Take away what it no
   * longer holds, and tell it.
   *
   * Returns how many of its connections were told, which is zero when it is not
   * connected — a normal outcome. The *rule* is live without this call, because
   * the grant is read per message and per tool call; what this does is stop a
   * revoked phone watching a conversation it can no longer influence, and drop
   * the MCP token its run was holding.
   */
  copilotGrantChanged(deviceId: string): number
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
  /**
   * A session was started or ended **here**, at this machine's own keyboard.
   * Push the new list to every connected device. Zero when none are connected.
   */
  sessionsChanged(): number
  /**
   * A browser window in this app was attached to, or detached from, a session on
   * a device. Re-send the holdings to every connection that can hear them.
   *
   * The mirror of `MachinesIpc.announceWindows`, and the same shape of answer:
   * how many were told, which is zero when nobody is connected or when no
   * connected build knows the frame. Nothing is lost by that zero — the set is
   * re-stated on every welcome, which is the moment the far end's table is empty
   * anyway.
   */
  windowsHeldChanged(): number
  /**
   * One device's copilot grant changed. Take away what it no longer holds, and
   * tell it. Zero when it is not connected.
   *
   * Note what happens when the server is *down*: the endpoint is null, so this
   * answers zero and tells nobody — and the run is not stopped either, because
   * there is no endpoint holding a reference to the copilot layer. That is
   * correct rather than a gap. With the server down there is no socket for the
   * phone to be driving anything over, its run has already lost its watcher, and
   * the grant is still read per tool call from the store the panel just wrote.
   */
  copilotGrantChanged(deviceId: string): number
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
  /**
   * What that device says is running on its own computer, from `sessions.mine`.
   *
   * Replaced whole every time the frame arrives, never merged: the frame is the
   * device's whole answer, so a merge would keep a terminal it has closed. Empty
   * until one arrives, which for a phone is forever.
   *
   * Held per connection rather than per device, like `capabilities` above and for
   * the same reason: it describes a running app, and a device that has gone has
   * nothing running. The list leaves with the socket.
   */
  sessions: RemoteSession[]
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
  /**
   * Undo for this connection's copilot subscription, or null when it has none.
   *
   * Made on `copilot.attach` and not before, for the reason `tunnels` and
   * `uploads` are made lazily: most phones never open the Copilot tab, and a
   * subscription per connection made eagerly would be a callback registered on
   * the run manager for every device that has not asked.
   *
   * Dropped on `copilot.detach`, on the socket closing, and on the grant being
   * revoked. **The run is not stopped with it** — see `copilot.detach`: a phone
   * that locked its screen in a lift has not asked for its agent to be killed
   * mid-turn.
   */
  copilot: (() => void) | null
  /**
   * Has this socket opened its copilot connection?
   *
   * **The gate in front of every `copilot.*` verb, read tier included.** False
   * until the client sends `copilot.hello` with the credential it was given when
   * somebody at this machine minted a connect code for it, and false again on
   * every reconnect — a session channel does not carry the copilot by existing.
   *
   * Per connection and not per device, deliberately. Two sockets from one phone
   * are two connections and each has to prove itself; a device that opened the
   * copilot on one socket and then dialled a second from somewhere else has not
   * authorised the second one. It is also what makes `copilot.bye` mean
   * something: a person closing the Copilot tab on a shared machine wants that
   * socket's access gone, not the credential deleted.
   *
   * See `copilot-link.ts` for why this exists at all — the short form is that
   * the second factor behind the `alter` tier moved from *be at the desk* to
   * *have been deliberately authorised for the copilot*, and this boolean is
   * where the desktop checks the second half of that sentence.
   */
  copilotOpen: boolean
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
    // Its opposite number, negotiated the same way and separately from it. A
    // host can genuinely start sessions and refuse to end them — the public demo
    // box is exactly that — so the two are two methods and two capabilities
    // rather than one flag read twice.
    if (name === CAPABILITY.close) return typeof options.sessions.close === 'function'
    // Same rule, same reason: the thing that makes the feature possible is the
    // thing that decides whether it is offered. A host with nowhere to put a file
    // must not draw a Send File button on somebody's phone.
    if (name === CAPABILITY.upload) return typeof options.uploadsDir === 'string' && options.uploadsDir !== ''
    // Same rule again. A host with no proxy would otherwise tell a phone it may
    // be asked for a GitHub login and then never ask, which is a screen in
    // somebody's app for a thing that cannot happen.
    if (name === CAPABILITY.credential) return options.credentials !== undefined
    /*
     * Same rule, running the same way round as `credential`: this one is a
     * question *this* machine asks a device, so what it is gated on is having a
     * desk to hold the question. Without one, a session here that tried to act
     * on a window over there would send a frame nothing was waiting to answer,
     * and the tool call would sit until the client's own timeout fired — which
     * is the fifty-five second stall `window-asks.ts` exists to not have.
     */
    if (name === CAPABILITY.windows) return options.windows !== undefined
    /*
     * And the mirror, gated on the thing that answers rather than on the thing
     * that asks. `windows` above is advertised when this machine has a *desk* —
     * somewhere to hold a question it is about to put to a device; this one is
     * advertised when it has a *server* — something that can act on a window
     * here when a device puts the question the other way.
     *
     * Not gated on the grant, deliberately, and the copilot's note two branches
     * down makes the argument in full: a capability says what this machine can
     * do and a grant says who may use it. Folding them together would leave a
     * device unable to tell "that build is too old" from "you have not been
     * allowed", which are two sentences with two different remedies — and would
     * make a tick applied mid-session unable to reach a connected device, since
     * the only frame carrying the capability is a `welcome`. The grant is read
     * per call instead, and refuses with a sentence naming the switch.
     */
    if (name === CAPABILITY.hostWindows) return options.serveWindows !== undefined
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
    /*
     * The object, and nothing else.
     *
     * Deliberately *not* also gated on any device holding a grant. The
     * capability says this desktop speaks these frames; the grant says whether
     * you may send them, and it travels per-device in `welcome.copilot` and in
     * the `copilot.grant` push. Folding the two together would make a phone
     * unable to tell "this desktop is too old to have a copilot" from "you have
     * not been given access" — two sentences with two different remedies — and
     * would leave a grant ticked mid-session unable to reach a connected phone,
     * because the only frame carrying it would be a `welcome`.
     */
    if (name === CAPABILITY.copilot) return options.copilot !== undefined
    /*
     * Same rule as every one above it: the thing that makes the feature possible
     * decides whether it is offered. A host with no window has nowhere to put a
     * page — the headless daemon and the demo box are both in that position —
     * and a client told otherwise would draw an Open button whose only outcome
     * is a refusal.
     *
     * Note what this is *not* gated on: which devices may use it. That is
     * `copilotEligible`, read per message, for the reason the copilot's own note
     * gives — a capability says what the machine can do and a grant says who may
     * ask, and folding them together makes "too old" and "not yours" the same
     * sentence. The difference is that `web` is stripped per device in
     * `capabilitiesFor`, because unlike a copilot grant there is no push frame
     * that could correct it later.
     */
    if (name === CAPABILITY.web) return typeof options.openUrl === 'function'
    /*
     * Same rule again, and here it decides more than a button: this is the
     * capability a client reads to know whether to draw a *model menu* over a
     * session on this machine at all. A host with no way to read a screen — the
     * stub host, the demo box — advertises nothing and the far window keeps the
     * sentence it has today, which is honest. Advertised on a boolean somebody
     * had to remember to set, it would eventually be a menu that types nothing.
     */
    if (name === CAPABILITY.controls) return options.sessions.controls !== undefined
    /*
     * Same rule once more, and here the honest absence matters more than usual:
     * a host that advertised this and could not answer would have the far bar
     * ask on every mount and then draw nothing, which reads as a broken figure
     * rather than as a host that has no figure. A stub host has terminals and no
     * usage layer, and saying so is what makes the far window keep the sentence
     * it already had.
     */
    if (name === CAPABILITY.usage) return options.sessions.usage !== undefined
    /*
     * And once more for the account chip. Gated on its own member rather than on
     * `controls`, because the two are genuinely separable: a host can read a
     * session's screen without having any way to replace that session's process,
     * and the stub host is exactly that. A chip advertised by a machine that
     * cannot switch would be a menu whose every row is refused after the press.
     */
    if (name === CAPABILITY.account) return options.sessions.account !== undefined
    /*
     * And once more for the machine's own login list. Its own member rather than
     * `account`'s, because the two are separable in both directions: a host can
     * answer "whose login is this session on" without keeping anything that could
     * start a login flow, and the demo box has neither.
     *
     * What this is *not* gated on is which devices may ask — that is
     * `ownDevice`, stripped per device in `capabilitiesFor` beside `web`, for the
     * reason `web`'s note gives: a capability says what the machine can do, a
     * grant says who may ask, and there is no push frame here that could correct
     * a welcome later.
     */
    if (name === CAPABILITY.logins) return options.sessions.logins !== undefined
    /*
     * And once more for the chat view. Its own member for the same reason the
     * account chip has one: reading a transcript and reading a *screen* are
     * different acts against different files, and the headless build has one and
     * not the other.
     */
    if (name === CAPABILITY.chat) return options.sessions.chat !== undefined
    /*
     * `send` is deliberately not in the list above, and the absence is the
     * decision rather than an omission.
     *
     * Every rule up there reads a capability off the object that makes it
     * possible — `controls` and `usage` off an optional member of
     * `SessionAccess`, `create` and `close` off optional methods — so the
     * advertisement cannot outlive the thing it advertises. `SessionAccess.write`
     * is a **required** member of that interface: there is no host, real or
     * stubbed, that has a session layer and cannot write into one. A gate here
     * would therefore be a condition that is true by construction, which is
     * worse than none — it reads as a negotiation somebody could get wrong
     * later.
     *
     * The one thing that can still take this away is `options.offer`, checked at
     * the top, and that is a decision about a particular host rather than a
     * capability it lacks. The public demo box uses it.
     */
    return true
  })

  /**
   * Whether this device may be told the copilot exists.
   *
   * Absent callback means yes, for every device — see
   * {@link RemoteEndpointOptions.copilotEligible}. Wrapped in a `try` because it
   * reaches a store on disk and it is consulted on the read path of a socket; an
   * exception here would be a main process that dies on a hello, and the safe
   * reading of "I do not know what kind of device this is" is the one that
   * offers nothing.
   */
  function copilotEligible(deviceId: string): boolean {
    const ask = options.copilotEligible
    if (!ask) return true
    try {
      return ask(deviceId) === true
    } catch (error) {
      console.error('[remote] the copilot-eligibility rule threw; treating the device as a guest:', error)
      return false
    }
  }

  /**
   * Whether this device is one of the owner's own.
   *
   * Absent callback means yes, for every device — see
   * {@link RemoteEndpointOptions.ownDevice}. Wrapped in a `try` for the reason
   * {@link copilotEligible} is: it reaches a store on disk and is consulted on
   * the read path of a socket, and the safe reading of "I do not know what kind
   * of device this is" is the one that manages nothing.
   */
  function ownDevice(deviceId: string): boolean {
    const ask = options.ownDevice
    if (!ask) return true
    try {
      return ask(deviceId) === true
    } catch (error) {
      console.error('[remote] the device-kind rule threw; treating the device as a guest:', error)
      return false
    }
  }

  /**
   * May this device use any of this machine's logins at all?
   *
   * Absent store means yes, for the reason every other absence here does: a host
   * with no account grants is every host written before they existed, and the
   * two machines already paired when they arrived had working account chips.
   *
   * Wrapped in a `try` like the two above it, and the safe reading here is the
   * *narrow* one — unlike `folders`, whose file failing open is argued for at
   * length in its own header, a store that **threw** is not a hand-edited
   * preference, it is a bug, and answering "yes, everything" on the strength of
   * an exception would be widening access because something broke.
   */
  function anyAccountFor(deviceId: string): boolean {
    const ask = options.accountAccess
    if (!ask) return true
    try {
      return ask.any(deviceId) === true
    } catch (error) {
      console.error('[remote] the account-grant rule threw; treating the device as granted none:', error)
      return false
    }
  }

  /** May this device use this one login? The same rule, one account at a time. */
  function accountShared(deviceId: string, accountId: string): boolean {
    const ask = options.accountAccess
    if (!ask) return true
    try {
      return ask.shares(deviceId, accountId) === true
    } catch (error) {
      console.error('[remote] the account-grant rule threw; refusing the account:', error)
      return false
    }
  }

  /**
   * What *this* device is told this host can do.
   *
   * The list is computed once for the endpoint, above, because it describes the
   * machine. This narrows it for one device, and there is exactly one thing in
   * it that is per-device: a guest is never told there is a copilot here. Every
   * other capability is a property of the host and is the same for everyone.
   *
   * Filtering the advertisement rather than only refusing the verb is the whole
   * of *"the copilot is never shared"* — a client that is told the capability
   * exists draws the tab, and a tab that refuses on every press is a worse
   * answer than a client that never knew.
   */
  function capabilitiesFor(deviceId: string): string[] {
    /*
     * Two per-device narrowings now, and they are independent of each other.
     *
     * A device granted **none** of this machine's logins is not told the
     * `account` capability exists, so the chip over a session here is absent on
     * its screen rather than drawn and empty. Asad's third sentence about the
     * accounts step is what this is: *"Untick all"* has to mean the feature is
     * not there, and a menu that opens onto nothing is the shape of defect this
     * app keeps being reviewed for. The refusal in `accountServe` is the other
     * half — this decides what a client of ours draws, that decides what any
     * client gets.
     *
     * And `logins` — the machine's own list, and starting a sign-in on it — goes
     * to one of the owner's own devices only. It is stripped here rather than
     * only refused for the reason `web` is: there is no push frame that could
     * correct a welcome later, so a guest must never be told it exists.
     */
    const withheld: string[] = []
    if (!anyAccountFor(deviceId)) withheld.push(CAPABILITY.account)
    if (!ownDevice(deviceId)) withheld.push(CAPABILITY.logins)
    const narrowed = withheld.length === 0 ? advertised : advertised.filter((name) => !withheld.includes(name))
    if (copilotEligible(deviceId)) return narrowed
    // `web` goes with it, and for the same reason: opening a page puts a window
    // on the owner's screen, which is driving the machine rather than reaching a
    // folder. One eligibility question behind both, so a device cannot be a
    // guest for one and an owner for the other.
    //
    // `localhost` used to be stripped here beside them, on the argument that a
    // port cannot be attributed to a folder. That argument is true of a *port
    // scan* and false of the ports this app started itself, and stripping the
    // capability made the difference invisible — see {@link grantedPorts}. A
    // guest is told the capability exists and is shown the ports its own grant
    // covers, which may be none; the narrowing is in the hub, where the same
    // list decides what is offered and what may be dialled.
    return narrowed.filter((name) => name !== CAPABILITY.copilot && name !== CAPABILITY.web)
  }

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
        sessions: [...connection.sessions],
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
  /**
   * May this device see what is listening here, and tunnel to it?
   *
   * ## The rule, stated
   *
   * **A device of your own reaches every port on this machine. A guest reaches
   * the ports this machine can name a folder for, and only the ones whose
   * folder it was granted.**
   *
   * ## What changed, and why the old rule was wrong
   *
   * The old rule was *every port or none*, and a guest got none. The argument
   * for it is still true as far as it goes: a port **scan** reads the process
   * table — `lsof` here, `netstat` plus `tasklist` on Windows — and what it can
   * say is *which command holds :5173*. It cannot say which project that command
   * was started in. The process may have been launched from a parent directory,
   * may be a proxy in front of three apps, may be a database or a container's
   * published port with no project anywhere near it. Filtering *that* by folder
   * would be a guess wearing the clothes of a permission.
   *
   * What the argument missed is that the scan is not the only thing on this
   * machine that knows about a port. `dev-server.ts` **starts** dev servers, in a
   * folder it was given, and dials until one answers — so `folder` and `port` on
   * a `ready` state are two facts about the same process this app spawned, not
   * an inference drawn from a process table. There is exactly one such source
   * and {@link grantedPorts} reads it; nothing here ever attributes a scanned
   * port to a folder.
   *
   * That gap was visible as a broken feature rather than as a policy. A guest
   * granted a folder can already ask this host to **start** the dev server in it
   * (`dev.start`), is already told the port it came up on (`dev.state`), and
   * then could not open it. Asad, connected to his PC as a guest:
   *
   *   > *"Now here I cannot even open the browser. As a guest I am connected, I
   *   > cannot open a browser inside that machine. Maybe because I am connected
   *   > as a guest, but still as a guest I should be able to open a browser."*
   *
   * ## What a guest still does not get
   *
   * Everything that is not in one of its folders: an admin console, a staging
   * database's web UI, another project's dev build, this app's own loopback
   * ports. The last of those is `reserved` and is not a matter of eligibility —
   * `own-ports.ts` covers `deck-control`, which is the copilot's whole tool
   * surface, and `hidden-sessions.ts` covers the ptys behind it.
   *
   * ## Where the narrowing lives
   *
   * In the hub's `scan`, once, and not at this door. `createTunnelHub` asks
   * `scan()` both to answer `ports` and to decide whether a `tunnel.open` may be
   * dialled at all, so a scan that has already been narrowed makes the offer and
   * the dial agree by construction. Two separate checks would be two chances for
   * a list and an enforcement to disagree, which is the defect `folder-grants.ts`
   * exists because of.
   */
  function localhostAllowed(connection: LiveConnection): boolean {
    // Eligibility is no longer the question — what a guest is *shown* and what
    // it may dial is decided by {@link grantedPorts}, and an empty list is an
    // honest answer rather than a refusal. What is left is the host's own
    // ceiling: `options.offer` can leave `localhost` out, and the public demo
    // box does exactly that. Read the same way `webOpen` reads its own, so a
    // client that never saw the welcome is refused rather than served.
    if (advertised.includes(CAPABILITY.localhost)) return true
    send(connection, {
      t: 'error',
      code: 'unauthorized',
      message: `This ${machineNoun(currentPlatform())} does not open its ports to a device.`,
    })
    return false
  }

  /**
   * The ports a guest may be told about, from the only source that can name a
   * folder for one.
   *
   * Re-read on every `ports` frame and every `tunnel.open`, never cached: a
   * grant edited while a device is connected has to take effect at the next
   * question, which is the same reason `mayTouch` is asked per keystroke rather
   * than once at attach.
   *
   * Empty whenever this host cannot answer *"may this device use this folder"* —
   * no dev-server module, no per-device folder list — because the correct
   * behaviour for a host that cannot ask the question is to offer nothing, not
   * to answer it optimistically. Same rule as `devserver`'s advertisement.
   */
  async function grantedPorts(deviceId: string): Promise<readonly TunnelPort[]> {
    const servers = options.devServers
    const folders = options.sessions.folders?.(deviceId) ?? []
    if (!servers || folders.length === 0) return []
    const allowed = new Set<number>()
    for (const folder of folders) {
      let state: DevServerState
      try {
        state = servers.status(folder)
      } catch (error) {
        // `status` reads the disk. A folder that has gone away is one fewer
        // port, never a socket that stops answering.
        console.error('[remote] could not read a dev server for a guest:', error)
        continue
      }
      // `ready` only, and `port` is set only on `ready` — see `DevServerState`.
      // A `starting` has no port yet and a `failed` may be carrying one from an
      // attempt that is over.
      if (state.status === 'ready' && typeof state.port === 'number') allowed.add(state.port)
    }
    if (allowed.size === 0) return []
    // Still intersected with a live scan, so the guest is offered a port only
    // while something is really listening on it — and gets the address families
    // the dial needs, which the dev-server state does not carry.
    try {
      return (await scanPorts()).filter((entry) => allowed.has(entry.port))
    } catch (error) {
      console.error('[remote] port scan failed while answering a guest:', error)
      return []
    }
  }

  function hubFor(connection: LiveConnection, deviceId: string): TunnelHub {
    if (connection.tunnels) return connection.tunnels
    const hub = createTunnelHub({
      /*
       * One seam, two doors.
       *
       * `createTunnelHub` asks this both to answer `ports` and to decide whether
       * a `tunnel.open` may be dialled, so narrowing it here is what makes the
       * list a guest is offered and the ports it may reach the same list. A
       * second check at the door would be a list and an enforcement computed
       * separately, which is the defect `folder-grants.ts` exists because of.
       *
       * Read per call rather than resolved once, because a grant is edited while
       * a device is connected and the hub outlives the edit.
       */
      scan: () => (copilotEligible(deviceId) ? scanPorts() : grantedPorts(deviceId)),
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
      /*
       * `deviceId` is null only on a connection that has not authenticated, and
       * `deskFor` is reached only from the authenticated branch — so the null
       * arm is unreachable and is a refusal rather than a cast. A folder check
       * that fell back to "no device, therefore allow" would be the one bug in
       * this file worth having a compiler.
       */
      store: (wanted) =>
        wanted === null
          ? diskUploadStore(dir)
          : connection.deviceId === null
            ? null
            : storeForFolder(connection.deviceId, wanted),
      send: (message) => send(connection, message),
    })
    connection.uploads = desk
    return desk
  }

  /**
   * A store for a folder the sender named, or null because it may not have it.
   *
   * The whole of `upload.begin.dir`'s safety, and it is deliberately the same
   * shape as `create`'s: the answer is decided against the list **this host**
   * published to **this device**, read now rather than at hello, so an untick in
   * Settings lands on the next frame. Containment rather than equality, for the
   * reason `device-reach.ts` gives about the same asymmetry — a person who
   * shared `~/work/site` shared what is under it, and a downloads folder inside
   * a shared project is the ordinary case rather than an edge one.
   *
   * Absolute, because a relative path would be resolved against this process's
   * working directory, which is a folder nobody chose and which differs between
   * a packaged app and a `npm start`.
   */
  function storeForFolder(deviceId: string, wanted: string): UploadStore | null {
    if (!isAbsoluteFolder(wanted)) return null
    if (options.unrestrictedFolders?.(deviceId) === true) return diskUploadStore(wanted)
    const offered = options.sessions.folders?.(deviceId) ?? []
    if (!offered.some((folder) => withinFolder(folder, wanted))) return null
    return diskUploadStore(wanted)
  }

  function detachAll(connection: LiveConnection): void {
    connection.tunnels?.closeAll()
    connection.tunnels = null
    /*
     * The watcher goes; the run stays.
     *
     * That asymmetry is the design and it is worth stating where the teardown
     * is, because everything else in this function is symmetric. A socket
     * dropping is a phone going into a pocket, a lift, a tunnel — not a person
     * asking for their agent to be killed mid-turn. The run has its own grace
     * window and stops itself when that expires; see `copilot-runs.ts`.
     */
    unwatchCopilot(connection)
    /*
     * The copilot *connection* goes with the socket, and the confirmations go
     * with it.
     *
     * Not the same asymmetry as the run above, and the difference is the point.
     * A run is work in progress and survives a lift; a confirmation is a
     * question somebody is looking at, and nobody is looking at it any more.
     * `COPILOT-REMOTE.md` §4 settles that a device that disconnects mid-prompt
     * defaults to refusal — the same direction `caller-gone` already fails in
     * one transport further in.
     */
    closeCopilotConnection(connection)
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

  /**
   * The sessions one device is allowed to know about.
   *
   * Every frame that carries a session list goes through here — the welcome, the
   * answer to `list`, and the refresh everyone else gets when somebody starts
   * one. Three call sites and one filter, because a list assembled in three
   * places is three chances to send one unfiltered, and the one that gets missed
   * is always the one nobody is looking at.
   *
   * A host with no per-device rule has no `visible` and the list is unchanged.
   */
  function sessionsFor(deviceId: string): RemoteSession[] {
    const all = options.sessions.list()
    const may = options.sessions.visible
    if (!may) return all
    return all.filter((session) => may.call(options.sessions, deviceId, session.id))
  }

  /**
   * May this device touch this session? True when the host has no such rule.
   *
   * Written once rather than inlined at each of the three verbs, so that the
   * `!may` default cannot be spelled one way in `attach` and the other way in
   * `input` — which is the shape of every "enforced in one place" bug in this
   * subsystem's history.
   */
  function mayTouch(deviceId: string, sessionId: string): boolean {
    const may = options.sessions.visible
    return may ? may.call(options.sessions, deviceId, sessionId) === true : true
  }

  function attach(connection: LiveConnection, message: Extract<ClientMessage, { t: 'attach' }>): void {
    const id = message.id
    /*
     * The device's own reach, before anything is subscribed.
     *
     * The refusal is deliberately the same sentence an unknown id gets, and the
     * reason is the one `SessionFanout.attach` gives about hidden sessions: a
     * distinct message would confirm that the id names something real, and these
     * ids are guessable from an alert, a transcript path or an older list. A
     * device that was never meant to see it is told the truth it is entitled to
     * — there is no such session, as far as this connection is concerned.
     */
    if (connection.deviceId && !mayTouch(connection.deviceId, id)) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${id} is running.` })
      return
    }
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

  /**
   * Sign a device in with an account this machine already trusts.
   *
   * The other pre-auth door beside {@link hello}, and it authenticates nothing on
   * this socket: it mints a pre-approved device over the sealed channel and
   * answers `enrolled`, after which the client says `hello` with the credential
   * on this same socket, through the ordinary door. `connection.deviceId`
   * therefore stays null here — a signed-in connection is an unauthenticated one
   * until its hello lands.
   *
   * The order of the three refusals is the security of this function:
   *
   *  - **No sign-in served here** → `unavailable`. The demo box and a build with
   *    it switched off both land here, and the sentence names the pairing-code
   *    remedy rather than leaving a phone to guess.
   *  - **No sealed channel** → `unauthorized`, *and the SSH probe is never run*.
   *    A connection with no handshake key cannot be bound to the device it would
   *    mint, and running the loopback probe for one would let anything that can
   *    open a plain socket point this host at its own sshd as a brute-force
   *    amplifier. Refused before {@link EnrollAccess.signIn} is even called.
   *  - Everything else is {@link EnrollAccess.signIn}'s to decide, and its
   *    refusals are already collapsed and rate-limited.
   */
  async function enrol(connection: LiveConnection, message: Extract<ClientMessage, { t: 'enroll' }>): Promise<void> {
    if (message.protocol !== PROTOCOL_VERSION) {
      refuse(
        connection,
        'version',
        `This phone app speaks protocol ${message.protocol}; the desktop speaks ${PROTOCOL_VERSION}. Update whichever is older.`,
        CLOSE.policyViolation,
      )
      return
    }

    const enroll = options.enroll
    if (!enroll) {
      refuse(
        connection,
        'unavailable',
        'Sign-in is not available on this machine. Pair it with a code instead.',
        CLOSE.policyViolation,
      )
      return
    }

    // Sealed channel only, and the probe is not reached without it — see the
    // header. Refused in the same words as any other rejection, so which door it
    // failed at is not a remote caller's business.
    const peerPublicKey = connection.peerPublicKey
    if (!peerPublicKey) {
      refuse(
        connection,
        'unauthorized',
        'This device is not allowed in. Pair it again from the desktop app.',
        CLOSE.policyViolation,
      )
      return
    }

    // The no-hello timer is re-armed around the probe and the mint: the socket is
    // unauthenticated throughout, the work outlasts a hello's scrypt, and the
    // fresh window also covers the `hello` the client sends the instant it has
    // the credential. Same shape the timer is first armed with in attachTransport.
    if (connection.helloTimer) clearTimeout(connection.helloTimer)
    connection.helloTimer = setTimeout(() => {
      if (connection.deviceId) return
      connection.wire.close(CLOSE.policyViolation, 'no hello')
    }, helloTimeoutMs)
    connection.helloTimer.unref?.()

    const outcome = await enroll.signIn({
      username: message.username,
      secret: message.secret,
      method: message.method,
      deviceName: message.device.name,
      address: connection.address,
      peerPublicKey,
    })
    // The socket can be gone by now: the probe takes real time and the timer kept
    // running through it.
    if (!live.has(connection.id)) return
    if (!outcome.ok) {
      refuse(connection, outcome.code, outcome.message, CLOSE.policyViolation)
      return
    }

    send(connection, {
      t: 'enrolled',
      deviceId: outcome.deviceId,
      deviceName: outcome.deviceName,
      credential: outcome.credential,
    })
    // Not authenticated here, deliberately. The client stores the credential and
    // says hello with it on this same socket; that hello is the door, and the
    // re-armed timer above is the window it has to arrive in.
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
      sessions: sessionsFor(outcome.deviceId),
      capabilities: capabilitiesFor(outcome.deviceId),
      hostPlatform: currentPlatform(),
      // The same name a pairing offer carries, from the same function, on the
      // one frame that arrives on *every* connection. A client that only ever
      // learned this at pairing time has no name for a machine paired before
      // the field existed — see `welcome.hostName`.
      hostName: describeThisMachine().name,
      // Spread rather than sent as `undefined`, so a host that cannot start
      // sessions sends no key at all — the same shape a desktop from before this
      // field sends, which is what an older client is already correct about.
      ...foldersFrame(outcome.deviceId),
      // Same rule, same reason. A desktop with no copilot sends no key; one with
      // a copilot sends the object even when nothing is granted, because "this
      // device is not connected to the copilot" is a state with a remedy and a
      // client should be able to say so rather than hiding the tab as though the
      // feature did not exist.
      //
      // `open` is false here on every welcome, always. Connecting is a frame the
      // client sends, not a property of having said hello — see
      // `LiveConnection.copilotOpen`.
      ...copilotFrame(outcome.deviceId, false),
    })
    /*
     * And which of that device's sessions has a browser window here.
     *
     * On the welcome, for the reason the guest link announces its own holds
     * there: this socket is new after every reconnect and the far end's table
     * went with the old one. Nothing over there can be relied on to notice a
     * reconnection, so the fact is re-stated by the end that holds it, every
     * time, before anybody can ask.
     *
     * After the welcome rather than folded into it, because it is gated on
     * something the welcome itself carries: the capability list this connection
     * sent, which decides whether the frame may be sent at all.
     */
    tellWindowHolds(connection)
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
   * This device's copilot grant, in the shape a `welcome` spreads.
   *
   * Absent when this host has no copilot at all, which is the same thing its
   * missing `copilot` capability already says. Present and all-false is the
   * ordinary case and is *not* the same fact: it means this desktop has a
   * copilot and this device has not been given access to it, which is a state
   * with a remedy — a switch, on the desktop, in Settings.
   */
  function copilotFrame(deviceId: string, open: boolean): { copilot?: CopilotLinkWire } {
    const copilot = options.copilot
    // A guest is sent no key at all, which is the same shape a host with no
    // copilot sends — deliberately, because those are the same fact from the
    // device's point of view and it is entitled to neither more nor less.
    if (!copilot || !copilotEligible(deviceId)) return {}
    return { copilot: copilotLink(copilot, deviceId, open) }
  }

  /**
   * This device's copilot connection, as the wire describes it.
   *
   * Three facts and not one, because a client has three screens to draw:
   * *nothing here, ask for a code*, *you have a credential, send it*, and *you
   * are in, here is what you may do*. Folding them together is how a phone ends
   * up showing a Connect button to a device that is already connected, or a
   * Copilot tab to one that has never been.
   */
  function copilotLink(copilot: CopilotRemote, deviceId: string, open: boolean): CopilotLinkWire {
    return { linked: copilot.linked(deviceId), open, grant: copilot.granted(deviceId) }
  }

  /**
   * Close this socket's copilot connection, and withdraw what it was holding.
   *
   * Called on `copilot.bye`, on the socket dropping, and on a disconnect from
   * the settings panel. The credential and the record survive all three — this
   * is the *connection* ending, not the authorisation — so the next
   * `copilot.hello` works.
   *
   * The confirmations do not survive, and only when this was the device's **last**
   * open connection. A phone with the app open in two places has not stopped
   * watching because one of them closed, and refusing its question on the first
   * close would be the app deciding on its behalf. When the last one goes,
   * `CopilotRemote.closed` refuses everything that device raised, with
   * `caller-gone`.
   */
  function closeCopilotConnection(connection: LiveConnection): void {
    if (!connection.copilotOpen) return
    connection.copilotOpen = false
    const deviceId = connection.deviceId
    if (deviceId === null) return
    for (const other of live.values()) {
      if (other.id !== connection.id && other.deviceId === deviceId && other.copilotOpen) return
    }
    try {
      options.copilot?.closed(deviceId)
    } catch (error) {
      console.error('[remote] could not close a copilot connection:', error)
    }
  }

  /**
   * Everything a copilot verb needs, or a refusal already sent.
   *
   * One function rather than the three checks written out at each of the ten
   * verbs, because it is the same three checks every time and the failure mode
   * of writing them ten times is that the tenth one is missing the middle check.
   *
   * The order is: does this host have a copilot at all, is this device holding
   * the tier this verb needs, and only then the verb. The grant is read **here**,
   * on every message, never at hello — which is what makes an untick in Settings
   * land on the next frame rather than on the next reconnect, and it is the same
   * property `folders()` has for `create`.
   */
  function copilotFor(
    connection: LiveConnection,
    deviceId: string,
    verb: string,
  ): CopilotRemote | null {
    const copilot = options.copilot
    if (!copilot) {
      // A client sending a verb this host never advertised is not a client of
      // ours — the same refusal `create`, the uploads and the dev servers give.
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'There is no copilot to reach on this machine.',
      })
      return null
    }
    /*
     * The copilot connection has to be open on **this socket**, before any tier
     * is consulted.
     *
     * This is the layer that did not exist while copilot access was a box ticked
     * beside a paired phone, and it is what makes the rest honest. A device that
     * has been paired for terminals and never connected to the copilot gets this
     * refusal for every verb including the read-tier ones, so there is no frame
     * it can send that measures anything about the copilot at all — not whether
     * one is running, not how many confirmations are waiting, not whether the
     * grant it does not have would have been enough.
     *
     * Checked before the tier deliberately. The tier check reads a store keyed
     * by device; this reads a fact about the socket, and answering "you do not
     * have enough access" to a device that has no connection would be describing
     * a grant it cannot use as though it were the obstacle.
     */
    if (!connection.copilotOpen) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message:
          'This device is not connected to the copilot. ' +
          `Connect it on the ${machineNoun(currentPlatform())} itself, in Settings → Remote.`,
      })
      return null
    }
    /*
     * And the kind, on every verb, after the connection and before the tier.
     *
     * Unreachable today by construction — a guest cannot open a copilot
     * connection, and a device's kind cannot change without it being revoked and
     * re-paired under a new id. It is here anyway, and the reason is the one this
     * file gives about `SessionFanout.write`: this is the single gate in front of
     * ten verbs, and a rule that holds only because of what a *different*
     * function refuses is a rule the eleventh verb does not have.
     */
    if (!copilotEligible(deviceId)) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'The copilot is not shared with guest devices.',
      })
      return null
    }
    if (!copilotFrameAllowed(copilot.granted(deviceId), verb)) {
      /*
       * `unauthorized`, and the sentence names the remedy rather than the tier.
       *
       * "You need `act`" is a word from this codebase's permission model that
       * means nothing on a phone. What a person can act on is that the switch is
       * on their Mac, in Settings, next to the folders — which is also the only
       * place it can be changed, deliberately: a grant that could be requested
       * from the device it is about is a grant the device holds.
       */
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message:
          'This device has not been given that much access to the copilot. ' +
          `Change it on the ${machineNoun(currentPlatform())} itself, in Settings → Remote.`,
      })
      return null
    }
    return copilot
  }

  /**
   * Where one connection's copilot frames go.
   *
   * Built per connection rather than per device, because two sockets from the
   * same device — the app and a second window, a phone and the same phone
   * reconnecting before the first socket has been reaped — are two places the
   * same conversation has to appear.
   */
  function copilotSink(connection: LiveConnection): CopilotSink {
    return {
      state: (state) => send(connection, { t: 'copilot.state', state }),
      chat: (run, messages, reset) =>
        send(connection, { t: 'copilot.chat', run, messages, ...(reset ? { reset: true } : {}) }),
      tool: (row) => send(connection, { t: 'copilot.tool', row }),
      sessions: (sessions) => send(connection, { t: 'copilot.sessions', sessions }),
      pending: (questions) => send(connection, { t: 'copilot.pending', questions }),
      /*
       * A question to decide, and one to merely know about, are two frames.
       *
       * `ask` carries the arguments verbatim and reaches only the surface that
       * raised the question; `pending` carries none and reaches every watcher.
       * The split is `copilot-consent.ts`'s and the reason is there: a prompt
       * without enough context becomes a reflex Yes, and a device that cannot
       * answer has no decision to make with somebody's settings patch.
       */
      ask: (question) => send(connection, { t: 'copilot.ask', question }),
      settled: (settled) => send(connection, { t: 'copilot.settled', settled }),
    }
  }

  /** Drop this connection's copilot subscription, if it has one. */
  function unwatchCopilot(connection: LiveConnection): void {
    const stop = connection.copilot
    connection.copilot = null
    if (!stop) return
    try {
      stop()
    } catch (error) {
      console.error('[remote] could not drop a copilot watcher:', error)
    }
  }

  /**
   * Serve the three frames that establish a copilot connection.
   *
   * Separate from {@link copilotServe} because these run *before* there is any
   * access to serve. Folding them in would mean the function that assumes an
   * open connection also contains the code that opens one, which is exactly the
   * shape in which somebody eventually moves a check to the wrong side of it.
   *
   * All three answer with `copilot.grant`, so a client has one frame to react to
   * and one shape to read whatever it just did. `copilot.connect` sends
   * `copilot.linked` first, because that carries the credential and it is the
   * only time it will ever be sent.
   */
  async function copilotConnectServe(
    connection: LiveConnection,
    copilot: CopilotRemote,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'copilot.connect' | 'copilot.hello' | 'copilot.bye' }>,
  ): Promise<void> {
    /*
     * A guest is refused before the code is even looked at.
     *
     * The capability was never advertised and the welcome carried no copilot
     * key, so no client of ours sends this — which is exactly why the refusal
     * has to exist anyway. The advertisement is what a *client* respects; this
     * is what the machine does. `copilot.bye` is exempt because closing
     * something you do not have is a no-op that costs nothing to serve, and
     * refusing it would be a way to ask this question.
     *
     * The sentence names the remedy, and the remedy is re-pairing rather than a
     * setting, because there is no setting: a device's kind is fixed when it is
     * approved. See `device-kind.ts` for why there is no toggle.
     */
    if (message.t !== 'copilot.bye' && !copilotEligible(deviceId)) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'The copilot is not shared with guest devices. Pair this device again as your own to use it.',
      })
      return
    }
    switch (message.t) {
      case 'copilot.hello': {
        /*
         * No credential, and no `copilot.connect` above this any more.
         *
         * Both were deleted on 2026-08-19. The socket is already authenticated
         * as this device by `RemoteAuth` and a person at this keyboard already
         * decided, when they approved it, whether it is one of their own — and
         * that decision cannot be changed without pairing again. A second
         * six-digit code on top proved the same fact twice.
         * `copilot-access.ts` carries the argument and preserves the one it
         * superseded.
         *
         * The eligibility check a few lines above this switch is what gates it,
         * and it is unchanged: a guest never reaches here at all.
         */
        const outcome = await copilot.open(deviceId)
        if (!live.has(connection.id)) return
        if (!outcome.ok) {
          // Cleared on failure as well as left unset, so a socket that opened,
          // had its device revoked on the desktop, and then said hello again
          // does not keep the access its first hello bought.
          closeCopilotConnection(connection)
          send(connection, { t: 'error', code: outcome.code, message: outcome.message })
          return
        }
        connection.copilotOpen = true
        send(connection, { t: 'copilot.grant', link: copilotLink(copilot, deviceId, true) })
        return
      }
      case 'copilot.bye': {
        closeCopilotConnection(connection)
        // The watcher goes too. Leaving it would push chat and tool rows down a
        // socket that has just said it is done with the copilot — a subscription
        // outliving the access that justified it.
        unwatchCopilot(connection)
        send(connection, { t: 'copilot.grant', link: copilotLink(copilot, deviceId, false) })
        return
      }
    }
  }

  /**
   * Serve one `copilot.*` frame, after {@link copilotFor} has allowed it.
   *
   * Not awaited by the caller, for the same reason `create` is not: the message
   * loop is the socket's data handler and starting a run spawns an agent
   * process. A rejection is impossible by contract and caught anyway.
   */
  async function copilotServe(
    connection: LiveConnection,
    copilot: CopilotRemote,
    deviceId: string,
    message: Extract<ClientMessage, { t: `copilot.${string}` }>,
  ): Promise<void> {
    switch (message.t) {
      case 'copilot.attach': {
        // Re-attaching is how a phone asks for its context again after a
        // reconnect, so it is not an error — the old subscription goes and a
        // fresh one is made, exactly as `attach` does for a session.
        unwatchCopilot(connection)
        connection.copilot = copilot.watch(deviceId, copilotSink(connection))
        send(connection, { t: 'copilot.state', state: copilot.state(deviceId) })
        return
      }
      case 'copilot.detach':
        unwatchCopilot(connection)
        return
      case 'copilot.state':
        send(connection, { t: 'copilot.state', state: copilot.state(deviceId) })
        return
      case 'copilot.sessions':
        send(connection, { t: 'copilot.sessions', sessions: copilot.sessions() })
        return
      case 'copilot.pending':
        send(connection, { t: 'copilot.pending', questions: copilot.pending(deviceId) })
        return
      case 'copilot.answer': {
        /*
         * Three checks have already happened and none of them is repeated here.
         *
         * The socket has an open copilot connection (`copilotFor`), the device
         * holds `alter` (`COPILOT_FRAME_TIER`, against the store, on this
         * message), and the question is one this device may answer — which is
         * the one check that is *not* here, because it belongs to the question
         * rather than to the socket and lives in `ConsentBroker.respond`. A copy
         * of it in this transport would be a copy the next transport does not
         * have.
         *
         * `accepted: false` covers a question that has already been settled and
         * one this device does not own, and the two are deliberately the same
         * answer: a device probing for another device's question ids must learn
         * nothing here that its own pending list did not already tell it.
         */
        const accepted = copilot.answer(deviceId, message.id, message.approved)
        if (!accepted) {
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That confirmation is no longer waiting for this device.',
          })
        }
        // The list either way, answered or not: a client whose answer was too
        // late has to see the question go rather than be left holding a dialog.
        send(connection, { t: 'copilot.pending', questions: copilot.pending(deviceId) })
        return
      }
      case 'copilot.log': {
        const { rows, more } = copilot.log({
          limit: message.limit ?? MAX_COPILOT_LOG_ROWS,
          ...(message.before === undefined ? {} : { before: message.before }),
        })
        send(connection, { t: 'copilot.log', rows, more })
        return
      }
      case 'copilot.start': {
        const outcome = await copilot.start(deviceId)
        // The phone can be gone by now: starting resolves a login shell's PATH,
        // probes for the CLI and spawns a process. The run is real either way —
        // that is the honest outcome of "start something" — and it will be found
        // by the reconnect inside the grace window.
        if (!live.has(connection.id)) return
        if (!outcome.ok) {
          send(connection, { t: 'error', code: outcome.code, message: outcome.message })
          return
        }
        send(connection, { t: 'copilot.state', state: copilot.state(deviceId) })
        return
      }
      case 'copilot.say': {
        const outcome = await copilot.say(deviceId, message.text)
        if (!live.has(connection.id)) return
        if (!outcome.ok) send(connection, { t: 'error', code: outcome.code, message: outcome.message })
        return
      }
      case 'copilot.cancel':
      case 'copilot.stop': {
        const outcome = message.t === 'copilot.cancel' ? copilot.cancel(deviceId) : copilot.stop(deviceId)
        if (!outcome.ok) {
          send(connection, { t: 'error', code: outcome.code, message: outcome.message })
          return
        }
        send(connection, { t: 'copilot.state', state: copilot.state(deviceId) })
        return
      }
    }
  }

  /**
   * Tell one device its copilot grant changed, and take away what it no longer
   * has.
   *
   * **Nothing in the product calls this today, and that is worth stating rather
   * than hiding.** It was reached from the settings panel through
   * `remote:copilot:set` and from a disconnect, and both went on 2026-08-19 with
   * the separate connection. What can change a device's answer now is its
   * *kind*, which `device-kind.ts` writes once and never overwrites, so the only
   * route from "reaches the copilot" to "does not" is revoking the device — and
   * `dropDevice` already does the whole job there: it calls
   * `CopilotRemote.revoked`, drops the MCP token, stops the run and closes every
   * socket, so the device learns by disconnection rather than by a frame.
   *
   * It is kept rather than deleted for one reason, and only one: the phone
   * clients read a `copilot.grant` carrying `linked: false` as *the copilot has
   * been taken away*, without needing a reconnect. That is the correct client
   * behaviour and it should stay correct; this is the only thing on this side
   * that could ever produce that frame. If a future change makes a kind
   * revocable in place, this is what it calls — and if that never happens, this
   * comment is the thing that stops somebody reading its silence as a bug.
   *
   * Two halves, and only the second is about the wire:
   *
   *  - `CopilotRemote.revoked` drops the device's MCP token — so a tool call in
   *    flight on it aborts with `caller-gone` — and stops its run. That is what
   *    stops a phone whose access was just taken away from continuing to drive
   *    an agent it can no longer be granted.
   *  - The push, and the unsubscribe, are what stop it *watching* a conversation
   *    it can no longer influence.
   *
   * The *rule* is already live without any of this, because the grant is read
   * per message and per tool call. This is what makes the screen agree with the
   * rule, which is why a device with no live connection is not an error and
   * simply counts zero.
   */
  function tellCopilotGrant(deviceId: string): number {
    const copilot = options.copilot
    if (!copilot) return 0
    const grant = copilot.granted(deviceId)
    // Losing `read` is losing the watch, and losing `act` is losing the run.
    // Asked of the store rather than of the caller, so that "the panel said so"
    // and "the disk says so" cannot come apart.
    if (!grant.act) copilot.revoked(deviceId)
    /*
     * A device that is no longer connected loses the connection on every socket.
     *
     * `linked` is false the instant the panel disconnects it, and every
     * `copilot.*` frame is refused from that moment because `copilotFor` reads
     * the store per message. Clearing the flag as well is what makes the refusal
     * say *this device is not connected to the copilot* rather than *you do not
     * have enough access* — two different sentences with two different remedies,
     * and the second one would send somebody looking for a checkbox that is no
     * longer the obstacle.
     */
    const stillLinked = copilot.linked(deviceId)
    let told = 0
    for (const connection of live.values()) {
      if (connection.deviceId !== deviceId) continue
      if (!stillLinked) closeCopilotConnection(connection)
      if (!grant.read || !stillLinked) unwatchCopilot(connection)
      send(connection, {
        t: 'copilot.grant',
        link: copilotLink(copilot, deviceId, connection.copilotOpen),
      })
      told += 1
    }
    return told
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
      /*
       * The session list goes with it, and that is not a bonus refresh.
       *
       * Folders now decide which *running* sessions a device may see, so taking
       * one back has to take the rows off its screen in the same breath as it
       * takes the folder off its picker. Sent before the folders so that a
       * client redrawing on either frame never has a moment where it is showing
       * a session it may no longer touch.
       *
       * Unconditional, unlike the folder frame below: a host with no per-device
       * rule sends the same list it always did, which is a harmless refresh.
       */
      send(connection, { t: 'sessions', sessions: sessionsFor(deviceId) })
      if (frame.folders === undefined) continue
      send(connection, { t: 'folders', folders: frame.folders })
      told += 1
    }
    return told
  }

  /**
   * Tell every device the session list changed, without waiting for it to ask.
   *
   * The counterpart of the loops inside `create` and `close`, and the same
   * frame: `sessions` is v1, so a client that has never heard of any capability
   * still redraws from it. What is new is the trigger — this one fires for a
   * session started or ended at *this* machine's keyboard, which the wire had no
   * way to hear about at all. See {@link RemoteEndpoint.sessionsChanged}.
   *
   * A connection that has not said hello is skipped rather than sent an empty
   * list: `sessionsFor` is keyed on the device, and there is no device yet.
   */
  function tellSessions(): number {
    let told = 0
    for (const connection of live.values()) {
      if (!connection.deviceId) continue
      send(connection, { t: 'sessions', sessions: sessionsFor(connection.deviceId) })
      told += 1
    }
    return told
  }

  /**
   * Tell one connection which of its own sessions this app is holding a browser
   * window for.
   *
   * The mirror of the `window.holds` a *client* sends, and it is a frame this end
   * sends **hopefully to nobody**: it goes only to a connection that named
   * `hostWindows` in its hello, because a client from before this direction
   * existed answers a frame it has never parsed by closing the channel — the
   * failure `MachineLink.announceWindows` guards the other way round, and the one
   * that turns a new fact into a machine falling off the network.
   *
   * The whole set every time, empty included. That is how a *detach* travels, and
   * it is why nothing here has to remember what it last said: a link that dropped
   * and came back is correct by arriving. See `WindowHoldsFrame`.
   */
  function tellWindowHolds(connection: LiveConnection): void {
    const held = options.windowsHeldFor
    if (held === undefined) return
    if (!connection.deviceId) return
    if (!connection.capabilities.includes(CAPABILITY.hostWindows)) return
    send(connection, { t: 'window.holds', sessions: [...held(connection.deviceId)] })
  }

  /**
   * A browser window here was attached to, or detached from, a session on some
   * device. Say so to every connection that can hear it.
   *
   * Every connection rather than the one that changed, and it costs one small
   * frame each: the caller is a subscription to the whole binding map, which
   * reports *that* the relation moved rather than which device it moved for.
   * Working this out here would mean the server keeping a second copy of a map
   * it does not own — which is the thing `machines/ipc.ts` refuses to do for
   * exactly the same frame going the other way.
   */
  function tellWindowsHeld(): number {
    if (options.windowsHeldFor === undefined) return 0
    let told = 0
    for (const connection of live.values()) {
      if (!connection.deviceId) continue
      if (!connection.capabilities.includes(CAPABILITY.hostWindows)) continue
      tellWindowHolds(connection)
      told += 1
    }
    return told
  }

  /**
   * Open a page on **this** machine because a device asked.
   *
   * ## What it is for
   *
   * A browser tab cannot listen on a socket, so the web client can tell somebody
   * which ports are open and cannot serve through one. His complaint about that
   * screen is exact — *"localhost lists ports with no way to open any of them;
   * the whole reason localhost exists is to drive them"* — and the answer is the
   * one he gave for the phone in the same review: the page opens **here**, on
   * the machine, in a tab of its own browser. The device is driving rather than
   * viewing, which is a smaller promise than a tunnel and one this transport can
   * actually keep.
   *
   * ## Three gates, and each closes something different
   *
   * **The capability**, first: a host with nowhere to put a page — the headless
   * daemon, the demo box — never advertises `web`, so a verb arriving at one is
   * a client that is not ours and is refused rather than served.
   *
   * **The kind**, second. This opens a window on somebody's screen, and no
   * folder grant says anything about that: a guest is granted *folders*, and a
   * page appearing on the owner's desktop is not in a folder. So it is `mine`
   * only, the same rule and the same sentence as the copilot's.
   *
   * **The scheme**, last, and it is `isNavigationAllowed` — the predicate behind
   * `routeGuestLink`, which is the rule for an *untrusted page* and not the one
   * for the app's own links. The difference matters: `routeAppLink` hands a
   * `file:` to Launch Services, because code we wrote asking to reveal a file
   * means it, and a URL that arrived over a socket is not code we wrote. So
   * http(s) opens in a tab and everything else — `file:`, `javascript:`, a
   * custom scheme somebody registered — is refused. A URL off a network gets the
   * strictest answer this app has, not a new one.
   *
   * The confirmation carries what was opened rather than what was asked for, and
   * nothing is sent at all when the open did not happen — a client that drew
   * "opened" over a press that did nothing is the failure this whole review is
   * about.
   */
  function webOpen(connection: LiveConnection, deviceId: string, url: string): void {
    const open = options.openUrl
    if (!open || !advertised.includes(CAPABILITY.web)) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: `This ${machineNoun(currentPlatform())} cannot open pages for a device.`,
      })
      return
    }
    if (!copilotEligible(deviceId)) {
      // The same eligibility question the copilot asks, deliberately: both are
      // "may this device drive the machine itself", as against "which folders
      // may it reach". One rule, one answer, so a device cannot be a guest for
      // one and an owner for the other.
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'Only your own devices can open pages on this machine.',
      })
      return
    }
    // `about:blank` passes `isNavigationAllowed` because that is what an empty
    // view holds, and a device asking to open it is asking for nothing — so it
    // is excluded here rather than in the shared predicate, where it is correct.
    if (url === BLANK_URL || !isNavigationAllowed(url)) {
      // The URL is not echoed back. It came off the network and this sentence is
      // both sent over the wire and drawn on a screen; quoting attacker-chosen
      // text into it buys nothing and costs an output channel — the same rule
      // the folder refusal follows.
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'That is not a web address this machine will open.',
      })
      return
    }
    let opened = false
    try {
      opened = open(url)
    } catch (error) {
      console.error('[remote] could not open a page for a device:', error)
    }
    if (!opened) {
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: 'The page did not open. There may be no window to open it in.',
      })
      return
    }
    send(connection, { t: 'web.opened', url })
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
   * Serve one `controls.read` or `controls.apply`.
   *
   * ## Two doors, and the second one is the one that matters
   *
   * The capability decides whether this host speaks these frames at all;
   * {@link mayTouch} decides whether *this device* may ask about *this session*,
   * and it is asked here for the same reason it is asked on every `input`
   * keystroke. A handle is proof of an attach that was allowed then, and folders
   * are edited from the settings panel while a device is connected — so a
   * connection that took a handle before a folder was removed must not keep a
   * way to type `/model` into an agent running in it.
   *
   * `controls.apply` genuinely is typing: the far side of it writes characters
   * and a return into a pty. So it is authorised exactly as `input` is, with the
   * same sentence, and a device that may not type into a session may not reach
   * this either. `controls.read` is authorised the same way and could argue for
   * something weaker — it only looks — but "what is on that session's screen" is
   * not a smaller question than "may I type at it", and two rules would be one
   * more thing to keep in step.
   *
   * ## An unknown session is answered, not ignored
   *
   * Every path here ends in a frame. The asking side holds a promise per `rid`
   * and a request that is silently dropped is a menu that spins until its own
   * timeout, which reads as the feature being broken rather than as a refusal.
   * The one thing that is *not* sent is a reading for a session this device may
   * not see: that is a plain `error` with `unknown-session`, deliberately the
   * same sentence an unauthorised `attach` gets, because a distinct one would
   * confirm the id names something real.
   */
  async function controlsServe(
    connection: LiveConnection,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'controls.read' | 'controls.apply' }>,
  ): Promise<void> {
    const controls = options.sessions.controls
    if (!controls || !advertised.includes(CAPABILITY.controls)) {
      // Refused here as well as withheld from the advertisement, and the
      // difference is the whole of it: `capabilitiesFor` decides what a client
      // of ours draws, and this decides what *any* client gets. A build older
      // than the rule, or one somebody wrote themselves, sends the frame without
      // having read the welcome.
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: `This ${machineNoun(currentPlatform())} cannot read a session’s model or effort.`,
      })
      return
    }
    if (!mayTouch(deviceId, message.id)) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${message.id} is running.` })
      return
    }

    if (message.t === 'controls.read') {
      const reading = await controls.read(message.id)
      // The device can be gone by now: a read waits for a terminal emulator to
      // finish parsing, which is milliseconds but is not nothing.
      if (!live.has(connection.id)) return
      send(connection, { t: 'controls.reading', rid: message.rid, id: message.id, reading })
      return
    }

    const answer = await controls.apply(message.id, message.control, message.value)
    if (!live.has(connection.id)) return
    send(connection, {
      t: 'controls.applied',
      rid: message.rid,
      id: message.id,
      ok: answer.ok,
      // Passed through as written. This is the CLI's own words about a refusal
      // — "Fast mode requires usage credits", "Mythos 5 isn’t available for your
      // account yet" — and the far end has no way to write a better sentence
      // about a machine it is not on.
      message: answer.message,
      reading: answer.reading,
    })
  }

  /**
   * Serve one `account.read` or `account.switch`.
   *
   * ## The same two doors as `controlsServe`, and the second one matters more
   *
   * The capability decides whether this host speaks the frame at all;
   * {@link mayTouch} decides whether *this device* may ask about *this session*.
   * It is deliberately the same door `input` goes through and not a weaker one:
   * `account.switch` ends a running agent on this machine and starts another,
   * which is strictly more than typing at it, and a device that may not type at
   * a session must certainly not be able to replace it.
   *
   * The refusal for an unauthorised session is `unknown-session`, the same
   * sentence an unauthorised `attach` gets, because a distinct one would confirm
   * that the id names something real.
   */
  async function accountServe(
    connection: LiveConnection,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'account.read' | 'account.switch' }>,
  ): Promise<void> {
    const account = options.sessions.account
    if (!account || !advertised.includes(CAPABILITY.account) || !anyAccountFor(deviceId)) {
      /*
       * Refused here as well as withheld from the advertisement, for the reason
       * `controlsServe` gives: the advertisement decides what a client of ours
       * draws, and this decides what *any* client gets.
       *
       * The third condition is the account grant, and it is the same refusal
       * rather than its own: a device granted none of this machine's logins is
       * in exactly the position of one talking to a host that has no account
       * store — there is nothing here for it — and a distinct sentence would be
       * this machine explaining its owner's choices to somebody who was not
       * given them.
       */
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: `This ${machineNoun(currentPlatform())} cannot change a session’s account from here.`,
      })
      return
    }
    if (!mayTouch(deviceId, message.id)) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${message.id} is running.` })
      return
    }

    if (message.t === 'account.read') {
      const state = await account.read(message.id)
      // The device can be gone by now: this reads a state file and a spawn
      // record, which is milliseconds but is not nothing.
      if (!live.has(connection.id)) return
      send(connection, {
        t: 'account.state',
        rid: message.rid,
        id: message.id,
        /*
         * `current` is *not* filtered, and the asymmetry is deliberate.
         *
         * The list is a fact about this **machine** — what logins it has — and
         * that is the thing an owner shares or withholds. `current` is a fact
         * about a **session** this device has already been given: it may attach
         * to that terminal and read the CLI printing the very same address three
         * lines into its banner. Withholding it there would put "No login" on a
         * chip over a session that plainly has one, which is the untruth this
         * whole area exists to remove — and it would hide nothing.
         */
        current: state.current,
        accounts: state.accounts.filter((row) => accountShared(deviceId, row.id)),
      })
      return
    }

    if (!accountShared(deviceId, message.accountId)) {
      /*
       * The one refusal on this path that is not the far machine's own words,
       * and it says what is true without naming what was withheld: the account
       * may not even be in the list this device was sent, and a sentence like
       * "that login is not shared with you" would confirm the id names something
       * real here.
       */
      send(connection, {
        t: 'account.switched',
        rid: message.rid,
        id: message.id,
        ok: false,
        message: 'That login is not one this machine offers here.',
        session: message.id,
      })
      return
    }

    const answer = await account.switch(message.id, message.accountId)
    if (!live.has(connection.id)) return
    send(connection, {
      t: 'account.switched',
      rid: message.rid,
      id: message.id,
      ok: answer.ok,
      // Passed through as written, for the reason `controls.applied`'s is: this
      // is this machine's own sentence about its own account — "that account has
      // never signed in", the CLI's own start failure — and the asking machine
      // has no way to write a better one about a computer it is not on.
      message: answer.message,
      session: answer.session,
    })
  }

  /**
   * Serve one `chat.read`.
   *
   * The same two doors as everything above it: the capability decides whether
   * this host speaks the frame at all, and {@link mayTouch} decides whether
   * *this device* may ask about *this session* — the same reach every keystroke
   * goes through, and deliberately not a weaker one. "What was said in that
   * session" is not a smaller question than "may I type at it"; it is a larger
   * one, and a chat view is the surface on which reading somebody else's
   * conversation would be easiest to do by accident.
   *
   * Clipped to {@link MAX_CHAT_ROWS} here as well as on the way in, keeping the
   * **end**: a conversation is read from the bottom, and a client that asked for
   * the whole of a thousand-turn session must not make this machine serialise it
   * onto a relay. The client's own parser clips too, and both are deliberate —
   * this one bounds what leaves the machine, that one bounds what a hostile
   * frame can make a phone hold.
   */
  /**
   * Serve one `logins.read` or `logins.signin`.
   *
   * ## A different door from `accountServe`, and that is the point of the file
   *
   * The verbs next door carry a session id and go through {@link mayTouch},
   * because they are about a terminal. These carry none: they are about the
   * **machine** — every login it has, and starting a login flow on it — so there
   * is no session to authorise against and the question becomes *whose device is
   * asking*. The answer is `ownDevice`, the same fact the copilot turns on, and
   * a guest is refused here as well as never being told the capability exists.
   *
   * The account grant narrows what a device sees inside `account.read`; it does
   * **not** appear here, and the reason is that these are already restricted to
   * the owner's own machines. A grant is how much of your machine you lend to
   * somebody else; one of your own computers is you at another keyboard, which is
   * the sentence the approval screen puts on that choice.
   */
  async function loginsServe(
    connection: LiveConnection,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'logins.read' | 'logins.signin' }>,
  ): Promise<void> {
    const logins = options.sessions.logins
    if (!logins || !advertised.includes(CAPABILITY.logins) || !ownDevice(deviceId)) {
      /*
       * One sentence for three states — no store, an old build, a guest — for the
       * reason the unauthorised-session refusal shares its wording with an
       * unknown id: a distinct refusal for the guest case would tell a device
       * that the machine *does* keep logins and is withholding them, which is a
       * fact about somebody's computer that a guest was not given.
       */
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: `This ${machineNoun(currentPlatform())} does not manage its logins from here.`,
      })
      return
    }

    if (message.t === 'logins.read') {
      const accounts = await logins.read()
      // The device can be gone by now: this reads a state file and up to a
      // handful of memoised probes, which is milliseconds but is not nothing.
      if (!live.has(connection.id)) return
      send(connection, { t: 'logins.state', rid: message.rid, accounts })
      return
    }

    const answer = await logins.signIn(message.accountId)
    if (!live.has(connection.id)) return
    send(connection, {
      t: 'logins.signedin',
      rid: message.rid,
      ok: answer.ok,
      // Passed through as written, for the reason `account.switched`'s is: this
      // is this machine's own sentence about its own account, and the asking
      // machine has no way to write a better one about a computer it is not on.
      message: answer.message,
      session: answer.session,
    })
  }

  async function chatServe(
    connection: LiveConnection,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'chat.read' }>,
  ): Promise<void> {
    const chat = options.sessions.chat
    if (!chat || !advertised.includes(CAPABILITY.chat)) {
      // Refused here as well as withheld from the advertisement, for the reason
      // `controlsServe` gives: the advertisement decides what a client of ours
      // draws, and this decides what *any* client gets.
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: `This ${machineNoun(currentPlatform())} cannot read a session’s conversation.`,
      })
      return
    }
    if (!mayTouch(deviceId, message.id)) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${message.id} is running.` })
      return
    }
    const answer = await chat.read(message.id, message.tail, deviceId)
    // The device can be gone by now: this is a file read, which is milliseconds
    // and is not nothing.
    if (!live.has(connection.id)) return
    send(connection, {
      t: 'chat.rows',
      rid: message.rid,
      id: message.id,
      rows: answer.rows.slice(-MAX_CHAT_ROWS),
      reset: answer.reset,
      found: answer.found,
    })
  }

  /**
   * Serve one `usage.read`.
   *
   * ## The same two doors, and the second one is still the one that matters
   *
   * The capability decides whether this host speaks the frame at all;
   * {@link mayTouch} decides whether *this device* may ask about *this session*,
   * and it is the same door `controls.read` and every `input` keystroke go
   * through. Deliberately not a weaker one: "what has this session's account
   * spent" is a fact about a subscription, and a device that may not attach to
   * the session has no more business with that than it has with the screen.
   * Two rules would be one more thing to keep in step, and folders are edited
   * from the settings panel while a device is connected.
   *
   * ## Why the branch is here and not behind one method
   *
   * Because one of the three is dear. `refresh` starts an agent CLI on this
   * machine — 725 MB, about three seconds — and `plan` and `context` read memory
   * and a file. Keeping them three named methods on {@link RemoteUsageAccess}
   * means the expensive one cannot be reached by a caller that meant one of the
   * cheap ones, which is exactly how a bar mounting would come to cost 725 MB a
   * tab.
   *
   * ## An unknown session is answered, not ignored
   *
   * Every path ends in a frame, for the reason `controlsServe` gives: the asking
   * side holds a promise per `rid`, and a request silently dropped is a bar that
   * spins until its own deadline and then reports "nobody answered" about a host
   * that had in fact refused. The one thing not sent is a reading for a session
   * this device may not see — that is a plain `error` with `unknown-session`,
   * the same sentence an unauthorised `attach` gets, because a distinct one
   * would confirm that the id names something real.
   */
  async function usageServe(
    connection: LiveConnection,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'usage.read' }>,
  ): Promise<void> {
    const usage = options.sessions.usage
    if (!usage || !advertised.includes(CAPABILITY.usage)) {
      // Refused here as well as withheld from the advertisement, and the
      // difference is the whole of it: `capabilitiesFor` decides what a client
      // of ours draws, and this decides what *any* client gets — including a
      // build older than the rule, or one somebody wrote themselves, that sends
      // the frame without having read the welcome.
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: `This ${machineNoun(currentPlatform())} cannot report a session’s usage.`,
      })
      return
    }
    if (!mayTouch(deviceId, message.id)) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${message.id} is running.` })
      return
    }

    const reading =
      message.want === 'refresh'
        ? await usage.refresh(message.id, message.force)
        : message.want === 'context'
          ? await usage.context(message.id)
          : await usage.plan(message.id)
    // The device can be gone by now, and for `refresh` it can have been gone for
    // seconds: the whole point of that branch is that it waits for a CLI.
    if (!live.has(connection.id)) return
    const answer: UsageAnswerWire = { reading }
    send(connection, { t: 'usage.reading', rid: message.rid, id: message.id, want: message.want, answer })
  }

  /**
   * Serve one `session.send`: type into a session this connection is not
   * attached to.
   *
   * ## One door, and it is deliberately not the handle
   *
   * `input` is refused unless `connection.handles` holds the session, and the
   * comment there says why in four words — *"Attachment is the authorisation"*.
   * That is a true sentence about `input` and it was never the only door.
   * {@link mayTouch} is the other one, and it is the one that actually decides
   * who may touch what: it is asked on the welcome, on `list`, on every
   * `attach`, and again on every `input` keystroke *after* the handle check,
   * because a handle only proves an attach that was allowed **then** and folders
   * are edited from the settings panel while a device is connected.
   *
   * So this verb asks `mayTouch` and nothing else, and that is the whole point
   * of it rather than a relaxation. `controlsServe` above already takes exactly
   * this position with exactly this door: `controls.apply` **writes characters
   * and a return into a pty** — no handle anywhere in its path — and it is
   * authorised by the reach alone. An attach is a subscription to a session's
   * *output*; the reach is the permission to *touch* it. A caller with something
   * to say and nothing to read should not have to buy the first to get the
   * second, and until this existed it did: the browser's Send-to-session picker
   * could name every session on every paired machine and could type into none of
   * them, because the only way to earn a handle would have been to displace the
   * one a terminal pane on this same connection already held — dropping that
   * pane's subscription and replaying its whole scrollback at the person reading
   * it. See `renderer/browser/agent-target.ts`, which states the problem and
   * prescribes this verb.
   *
   * ## Every path ends in a frame
   *
   * Including the refusals, and including the ones `controls` answers with a
   * plain `error`. The asking side holds a promise per `rid` and an `error`
   * frame carries no `rid`, so a refusal sent that way is a request that is
   * never settled and a panel that spins until its own deadline — over a machine
   * that answered instantly. The only thing withheld is *which* refusal it was:
   * a device that may not touch the session gets the same sentence an unknown id
   * gets, because a distinct one would confirm that the id names something real,
   * and these ids are recoverable from an alert, a transcript path or an older
   * list.
   */
  function sendServe(
    connection: LiveConnection,
    deviceId: string,
    message: Extract<ClientMessage, { t: 'session.send' }>,
  ): void {
    /*
     * The capability first, and it is the *only* gate this host applies that is
     * not about the device.
     *
     * Note what is not here: a check on the session layer. `controls` and
     * `usage` are advertised off an optional object and refused here when it is
     * absent, because a host can genuinely lack the thing behind them.
     * `SessionAccess.write` is a **required** member of that interface — every
     * host that exists can already do this — so the only way for the name to be
     * missing from `advertised` is `options.offer`, which is a decision
     * somebody took about a particular host rather than a capability it lacks.
     * The public demo box is that host, and it is why this check exists at all:
     * a client that never read the welcome still gets a sentence rather than
     * silence.
     */
    if (!advertised.includes(CAPABILITY.send)) {
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: `This ${machineNoun(currentPlatform())} cannot be sent to without attaching first.`,
      })
      return
    }
    if (!mayTouch(deviceId, message.id)) {
      send(connection, {
        t: 'session.sent',
        rid: message.rid,
        id: message.id,
        ok: false,
        message: `No session ${message.id} is running.`,
      })
      return
    }
    // Byte for byte what `case 'input'` does, and that is the assertion rather
    // than a coincidence: this frame is not a second way of writing to a pty,
    // it is the same write with a different authorisation in front of it.
    options.sessions.write(message.id, message.data)
    send(connection, {
      t: 'session.sent',
      rid: message.rid,
      id: message.id,
      ok: true,
      message: 'Sent.',
    })
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
    // Per connection rather than once, now that two devices watching the same
    // machine are entitled to two different lists. One `sessions` value shared
    // across the loop was correct while everybody saw everything and is a leak
    // the moment they do not.
    for (const other of live.values()) {
      if (other.id === connection.id || !other.deviceId) continue
      send(other, { t: 'sessions', sessions: sessionsFor(other.deviceId) })
    }
  }

  /**
   * End a session because a device asked.
   *
   * ## The fourth door, and why it needed its own gate
   *
   * `list`, `attach` and `create` are the three doors onto a machine's running
   * work, and all three grew a per-device rule tonight — `sessionsFor` filters
   * the list, `attach` refuses an id outside the device's reach, `create`
   * refuses a folder it was not granted. This is the fourth, and it is the one
   * that is not recoverable: reading somebody else's session is a leak, typing
   * into it is an intrusion, and ending it destroys work that was in progress.
   * So `mayTouch` is asked here as it is at the other three, and
   * `guest-close.test.ts` drives a real socket to prove a guest with one granted
   * folder cannot end a session running in another.
   *
   * ## The order of the three checks, which is not arbitrary
   *
   * The capability first, because a verb this host never advertised is a client
   * that is not ours and gets a refusal rather than a lookup. Then the device's
   * reach, and it is deliberately checked **before** the session layer is asked
   * anything at all — a desktop that ended the session and then decided whether
   * it was allowed to would have already done the thing. Then the outcome, which
   * is the only question left: was there a session there.
   *
   * ## Two refusals, one sentence
   *
   * A device that may not touch the session and a device naming an id that does
   * not exist are told the same thing, in the same words `attach` uses, for the
   * reason its own comment gives: a distinct message would confirm that the id
   * names something real, and these ids are recoverable from an alert, a
   * transcript path or a list taken before a folder was removed. A device that
   * was never meant to see it is told the truth it is entitled to — as far as
   * this connection is concerned, there is no such session.
   */
  function closeSession(connection: LiveConnection, deviceId: string, id: string): void {
    const end = options.sessions.close
    if (!end || !advertised.includes(CAPABILITY.close)) {
      send(connection, {
        t: 'error',
        code: 'unauthorized',
        message: 'Sessions cannot be closed from a device here.',
      })
      return
    }
    if (!mayTouch(deviceId, id)) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${id} is running.` })
      return
    }
    let ended = false
    try {
      ended = end.call(options.sessions, id) === true
    } catch (error) {
      // The session layer threw while killing a process. That is this machine's
      // problem and not the device's, and it must not take the socket down.
      console.error('[remote] could not close a session for a device:', error)
      send(connection, {
        t: 'error',
        code: 'unavailable',
        message: 'That session could not be closed.',
      })
      return
    }
    if (!ended) {
      send(connection, { t: 'error', code: 'unknown-session', message: `No session ${id} is running.` })
      return
    }

    // This connection's own subscription goes with it. The pty's exit will empty
    // the fanout's listener set anyway, but the handle in this map is what
    // `input` and `resize` check first, and leaving it behind would mean a
    // keystroke arriving for a session that no longer exists passed the first
    // gate on the strength of a handle to a dead process.
    const handle = connection.handles.get(id)
    if (handle) {
      options.sessions.detach(handle)
      connection.handles.delete(id)
    }

    send(connection, { t: 'closed', id })
    // Everyone else hears about it as an ordinary list refresh, exactly as they
    // do for `created` and for the same reason: `closed` is a capability frame
    // that names *this* device's action, and `sessions` is v1, so a client that
    // has never heard of closing still watches the row disappear. Per connection
    // rather than once, because two devices watching the same machine are
    // entitled to two different lists.
    for (const other of live.values()) {
      if (other.id === connection.id || !other.deviceId) continue
      send(other, { t: 'sessions', sessions: sessionsFor(other.deviceId) })
    }
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
      if (message.t !== 'hello' && message.t !== 'enroll') {
        // Not merely ignored: a client that talks before authenticating is
        // either broken or probing, and neither deserves a second try here. The
        // only two doors before a welcome are `hello` and `enroll`.
        refuse(connection, 'unauthenticated', 'Say hello first.', CLOSE.policyViolation)
        return
      }
      if (connection.greeting) {
        // The single-flight covers both doors: a second hello or a second enroll
        // while one is still being answered is refused, so two asynchronous
        // checks never run against a connection that is unauthenticated for both.
        refuse(connection, 'bad-message', 'One at a time.', CLOSE.protocolError)
        return
      }
      connection.greeting = true
      const greeting = message.t === 'enroll' ? enrol(connection, message) : hello(connection, message)
      void greeting
        .catch((error) => {
          console.error('[remote] greeting failed:', error)
          if (!live.has(connection.id)) return
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
      case 'enroll':
        // Signing in after this socket is already signed in changes nothing it
        // could want changed — it has a device — and the only thing a second
        // enroll here could do is mint a stray row on an authenticated socket.
        // Refused and closed, the same rule the second hello above follows.
        refuse(connection, 'bad-message', 'Already signed in.', CLOSE.protocolError)
        return
      case 'list':
        send(connection, { t: 'sessions', sessions: sessionsFor(connection.deviceId) })
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
        /*
         * And the device's reach again, on every keystroke.
         *
         * A handle is proof of an attach that was allowed *then*. Folders are
         * edited from the settings panel while a phone is connected — that is
         * the whole reason `SessionStarter.folders` is called per request rather
         * than captured once — so a handle taken before a folder was removed
         * would otherwise stay a live keyboard on somebody's agent until they
         * happened to reconnect. Removing a folder has to mean removing it.
         */
        if (!mayTouch(connection.deviceId, message.id)) {
          send(connection, {
            t: 'error',
            code: 'unauthorized',
            // Was "That folder is no longer shared with this device." It named
            // the folder because the folder was the only axis. It is not any
            // more — a session can be unticked on its own, in a folder that is
            // still shared — so the sentence names the thing that stopped being
            // shared rather than guessing which of two rules did it.
            message: 'That session is no longer shared with this device.',
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
        // Same check as `input` above, and the same reason. A resize reshapes
        // the pty everyone else is looking at, including the person at the desk.
        if (!mayTouch(connection.deviceId, message.id)) return
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
      case 'close':
        closeSession(connection, connection.deviceId, message.id)
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
        //
        // Checked here rather than only in the advertisement, and the difference
        // is the whole of it: `capabilitiesFor` decides what a *client of ours*
        // draws, and this decides what *any* client gets. A build that is older
        // than the rule, or one somebody wrote themselves, sends these frames
        // without having read the welcome. The refusal is a sentence on a
        // channel that stays open, because a device being told "not you" must
        // not also lose the terminal it is holding.
        if (!localhostAllowed(connection)) return
        hubFor(connection, connection.deviceId).handle(message satisfies LocalhostMessage)
        return
      case 'web.open':
        webOpen(connection, connection.deviceId, message.url)
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
      case 'controls.read':
      case 'controls.apply':
        // Not awaited, for the same reason `create` and `dev.status` are not:
        // applying types a command into a pty and then waits seconds for the CLI
        // to answer it, and the message loop is the socket's data handler. A
        // window that stopped reading its socket for six seconds would freeze
        // every other session on the connection while one menu was working.
        void controlsServe(connection, connection.deviceId, message).catch((error) => {
          console.error('[remote] a controls request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That session’s controls could not be reached.',
          })
        })
        return
      case 'session.send':
        // Not awaited and not asynchronous: writing into a pty is a synchronous
        // call this process already holds the handle for, exactly as `input` is
        // two cases up. The neighbours below spawn processes and wait seconds
        // for a CLI, which is why they are promises; nothing here does.
        sendServe(connection, connection.deviceId, message)
        return
      case 'usage.read':
        // Not awaited, for the reason the controls above are not — and here the
        // reason is measured rather than argued: the `refresh` branch boots an
        // agent CLI and waits about three seconds for it. A message loop that
        // stopped reading its socket for three seconds would freeze every
        // session on the connection while one bar was looking at a percentage.
        void usageServe(connection, connection.deviceId, message).catch((error) => {
          console.error('[remote] a usage request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That session’s usage could not be read.',
          })
        })
        return
      case 'account.read':
      case 'account.switch':
        // Not awaited, for the reason the two above are not, and here the wait is
        // the longest on this wire: a switch spawns an agent CLI, waits for it to
        // survive its first seconds and only then kills the session it replaced.
        void accountServe(connection, connection.deviceId, message).catch((error) => {
          console.error('[remote] an account request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That session’s account could not be reached.',
          })
        })
        return
      case 'logins.read':
      case 'logins.signin':
        // Not awaited, for the reason the account frames above are not: a
        // sign-in starts an agent CLI on this machine, and a socket that stopped
        // reading would freeze every session on the connection while it did.
        void loginsServe(connection, connection.deviceId, message).catch((error) => {
          console.error('[remote] a logins request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'This machine’s logins could not be reached.',
          })
        })
        return
      case 'chat.read':
        // Not awaited, for the reason the readings above are not: this is a file
        // read on this machine and a socket that stopped reading would freeze
        // every session on the connection while one view loaded a conversation.
        void chatServe(connection, connection.deviceId, message).catch((error) => {
          console.error('[remote] a chat request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            message: 'That session’s conversation could not be read.',
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
      case 'window.holds': {
        /*
         * A device saying which of this machine's sessions it is holding a
         * browser window for.
         *
         * This is the fact that makes the feature work for a session nobody
         * started remotely — one already running here, or restored here, or
         * typed into at this keyboard — because the window is attached in *that*
         * app's map and nothing on this side of the wire can see it. See
         * `CAPABILITY.windows` and `WindowAskDesk.held`.
         *
         * Recorded whatever the ids are and whether or not this machine has ever
         * heard of them. It is not a grant and it takes nothing away: a session
         * with a window attached *here* is still served here (see the forwarder
         * in `index.ts`), and a verb addressed to this device is still resolved
         * over there inside that session's own binding — so a device that named
         * a session it holds no window for has arranged for its own frames to
         * come back refused.
         */
        options.windows?.held(connection.deviceId, message.sessions)
        return
      }
      case 'sessions.mine': {
        /*
         * A device saying what is running on **its** computer, so this app can
         * offer one of those sessions in its own attach menu.
         *
         * ## Why this frame is the whole of the fourth case
         *
         * `windowsHeldFor` in `index.ts` filters the binding map for bindings
         * whose machine is this device, and for as long as this frame did not
         * exist that filter was correct and always empty. The picker that mints
         * bindings — `renderer/browser/agent-target.ts` — is built from this
         * machine's own ptys and from the machines this desktop *dialled out to*,
         * and a device that dialled *in* is in neither list. So nobody at this
         * keyboard could attach a window to one of its sessions, so no binding
         * was ever filed under its id, so the `window.holds` this app sends it
         * was the honest empty set, so its agent's browser verbs had nowhere to
         * go. Three of the four directions worked; this was the fourth.
         *
         * ## What accepting it does and does not do
         *
         * It writes a list of rows on this socket and pushes the roster. That is
         * all. It is not a grant, it authorises nothing, and it cannot: there is
         * no verb in this protocol by which this host types into, starts, reads or
         * closes a session on a device, and none is added here. The one thing it
         * unlocks is a row in a menu on this screen, and the browser verb that row
         * leads to arrives as `window.call` — refused unless `WindowGrants.drives`
         * says yes, read per call, defaulting to no.
         *
         * A device naming sessions it does not have has arranged for its own
         * frames to come back refused, exactly as `window.holds` above: the verb
         * is resolved over there, inside that session's own binding.
         *
         * ## Why it is dropped rather than refused when this host cannot use it
         *
         * `serveWindows` absent means this build has no browser to drive, so a
         * window could never be attached to one of these rows and the list would
         * be a menu of dead entries. A client only sends this after this host
         * advertised `hostWindows`, which is advertised on the same dep — so a
         * frame arriving without it is a client talking to an older desktop, and
         * an announcement nobody asked for is dropped rather than made a reason to
         * close somebody's link.
         */
        if (options.serveWindows === undefined) return
        connection.sessions = message.sessions
        announce()
        return
      }
      case 'window.result': {
        /*
         * A device answering a browser verb this machine asked it to run.
         *
         * The desk matches the id against a question it sent, so a frame naming
         * anything else is dropped — but the id is not the authorisation and must
         * not be read as one. What binds this answer to that question is that the
         * desk only ever hands ids to `ask`, and `ask` only ever writes to the
         * device the session belongs to; a second device replaying an id it
         * observed cannot have observed one, because each channel is sealed.
         *
         * A frame nothing was waiting for is dropped in silence rather than
         * refused. It is what a device sends when its answer and this end's
         * deadline crossed on the wire, which is an ordinary race with an already
         * correct outcome — the tool call has been answered — and closing the
         * channel over it would turn a slow network into a dropped link.
         */
        options.windows?.answer(message.id, { ok: message.ok, body: message.body })
        return
      }
      case 'window.call': {
        /*
         * The mirror: a session on that device asking this machine to act on a
         * browser window **here**.
         *
         * Answered on this socket whatever happens, including when there is no
         * server wired and when the server throws. The far end is inside an MCP
         * tool call with a model waiting on it, so silence costs a whole turn and
         * produces the thing `session-verbs.ts` was written to stop: an agent
         * that concludes it has not found the way in yet and goes looking for
         * another.
         *
         * Refused outright when this host never advertised `hostWindows`, and
         * that refusal is not a formality. A device that sends a frame nobody
         * offered is either a build talking to an older desktop or something that
         * is not this app, and the honest answer to both is the same sentence:
         * there is nothing here to drive.
         *
         * Everything else — the grant, the allow-list, the binding lookup, the
         * tier, the confirmation, the log — is `window-serve.ts`'s, reached
         * through `options.serveWindows`. None of it is re-implemented here and
         * none of it may be; a second dispatcher is how one of them comes to
         * allow what the other refuses.
         */
        const serve = options.serveWindows
        if (serve === undefined) {
          send(connection, {
            t: 'window.result',
            id: message.id,
            ok: false,
            body: JSON.stringify({
              message:
                'that computer is not set up to be driven from here. Say what you would have done on ' +
                'the page and let the person do it.',
            }),
          })
          return
        }
        const deviceId = connection.deviceId
        void serve(deviceId, {
          sessionId: message.session,
          tool: message.tool,
          args: message.args,
        })
          .then((result) => {
            send(connection, { t: 'window.result', id: message.id, ok: result.ok, body: result.body })
          })
          .catch((error: unknown) => {
            send(connection, {
              t: 'window.result',
              id: message.id,
              ok: false,
              body: JSON.stringify({
                message: error instanceof Error ? error.message : 'that could not be done here',
              }),
            })
          })
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
      case 'copilot.hello':
      case 'copilot.bye': {
        /*
         * The two frames that open and close it, deliberately **not** tier-gated.
         *
         * Gating these on a tier would be circular: the tiers are read off the
         * connection these frames establish, so requiring one to send them would
         * mean no device could ever open the stream.
         * `COPILOT_UNTIERED_FRAMES` names them so that "which verbs skip the
         * tier check" is answerable from the code rather than inferred from an
         * absence, and `copilot-frames.test.ts` asserts the two lists together
         * cover every `copilot.*` client verb.
         *
         * What still holds: the socket is authenticated as a device — the guard
         * at the top of this function returned for anything that has not said
         * hello — and the code or credential is checked by `copilot-link.ts`,
         * with its own expiry, its own single use and its own lockouts.
         */
        const copilot = options.copilot
        if (!copilot) {
          send(connection, {
            t: 'error',
            code: 'unauthorized',
            message: 'There is no copilot to reach on this machine.',
          })
          return
        }
        void copilotConnectServe(connection, copilot, connection.deviceId, message).catch((error) => {
          console.error('[remote] a copilot connection request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            // Not quoted, for the reason every other refusal here is not: the
            // error came from a hash or a file write on this machine and the
            // sentence is drawn on somebody's phone.
            message: 'The copilot connection could not be set up just now.',
          })
        })
        return
      }
      case 'copilot.attach':
      case 'copilot.detach':
      case 'copilot.state':
      case 'copilot.sessions':
      case 'copilot.log':
      case 'copilot.pending':
      case 'copilot.answer':
      case 'copilot.start':
      case 'copilot.say':
      case 'copilot.cancel':
      case 'copilot.stop': {
        /*
         * Listed one by one rather than caught by a prefix test, so that adding
         * a verb to this capability without deciding which tier it needs stops
         * the build instead of falling through to a handler that assumes `read`.
         *
         * The tier check is `copilotFor`, and it is deliberately **not** the
         * boundary — see `copilot-remote.ts`. It keeps the UI honest and gives a
         * clean refusal; the boundary is `DeckControl.call` on the desktop, at
         * the point a tool is dispatched, and it holds whether or not this
         * transport exists.
         *
         * `connection.deviceId` is a `string` here and not `string | null`: the
         * guard at the top of this function returned for anything that had not
         * said hello, and nothing between reassigns it. Passing it rather than
         * letting the run manager read it off a connection is the same argument
         * `create` makes — whose request this is must come from the
         * authenticated socket, never from the frame.
         */
        const copilot = copilotFor(connection, connection.deviceId, message.t)
        if (!copilot) return
        void copilotServe(connection, copilot, connection.deviceId, message).catch((error) => {
          console.error('[remote] copilot request failed:', error)
          if (!live.has(connection.id)) return
          send(connection, {
            t: 'error',
            code: 'unavailable',
            // The error is not quoted. It came from a spawn on this machine and
            // this sentence is drawn on somebody's phone; `protocol.ts`'s rule
            // that reasons never quote what was refused applies more sharply
            // here, because the value could be a line of the copilot's own
            // conversation.
            message: 'The copilot could not be reached just now.',
          })
        })
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
      sessions: [],
      handles: new Map(),
      tunnels: null,
      uploads: null,
      devFolders: new Set(),
      copilot: null,
      copilotOpen: false,
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
          /*
           * And every browser verb outstanding to that device, for the same
           * reason and read from the other end: a tool call on this machine must
           * not spend fifty-five seconds finding out that the computer holding
           * the window hung up. `gone` settles them all with a sentence now.
           *
           * Unconditional rather than "only if this was the last channel". The
           * desk is keyed by device, a device with two channels is a device that
           * heard the ask twice, and settling early is the direction that cannot
           * strand a turn.
           */
          options.windows?.gone(deviceId)
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

  /*
   * The same shape one capability along, and the same reason for it: the desk is
   * built by the assembly, because `deck-control`'s browser tools forward
   * through it, and the live connections belong here.
   *
   * `windows` rather than `credential` in the capability test, and it is not
   * interchangeable: a device that can answer a git login has said nothing about
   * whether it holds browser windows or knows the frame that asks about one.
   */
  options.windows?.serve({
    ask(deviceId: string, message: ServerMessage): number {
      let heard = 0
      for (const connection of live.values()) {
        if (connection.deviceId !== deviceId) continue
        if (!connection.capabilities.includes(CAPABILITY.windows)) continue
        send(connection, message)
        heard += 1
      }
      return heard
    },
    /*
     * The same two conditions, asked without writing to anybody's socket.
     *
     * The launch gate in `host-core.ts` is the caller: a session started for a
     * device that cannot serve a browser verb is launched with no browser verbs
     * and told why, rather than with six tools that all end in the same sentence
     * about a device that is plainly connected. A phone is exactly that device —
     * it holds no windows and its client has never heard of `window.call` — and
     * before this it was the constant `true` that handed it the six.
     */
    reaches(deviceId: string): boolean {
      for (const connection of live.values()) {
        if (connection.deviceId !== deviceId) continue
        if (!connection.capabilities.includes(CAPABILITY.windows)) continue
        return true
      }
      return false
    },
  })

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
      /*
       * And its copilot run goes with it, before the socket does.
       *
       * Closing the socket alone would leave a Claude CLI process running in the
       * copilot's folder, holding an MCP token that `remoteCopilotCaller` would
       * keep resolving — to `NO_TIERS`, once the grant store has been cleared,
       * so it could no longer *do* anything. But it would still be spending
       * money on a turn nobody can read, for a device that has just been thrown
       * off the machine. Revocation stops the process, not merely its powers.
       */
      options.copilot?.revoked(deviceId)
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
    sessionsChanged: tellSessions,
    windowsHeldChanged: tellWindowsHeld,
    copilotGrantChanged: tellCopilotGrant,
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
    // Nothing to tell with the server down: no device is connected, and each
    // one reads the list it missed in its `welcome` the next time it is.
    sessionsChanged: () => endpoint?.sessionsChanged() ?? 0,
    // Same rule, same reason: with the server down there is no socket to say
    // it on, and every device reads the set it missed in its next `welcome`.
    windowsHeldChanged: () => endpoint?.windowsHeldChanged() ?? 0,
    copilotGrantChanged: (deviceId) => endpoint?.copilotGrantChanged(deviceId) ?? 0,
    dropConnection: (connectionId) => endpoint?.dropConnection(connectionId) ?? false,
    stopTunnel: (connectionId, tunnelId) => endpoint?.stopTunnel(connectionId, tunnelId) ?? false,
    status: snapshot,
    // No relay configured (`TERMINALDECK_RELAY=off`) means nothing to re-dial.
    wake: () => relay?.wake(),
  }
}

/* --------------------------------------------------------------------- ipc -- */

/**
 * Main → renderer. **The remote picture changed** — go and read it again.
 *
 * It began as a narrower promise: a phone authenticating, attaching, detaching
 * or leaving. That was every change a *connection* could undergo, and it left
 * out the one change that matters most to somebody sitting in front of the app,
 * because it is not a connection change at all.
 *
 * **A device pairing produces no connection.** `authenticatorFor` redeems the
 * code, creates the row, and then deliberately refuses the socket — a pairing
 * token can be photographed off a screen, so a human at this machine has to
 * approve the device before it is admitted. The refused socket never gets a
 * `deviceId`, and `publicConnections` skips anything without one, so the
 * connection list is byte-for-byte identical before and after the single most
 * consequential thing that can happen on this surface. Nothing fired. The
 * settings pane that was *already open on the pairing screen* — the pane you
 * are necessarily looking at, because it is where the six digits came from —
 * went on showing a list with no waiting device in it, and stayed that way
 * until something else happened to make it re-read. That is the likeliest
 * explanation for four browser pairings watched sitting pending through
 * repeated approval attempts: they had paired, and no surface in the app had
 * been told.
 *
 * So the channel now means what both of its listeners already treated it as
 * meaning. Neither reads the payload to decide what changed — `RemoteSection`
 * says so in as many words ("the payload is ignored on purpose: one read is one
 * source of truth") and the alerts feed does the same — they re-read. Widening
 * a signal that is already used as a bare nudge costs one extra read on a rare
 * event and closes the hole; narrowing it to connections alone was never a
 * property anything relied on.
 *
 * Fired for: a phone authenticating, attaching, detaching or leaving; **and** a
 * device pairing, being approved, or being revoked.
 */
export const REMOTE_CONNECTIONS_CHANNEL = 'remote:connections'

/**
 * Main → renderer. Fires when a device redeems a connect code.
 *
 * Carries the whole list rather than the one device, for the same reason the
 * `remote:copilot` channels answer with the whole list: the panel renders what
 * the main process says rather than what it just asked for.
 */
export const REMOTE_COPILOT_CHANNEL = 'remote:copilot:changed'

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
  /**
   * Which of the running sessions each device may see — the second axis.
   *
   * Passed in for exactly the reason `folders` beside it is: the predicate the
   * session fanout closes over reads this store, and it is built at assembly,
   * before this function is called. A second one here would answer the panel
   * from one copy of the file and every connection from another.
   *
   * **Optional, and its absence is the switch.** A host with no per-session
   * choice — the headless daemon before this is wired, `scripts/remote-host.ts`,
   * the public demo box — answers the panel's channels with nothing rather than
   * drawing a control over a store that decides nothing.
   */
  sessionGrants?: SessionGrants
  /**
   * Which of this machine's logins each device may use — the third axis.
   *
   * Passed in for exactly the reason `folders` and `sessionGrants` are: the
   * filter every account frame goes through closes over this store, and it is
   * built at assembly, before this function is called. A second one here would
   * answer the approval screen from one copy of the file and every connection
   * from another.
   *
   * **Optional, and its absence is the switch.** A host with no per-device
   * account choice answers the panel's channels with nothing and shares every
   * login with every paired device — which is what every host written before this
   * store existed already does.
   */
  accountGrants?: AccountGrants
  /**
   * Which devices may act on the browser windows in this app — the fourth axis.
   *
   * Passed in for exactly the reason the three above are: the check every
   * forwarded browser verb goes through closes over this store, and it is built
   * at assembly. A second one here would answer the settings panel from one copy
   * of the file and every `window.call` from another.
   *
   * **Optional, and its absence is the switch** — but read which way it fails.
   * The three above widen when they are absent, because they narrow a thing that
   * already worked. This one is the permission itself: a host with no store
   * allows **nobody**, which is what every host written before it already does.
   */
  windowGrants?: WindowGrants
  /**
   * Whether each device is one of the owner's own or a guest.
   *
   * Passed in for exactly the reason `folders` beside it is: `index.ts` needs
   * this object *before* this function is called, because the reach rule the
   * session layer closes over reads it. A second store built here would answer
   * the approval screen from one copy of the file and every connection from
   * another, and the two would agree right up until somebody approved a device.
   */
  kinds: DeviceKinds
  /**
   * Open a page on this machine, for a device that asked. Absent is the switch.
   *
   * The Electron shell passes `openAppLink` against its own window, so the page
   * becomes a tab of *this app's* browser rather than a launch of the system
   * one. The headless daemon passes nothing and never advertises `web`.
   */
  openUrl?(url: string): boolean
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
   * The desk holding this machine's questions to a device about a browser
   * window it is showing.
   *
   * **Absent is the switch**, as everywhere else here: with no desk the
   * `windows` capability is not advertised, a device never says it can serve
   * one, and a session started for a device is launched without the browser
   * verbs and told why — rather than holding six tools whose every call would
   * end in a timeout.
   *
   * Injected rather than constructed here because the same desk is what
   * `deck-control`'s browser tools reach when they forward a verb: one desk, or
   * the frame goes out on a socket and the answer is matched against a table
   * nobody sent from.
   */
  windows?: WindowAskDesk
  /**
   * Serving a browser verb that arrived **from** a device, against a window in
   * this app.
   *
   * The mirror of {@link windows} above, and the two are not the same feature
   * read twice: `windows` is this machine asking a device to move a browser it
   * holds, this is a device asking this machine to move one *here*. Which of the
   * two a given link needs depends only on which end the person is sitting at,
   * and a desktop that dialled another desktop can need both at once.
   *
   * **Absent is the switch**, as everywhere else here: with no server the
   * `hostWindows` capability is not advertised, so a device never sends the
   * frame and never waits on an answer that is not coming.
   *
   * Nothing about the decision is here. The grant is read per call in
   * `window-grants.ts`, the allow-list is `ELSEWHERE_TOOLS` — the session grant
   * minus the tools whose answers are files on this computer — the window is
   * resolved inside that session's own binding, and the answer is cut to fit by
   * `fitAnswer` — all of it in `machines/window-serve.ts`, which is the same
   * function the machine links serve their asks through. One decider, or the two
   * come to allow what each other refuses.
   */
  serveWindows?(
    deviceId: string,
    call: { sessionId: string; tool: string; args: string },
  ): Promise<{ ok: boolean; body: string }>
  /**
   * Which of **that device's** sessions this app is holding a browser window
   * for, asked whenever the answer has to be sent.
   *
   * The other half of {@link serveWindows}, and the half without which it would
   * never fire: a session over there cannot address a window here unless it has
   * been told there is one. A window attached in this app is a relation in *this*
   * process — `browser-binding.ts` — and the machine the pty is on has no way to
   * derive it.
   *
   * A function rather than a list, read at the moment of sending, because the
   * answer changes every time somebody attaches or detaches a window; and per
   * device, because a link may only be told about its own — the sessions of one
   * paired computer are not facts the next one gets to hear.
   */
  windowsHeldFor?(deviceId: string): readonly string[]
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
   * The copilot, as a paired device may touch it. Absent is the switch — see
   * {@link RemoteEndpointOptions.copilot}.
   *
   * Passed in for the same reason `folders`, `credentials` and `devServers` are:
   * `index.ts` builds it before this function is called, because the run manager
   * needs `deck-control`'s caller table and the app's own session starter, and a
   * second one built here would mint tokens into a table nothing checks.
   */
  copilot?: CopilotRemote
  /**
   * Who reaches the copilot, for the settings panel to *show*.
   *
   * Read-only now, and the change of tense is the whole of 2026-08-19: this used
   * to be the *editing* side of a store of separate connections, with channels
   * that minted a code, disconnected a device and set its tiers. There is
   * nothing to edit any more — a device's kind is the answer and a kind is fixed
   * when the device is approved — so the panel's only remaining question is
   * *which of my devices have it*, which this derives. `copilot-access.ts`
   * carries the argument.
   *
   * Absent means the panel's channel answers with nothing, which is what a host
   * with no copilot should say to a UI that has no business asking.
   */
  copilotLinks?: CopilotAccess
  /**
   * The ceiling on what this host advertises. See {@link RemoteEndpointOptions.offer}.
   *
   * Forwarded rather than recomputed, because the thing that knows a host is a
   * public demo box is the assembly that built it, and this function is the only
   * road from there to the endpoint.
   */
  offer?: readonly string[]
  /**
   * Whether this host serves sign-in. **Default true; false never builds it.**
   *
   * Sign-in is on wherever this machine's own sshd answers on loopback, with no
   * toggle — anyone who can already log in to this computer holds strictly more
   * power than a paired device, so admitting them adds none, and a host with no
   * sshd simply refuses with a sentence naming the pairing-code remedy. The one
   * host that sets this false is the public demo box, which must not hand a
   * stranger a road to becoming one of the owner's own devices.
   */
  signin?: boolean
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
/**
 * What one relay state change is told to, in order: the assembly's own hook,
 * then every window.
 *
 * The second half is 2026-08-22's. `onRelayState`'s doc used to say "nothing
 * with a window needs it — a panel reads `remote:status` when it draws", and
 * that was true of panels and false of the one sentence computed from relay
 * state that stands on screen *between* draws: the pairing screen's `blocked`
 * line (`machines:list` builds it from this relay's state). On a machine with
 * nothing paired yet there are no machine links to publish when the relay
 * comes up, so nothing pushed `machines:state`, and the warning outlived the
 * condition it warned about — cleared, until 2026-08-22, only by the machines
 * hook's four-second poll. The poll is gone (his rule: events, not polling),
 * so the event is real now: the relay's state change lands on
 * `remote:connections`, the channel that already means "the remote picture
 * moved" and whose listeners re-read and ignore the payload — see
 * {@link REMOTE_CONNECTIONS_CHANNEL} for the first widening and why it is
 * cheap. Rare by nature: a relay connects once per launch and drops when a
 * network does.
 *
 * Named and exported rather than an inline arrow so the composition is a thing
 * a test can call: the wiring itself is pinned by `relay-announce.test.ts`.
 */
export function relayStateFanout(
  tell: ((state: RelayState) => void) | undefined,
  announce: () => void,
): (state: RelayState) => void {
  return (state) => {
    tell?.(state)
    announce()
  }
}

function relayFor(
  storageDir: string,
  url: string,
  auth: RemoteAuth,
  desk: PairingDesk,
  /**
   * Whether this host serves sign-in. When it does, a device this Mac has never
   * seen is let through the handshake so it can send `enroll` — the third of the
   * three narrow doors below. Admission still grants nothing.
   */
  enrollServed: boolean,
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
            // Three ways in, and every one is narrow. A device this Mac already
            // knows, by a key it stored when that device paired — or any device
            // at all while a pairing code is on screen, because a phone pairing
            // for the first time has no key here to be known by — or any device
            // at all while sign-in is served, because a phone signing in for the
            // first time is in the same position and its `enroll` frame is the
            // thing that then proves the login. None of the three grants access:
            // the hello or enroll that follows still has to prove a credential or
            // a login, and a paired device still has to be approved.
            isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open() || enrollServed,
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

  // Sign-in, on every host except the one that says not to. Built here for the
  // reason `relay` is: this is the only place that holds the trust store and the
  // device kinds together. Building it starts nothing — the loopback probe only
  // runs when a device actually sends `enroll`. `undefined` is the switch, and
  // it also decides whether the relay lets an unknown device through the
  // handshake far enough to send that frame.
  const enroll = deps.signin === false ? undefined : createEnrollAccess({ auth, kinds: deps.kinds, env })

  // Built here rather than inside the server, because this is the only place
  // that holds the trust store and the storage directory. Building it dials
  // nothing and writes no key on its own — `start()` at the bottom of this
  // function is what does both, on every launch unless this Mac was switched
  // off.
  const relay = relayEnabled(env, deps.relayEnabled)
    ? relayFor(
        deps.storageDir,
        relayUrl(env, deps.relayUrl),
        auth,
        desk,
        enroll !== undefined,
        relayStateFanout(deps.onRelayState, () => announceRemoteChange()),
      )
    : null

  /**
   * Tell every window that the remote picture moved.
   *
   * A function declaration rather than a `const`, because it is referenced from
   * inside the `createRemoteServer` call below — hoisting is what lets the
   * pairing hook be written where the pairing happens rather than being patched
   * on afterwards. It reads `server` only when it runs, which is always long
   * after the assignment completes.
   *
   * The payload is the live connection list, which is usually *unchanged* at
   * the three moments this is called from. That is not a lie and not padding:
   * both listeners re-read the whole state and ignore what arrives, so the
   * payload's only job is to be true, and the true current list is what it is.
   * See {@link REMOTE_CONNECTIONS_CHANNEL} for why the signal was widened.
   */
  function announceRemoteChange(): void {
    deps.broadcast(REMOTE_CONNECTIONS_CHANNEL, server.connections())
  }

  const server = createRemoteServer({
    sessions: deps.sessions,
    /*
     * The pairing hook, wired for every host rather than only the headless one.
     *
     * `deps.onDevicePaired` is the demo box's private arrangement — it approves
     * from a broker allocation — and it is still called, unchanged and first,
     * because it is the one caller whose behaviour depends on running before the
     * refusal frame goes out (see {@link RemoteIpcDeps.onDevicePaired}). What is
     * added around it is the thing every host needs and none had: the window is
     * told, so the device that just paired is visible somewhere other than in a
     * settings pane that happens to be re-read.
     *
     * Wrapped in nothing here — `authenticatorFor` already swallows a throw from
     * this callback, and it must, because the pairing code has been burned by
     * this point and a listener that failed would strand the device forever.
     */
    auth: authenticatorFor(auth, desk, (device) => {
      /*
       * The announcement goes first, and inside its own guard.
       *
       * `authenticatorFor` wraps this whole callback in a try/catch, so an
       * exception anywhere in it is swallowed and the pairing still completes —
       * which is correct and is why the two halves must not be able to take each
       * other down. If the demo box's hook threw and the announcement came
       * after, the window would never hear about a device that had genuinely
       * paired; guarding the broadcast separately, and running it first, means
       * neither half can silence the other whichever one fails.
       */
      try {
        announceRemoteChange()
      } catch (error) {
        console.error('[remote] could not announce a new pairing to the window:', error)
      }
      deps.onDevicePaired?.(device)
    }),
    // Absent is the switch, like every capability spread below: with no access
    // an `enroll` frame is refused `unavailable`, which is exactly what the demo
    // box (signin === false) wants.
    ...(enroll ? { enroll } : {}),
    webRoot: deps.webRoot,
    certDir: deps.storageDir,
    ...(deps.uploadsDir ? { uploadsDir: deps.uploadsDir } : {}),
    ...(deps.credentials ? { credentials: deps.credentials } : {}),
    /*
     * The desk this machine's sessions ask a device through, when the browser
     * window one of them is attached to is on that device's screen.
     *
     * Absent is the switch here too: with no desk the `windows` capability is
     * not advertised, no device ever says it can serve one, and `host-core.ts`
     * launches a device's session with no browser verbs and tells it why.
     */
    ...(deps.windows ? { windows: deps.windows } : {}),
    /*
     * And the two halves of the mirror, spread on the same rule: absent means
     * this host does not advertise `hostWindows`, so no device ever sends a
     * `window.call` here and none waits on an answer that is not coming.
     */
    ...(deps.serveWindows ? { serveWindows: deps.serveWindows } : {}),
    ...(deps.windowsHeldFor ? { windowsHeldFor: deps.windowsHeldFor } : {}),
    // Spread rather than passed as possibly-undefined, like everything else that
    // is a switch: absent means this host does not advertise `devserver` at all.
    ...(deps.devServers ? { devServers: deps.devServers } : {}),
    // Likewise. A host with no copilot layer does not advertise `copilot`, so a
    // phone talking to it draws no Copilot tab at all — which is the shape
    // Asad's constraint on this feature demands: *"we don't want to give this
    // copilot to others."*
    ...(deps.copilot ? { copilot: deps.copilot } : {}),
    /*
     * And who it is shared with, which is a narrower question than whether it
     * exists.
     *
     * Read live rather than snapshotted, because a device is approved while
     * other devices are connected and the answer for a device paired a minute
     * from now has to be right without a restart. His sentence — *"the copilot
     * is never shared"* — is enforced here as an absence: an ineligible device
     * is never told the capability exists, so nothing on its screen offers it.
     */
    copilotEligible: (deviceId) => deps.kinds.kindOf(deviceId) === 'mine',
    /*
     * And which of this machine's logins each device may use.
     *
     * Read live rather than snapshotted, for the reason `copilotEligible` above
     * is: the choice is made when a device is approved and edited afterwards
     * from the settings panel, both of which happen while other devices are
     * connected.
     *
     * Spread, so a shell with no store shares everything — the state every host
     * written before this file was in, and the state the two machines already
     * paired when it arrived were in.
     */
    ...(deps.accountGrants
      ? {
          accountAccess: {
            shares: (deviceId, accountId) => deps.accountGrants?.shares(deviceId, accountId) ?? true,
            any: (deviceId) => deps.accountGrants?.any(deviceId) ?? true,
          },
        }
      : {}),
    /*
     * And whether a device is one of his own, which decides whether it may
     * manage this machine's logins at all.
     *
     * The same fact `copilotEligible` reads, deliberately asked again rather
     * than shared: they are two features that happen to agree today, and a
     * single predicate would mean the next person to change one had silently
     * changed the other.
     */
    ownDevice: (deviceId) => deps.kinds.kindOf(deviceId) === 'mine',
    /*
     * `reachFor`'s own rule, spelled here because this is the layer that has the
     * device kinds. One of your own machines may be handed a file anywhere on
     * this disk, exactly as it may start a session anywhere; a guest may only be
     * handed one inside a folder somebody chose for it.
     */
    unrestrictedFolders: (deviceId) => deps.kinds.kindOf(deviceId) === 'mine',
    // Spread, so a shell with no window advertises no `web` capability at all —
    // the headless daemon is exactly that, and a page it could not open must
    // not appear as a button on somebody's phone.
    ...(deps.openUrl ? { openUrl: deps.openUrl } : {}),
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

  /**
   * Approving a device is now three writes, and the order is the whole fix.
   *
   * What it used to be: one call, `auth.approveDevice(id)`, after which the
   * device was in. The folder list was a *separate* block further down the same
   * settings page that nobody had to visit, and a device with no entry in it
   * fell back to "whatever this desktop is offering" — its open projects and the
   * folder of every running session. So the observed behaviour was exactly what
   * he reported: six digits typed into a phone, Approve pressed, and every
   * folder immediately reachable. The mechanism existed and was enforced; the
   * flow that would have closed it was optional and elsewhere.
   *
   * Now the kind and the folders are written **first** and the approval last, so
   * there is no instant, however short, in which the device is admitted with
   * nothing decided about it. That ordering is the property, not a tidiness
   * preference: `RemoteAuth.verify` is what a connection waits on, and it starts
   * answering yes the moment the third write lands.
   *
   * A malformed request approves nothing. It is an IPC channel from this app's
   * own window, so this should not happen — and "should not happen" is precisely
   * when a handler that half-completed would leave a device admitted with no
   * kind, which reads as a guest with no folders and looks to its owner like a
   * device that paired and then broke.
   */
  ipcMain.handle(
    'remote:device:approve',
    (_event, id: unknown, kind: unknown, folders: unknown, accountMode: unknown, accounts: unknown): Device[] => {
      if (typeof id !== 'string' || id === '') return auth.listDevices()
      const decided = asDeviceKind(kind)
      if (decided === null) return auth.listDevices()
      // Refused rather than overwritten: a kind is decided once, and a second
      // approval naming a different one is either a stale window or a mistake.
      // Either way the answer is the same and it is not "quietly promote it".
      if (!deps.kinds.claim(id, decided)) return auth.listDevices()
      if (decided === 'guest') {
        // Always written, including an empty list, because an empty list is a
        // real answer — "this guest may reach nothing yet" — and it is the
        // *absence* of a record that used to mean "everything". A guest approved
        // without choosing a folder now has a row saying so rather than a hole
        // that reads as consent.
        deps.folders.set(id, Array.isArray(folders) ? folders : [])
        /*
         * And which of this machine's logins it may use, written under the same
         * rule and for the same reason.
         *
         * Asad, 2026-08-21: *"Maybe we can give one selection step when we give
         * access to any remote device… If they wants to give access of the
         * accounts too, so they can give it."* An absent record here means
         * *every login*, exactly as an absent folder record used to mean every
         * folder — so a guest approved without an answer must get a written one,
         * and the written one is `selected` with nothing in it. That is the
         * fail-closed direction, and it is the direction the folder half of this
         * handler was fixed in after he watched a device paired with six digits
         * reach every project on the machine.
         */
        deps.accountGrants?.set(id, accountMode === 'all' ? 'all' : 'selected', Array.isArray(accounts) ? accounts : [])
      } else {
        // One of your own has no list. `device-reach.ts` never consults it for a
        // `mine` device, and leaving a stale one behind would be a set of
        // folders in the file that nothing reads and that would come back to
        // life if the kind were ever mis-read.
        deps.folders.forget(id)
        // And no login list, for the same reason and on the same argument.
        // *"My device — full access. It's you at another keyboard."* There is
        // nothing to choose, so there is nothing to store, and a row left behind
        // would be a narrowing that nothing reads until somebody mis-reads a
        // kind.
        deps.accountGrants?.forget(id)
      }
      auth.approveDevice(id)
      /*
       * And every other surface is told the wait is over.
       *
       * The window that pressed Approve gets the roster back as this call's
       * answer and needs nothing else. The *other* surfaces do: the bell counts
       * devices waiting for approval, and a badge that clears only when
       * something else happens to make it re-read is a badge that says a person
       * is still waiting after they have been let in. Approving in Settings must
       * put the bell out, and this is the only moment that knows it happened.
       */
      announceRemoteChange()
      return auth.listDevices()
    },
  )

  /**
   * Which devices are yours and which are guests, for the panel.
   *
   * Read-only. There is deliberately no channel that changes a kind — see
   * `device-kind.ts`. The only way a device's kind changes is revoke and pair
   * again, and the screen says that in words rather than offering a control it
   * would refuse.
   */
  ipcMain.handle('remote:kinds', (): DeviceKindRecord[] => deps.kinds.list())
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
      // And its session ticks, for the same reason and on the same argument:
      // the id can never be issued again, so the row could never be reached.
      deps.sessionGrants?.forget(id)
      // And its login ticks, on the same argument once more.
      deps.accountGrants?.forget(id)
      // And its window grant. The same garbage-collection argument, and the one
      // where a row left behind matters most: an id still in that set is a
      // permission to move this person's browser with nobody attached to it.
      deps.windowGrants?.forget(id)
      /*
       * Nothing to forget for the copilot any more, and that is worth a line
       * rather than a silence.
       *
       * There used to be a `copilotLinks.forget(id)` here, garbage-collecting a
       * stored credential that could never be reached again. Since 2026-08-19
       * there is no such record: copilot access is derived from the device's
       * kind, and the kind is dropped two lines below. `dropDevice` above has
       * already stopped the run and dropped its MCP token, so the revocation is
       * complete before this comment ends.
       */
      /*
       * And its kind, which is what makes re-pairing the way to change one.
       *
       * Same garbage-collection argument as the two above — a revoked device id
       * is never reachable again — and one extra consequence worth naming: this
       * is the *only* thing that ever removes a kind, so "revoke, pair again,
       * choose again" is not a workaround for a missing toggle, it is the
       * supported path and the file has no other door.
       */
      deps.kinds.forget(id)
      /*
       * And the announcement, for the same reason approval makes one: Deny is
       * how a waiting device is answered *no*, and a bell that went on counting
       * a device somebody had already refused would be a count nothing could
       * clear. Inside the `if`, unlike approval's, because `revokeDevice`
       * answers false for a device that was already revoked and there is
       * nothing to announce about a no-op.
       */
      announceRemoteChange()
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

  /**
   * Which of the running sessions each device may see, and the one write.
   *
   * The second axis, asked for on 2026-08-20: *"when we give remote access we
   * should be able to choose between running sessions which ones to give and
   * which ones not, i mean select vs all type of options"*. `session-grants.ts`
   * holds the store; the enforcement is the same `visible` predicate every verb
   * already goes through, so there is nothing new to lock here.
   *
   * Three channels rather than two, because the panel needs the sessions to draw
   * ticks against and the renderer has no list of this machine's terminals — the
   * settings window is a different tree from the one holding the rail.
   * `deps.sessions.list()` is the same call the wire is answered from, hidden
   * sessions already removed, so the panel cannot offer a tick for a session no
   * device could ever be given.
   *
   * Devices with no row simply do not appear, the same way the folder channel
   * leaves them out: "not narrowed" and "narrowed to everything" behave alike
   * and are not the same fact, and inventing a row here would make the panel
   * unable to tell them apart.
   */
  /**
   * Which of this machine's logins each device may use, and the one write that
   * changes them.
   *
   * The third axis, asked for on 2026-08-21: *"he can choose if he wants to give
   * multiple or one or whatever."* `account-grants.ts` holds the store; the
   * enforcement is the filter and the refusal inside `accountServe`, which every
   * account frame already goes through, so there is nothing new to lock here.
   *
   * Two channels rather than three: the panel draws its tick list from this
   * machine's own accounts, which the settings window already reads through
   * `profiles:list` for the pane six inches away. A second list served from here
   * would be a second answer to "what logins does this computer have".
   *
   * Devices with no row simply do not appear, the same way the other two grant
   * channels leave them out: "not narrowed" and "narrowed to everything" behave
   * alike and are not the same fact.
   *
   * ## What a narrowing does to a device that is already connected
   *
   * The *rule* is live immediately — the filter is asked per frame, so a login
   * unticked here is gone from the next read and refused on the next switch,
   * with a sentence. What does **not** change until that device reconnects is
   * the capability it was told about at `hello`: narrowing a device to no logins
   * at all leaves its chip drawn until then, and every press on it refused. That
   * is the same shape `web` has and is stated here rather than papered over,
   * because the alternative — dropping a connected device's sockets to correct a
   * capability — would take every terminal on it down to change a preference.
   */
  ipcMain.handle('remote:accounts', (): DeviceAccountGrant[] => deps.accountGrants?.list() ?? [])
  ipcMain.handle(
    'remote:accounts:set',
    (_event, id: unknown, mode: unknown, accounts: unknown): DeviceAccountGrant[] => {
      const store = deps.accountGrants
      if (!store) return []
      if (typeof id !== 'string' || id === '') return store.list()
      store.set(id, mode, Array.isArray(accounts) ? accounts : [])
      return store.list()
    },
  )

  /**
   * The fourth axis: which devices may act on the browser windows in this app.
   *
   * One boolean per device rather than a mode and a list, because there is
   * nothing to narrow — a window is not a folder or a login, it is *the browser
   * on this screen*, and the only two answers are yes and no. The channel
   * therefore answers the set of ids that are allowed, and everything not in it
   * is not.
   *
   * ## What a change does to a device that is already connected
   *
   * It lands on the very next call, both ways. Unlike the three axes above it,
   * nothing about this grant is baked into the capability list a device was told
   * at `hello`: `hostWindows` says only that this machine speaks the frames, and
   * `window-serve.ts` reads the grant per call. So ticking this reaches a device
   * that is already connected, and unticking it stops the next verb rather than
   * the next connection. That is the property `TokenGrant.caller` argues for and
   * it is the one that makes a switch over somebody's browser worth having.
   */
  /*
   * The channel answers the **effective** set — every paired device for which
   * `drives` says yes — rather than the store's raw yes list. The two stopped
   * being the same sentence when the default became the kind's: a device
   * approved as one of the owner's own drives with no row in the file at all,
   * and a panel reading the raw list would draw it unticked while its verbs
   * landed — a control showing a state nothing behind it holds, the defect
   * this round is about. Devices the roster no longer knows are not named
   * either way; `forget` already clears their rows.
   */
  const effectiveWindowGrants = (): string[] => {
    const store = deps.windowGrants
    if (!store) return []
    return auth
      .listDevices()
      .map((device) => device.id)
      .filter((id) => store.drives(id))
  }
  ipcMain.handle('remote:windows', (): string[] => effectiveWindowGrants())
  ipcMain.handle('remote:windows:set', (_event, id: unknown, allowed: unknown): string[] => {
    const store = deps.windowGrants
    if (!store) return []
    store.set(id, allowed === true)
    return effectiveWindowGrants()
  })

  ipcMain.handle('remote:sessions', (): DeviceSessionGrant[] => deps.sessionGrants?.list() ?? [])
  ipcMain.handle('remote:sessions:running', (): RemoteSession[] => deps.sessions.list())
  ipcMain.handle(
    'remote:sessions:set',
    (_event, id: unknown, mode: unknown, sessions: unknown): DeviceSessionGrant[] => {
      const store = deps.sessionGrants
      if (!store) return []
      if (typeof id !== 'string' || id === '') return store.list()
      store.set(id, mode, Array.isArray(sessions) ? sessions : [])
      /*
       * Immediately, on a device that is already connected — his fourth
       * sentence about this feature.
       *
       * The *rule* is live without this: `visible` is asked per frame and per
       * keystroke, so an untick has already taken the keyboard away by the time
       * this line runs. What this does is take the row off the phone's screen in
       * the same moment rather than at its next reconnection, which is the
       * difference between a setting that works and a setting somebody has to be
       * told to reconnect for.
       *
       * `sessionsChanged` rather than a per-device frame, because it already
       * sends every connection its own `sessionsFor` list — one device's choice
       * changing cannot alter another's list, and sending each one what it is
       * entitled to is cheaper than a second code path that has to remember to.
       */
      server.sessionsChanged()
      return store.list()
    },
  )

  /**
   * Which of your devices reach the copilot.
   *
   * **One channel now, and it only reads.** There were four until 2026-08-19 —
   * list, mint a code, disconnect, set tiers — because copilot access was a
   * separate connection with its own credential and its own record. It is not
   * any more: a device's kind decides it, a kind is chosen when the device is
   * approved, and there is deliberately no way to change one without pairing
   * again. `copilot-access.ts` carries that argument in full, including the one
   * it superseded.
   *
   * So there is nothing here to write. Minting a code would mint nothing;
   * disconnecting would have to un-decide a kind, which `device-kind.ts` has no
   * method for on purpose; and setting tiers would be a tick box pretending to
   * be an authorisation, which is the exact shape the separate connection was
   * built to replace. The remedy for a device you no longer trust is
   * `remote:device:revoke`, which already exists and takes everything with it.
   *
   * Derived from the roster rather than stored, so a device approved a second
   * ago appears without anything having been written to disk.
   */
  ipcMain.handle(
    'remote:copilot',
    (): CopilotReach[] => deps.copilotLinks?.list(auth.listDevices().map((device) => device.id)) ?? [],
  )

  return { server, auth, desk }
}
