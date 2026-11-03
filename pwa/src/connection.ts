/**
 * The socket, and the honest story about what it is doing.
 *
 * ## The rule this module exists to obey
 *
 * There is exactly one thing this client must never do, and it is to show a
 * terminal that looks connected when it is not. A phone terminal is used to
 * check on something long-running and to stop it when it goes wrong; a screen
 * of stale output with a live-looking cursor is worse than no client at all,
 * because a person will type Ctrl+C into it and walk away believing the job
 * stopped.
 *
 * So: every transition ends in a state with a sentence attached, `send` refuses
 * rather than buffers when the socket is not up, and the app clears the
 * terminal on re-attach instead of leaving the old pixels under a new
 * connection.
 *
 * ## Why there is a heartbeat
 *
 * A TCP connection through a phone's NAT, a carrier's middlebox and a WireGuard
 * tunnel can be dead on the wire while `readyState` still says OPEN — nothing
 * tells the client until it tries to write and the write does not land. That is
 * the fake-connected terminal in its most convincing form, so the client pings
 * and holds the connection to account for a pong.
 *
 * ## Testing
 *
 * The socket and the clock are both constructor arguments. Nothing here touches
 * `WebSocket`, `window` or `Date` directly, which is what lets the reconnect
 * schedule be tested by moving a fake clock rather than by waiting.
 */

import { BRAND } from '../../src/shared/brand'
import { Backoff, type BackoffOptions } from './backoff'
import { answerCredential, credentialNotice, type CredentialNotice } from './credential'
import { machineNoun, readHostPlatform, type HostPlatform } from './host-platform'
import {
  decodeServerMessage,
  encode,
  helloMessage,
  PROTOCOL_VERSION,
  type ClientMessage,
  type DeviceDescriptor,
  type ServerMessage,
} from './protocol-client'

/* ------------------------------------------------------------- injected -- */

export interface SocketLike {
  send(data: string): void
  close(code?: number, reason?: string): void
  onopen: (() => void) | null
  onmessage: ((event: { data: unknown }) => void) | null
  onclose: ((event: { code: number; reason: string }) => void) | null
  onerror: (() => void) | null
}

export interface Clock {
  now(): number
  /** Schedule `fn`, and return the function that cancels it. */
  after(ms: number, fn: () => void): () => void
}

export const systemClock: Clock = {
  now: () => Date.now(),
  after(ms, fn) {
    const handle = setTimeout(fn, ms)
    return () => clearTimeout(handle)
  },
}

/**
 * A real browser socket behind `SocketLike`.
 *
 * The adapter is here rather than a direct `WebSocket` because `WebSocket`'s
 * handler signatures carry `MessageEvent` and `CloseEvent`, and depending on
 * those would drag a DOM into every test of the reconnect logic.
 */
export function browserSocket(url: string): SocketLike {
  const socket = new WebSocket(url)
  const adapter: SocketLike = {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    onopen: null,
    onmessage: null,
    onclose: null,
    onerror: null,
  }
  socket.onopen = () => adapter.onopen?.()
  socket.onmessage = (event) => adapter.onmessage?.({ data: event.data })
  socket.onclose = (event) => adapter.onclose?.({ code: event.code, reason: event.reason })
  socket.onerror = () => adapter.onerror?.()
  return adapter
}

/**
 * Close codes this client invents for itself.
 *
 * The 4000–4999 range is the one the WebSocket spec leaves to applications, and
 * these are the reasons a *sealed* channel ends that a plain socket has no code
 * for: a handshake reply that could not be opened, a build that cannot run the
 * crypto, a relay that answered with something else entirely. `relay-socket.ts`
 * is the only thing that raises them and `closeReason` below is the only thing
 * that reads them, which is why they live here rather than there — the wording
 * of every close in this client is decided in one place.
 *
 * A hostile relay can also send a code in this range on a real close frame. It
 * would get a slightly wrong sentence for its trouble and nothing else: nothing
 * here branches on a close code except to choose words, and the relay's own code
 * is not passed through in any case — see the note in `relay-socket.ts`.
 */
export const CHANNEL_CLOSE = {
  /** The relay dropped the channel before the handshake finished. */
  relayUnreached: 4001,
  /** It dropped after. */
  relayLost: 4002,
  /** The far end could not prove it holds the key this device paired against. */
  sealedRefused: 4003,
  /** The crypto could not run at all. Not the far end's fault. */
  sealedFault: 4004,
  /** Two builds of the sealed channel that do not speak the same framing. */
  sealedVersion: 4005,
  /** Something answered that is not this protocol. */
  malformed: 4006,
} as const

/**
 * How this client is reaching the machine, which decides one sentence.
 *
 * `direct` is a socket to an address the browser can already open — the tailnet
 * shape this client began as. `relay` is the sealed channel every other client
 * in the product uses. The only thing above that depends on it is what to
 * suggest when a connection cannot be made at all, and suggesting a tailnet to
 * somebody who has never installed one is worse than saying nothing.
 */
export type Reach = 'direct' | 'relay'

/* ---------------------------------------------------------------- state -- */

export type ConnectionPhase =
  | 'offline'
  | 'connecting'
  | 'online'
  /** Paired, but a human at the desktop has not approved this device yet. */
  | 'pending'
  /** A retry is scheduled. `retryAt` says when. */
  | 'waiting'
  /** The credential was refused. Only re-pairing fixes this, so retrying stops. */
  | 'rejected'
  /** The two ends do not speak the same protocol version. Retrying stops. */
  | 'incompatible'

export interface ConnectionState {
  phase: ConnectionPhase
  /** A sentence for the banner. Always present, always true. */
  detail: string
  /** Epoch ms of the next attempt, when one is scheduled. */
  retryAt: number | null
  /** Consecutive failed attempts. Shown once it stops looking like a blip. */
  attempts: number
}

export interface ConnectionHandlers {
  onState(state: ConnectionState): void
  /** `activity` accompanies a session list when the desktop timestamps its rows. */
  onMessage(message: ServerMessage, activity?: ReadonlyMap<string, number>): void
  /**
   * A durable credential arrived. Persist it — the pairing token that bought it
   * is now spent and will not work a second time.
   */
  onCredential(token: string): void
  /**
   * A machine asked this browser for a GitHub login, and it has already been
   * acknowledged and refused — see the header of `credential.ts`.
   *
   * Optional because the answer does not depend on anybody listening: the two
   * frames go out whether or not this is set, which is what keeps "acknowledge
   * every request" a property of the transport rather than of the screen. What a
   * listener adds is the person finding out it happened, which matters because a
   * refusal nobody sees is indistinguishable from a broken feature.
   */
  onCredentialAsked?(notice: CredentialNotice): void
}

export interface ConnectionOptions {
  url: string
  /** A pairing token on the first connection, the stored credential after that. */
  token: string
  device: DeviceDescriptor
  handlers: ConnectionHandlers
  open?: (url: string) => SocketLike
  clock?: Clock
  backoff?: BackoffOptions
  random?: () => number
  /**
   * Which of the two routes this connection is, for one sentence's sake.
   *
   * Defaults to `direct` because that is what this client was before the relay,
   * and a caller that has not been updated should keep getting the wording it
   * used to.
   */
  reach?: Reach
}

/* ------------------------------------------------------------ heartbeat -- */

/**
 * Well under the 30 seconds after which idle NAT and proxy table entries start
 * being reclaimed, so the socket is never idle long enough to be collected.
 */
const PING_EVERY_MS = 25_000

/** A pong crosses a tailnet in milliseconds. Ten seconds is a dead socket. */
const PONG_GRACE_MS = 10_000

/**
 * Longest a socket may sit there without the desktop answering the `hello`.
 *
 * Nothing else bounds this state. The heartbeat does not start until the
 * welcome arrives, and `resume` refuses to act while the phase is "connecting",
 * so a peer that completes the WebSocket upgrade and then says nothing —
 * a captive portal, a middlebox holding the connection open, a desktop wedged
 * mid-verification — left this client on "Connecting…" for as long as the
 * browser's own TCP timeout, with the retry button hidden because a retry was
 * supposedly already in flight. The real desktop closes an unauthenticated
 * socket after eight seconds, so this only ever fires against something that is
 * not it.
 */
const HANDSHAKE_TIMEOUT_MS = 15_000

/**
 * How long this client keeps knocking after a machine says "not allowed in".
 *
 * ## The state this bounds
 *
 * A device that has paired but not been approved is refused with `unauthorized`
 * before the handshake, and the fix is a person walking to the machine and
 * pressing a button — so this client keeps trying, and the backoff doubles as
 * the poll. That is right, and it was unbounded.
 *
 * The reason it cannot stay unbounded is that **a revoked device is refused with
 * the same code**. `authenticatorFor` in `src/main/remote/server.ts` deliberately
 * collapses `pending`, `revoked` and "your key does not match" into one answer,
 * because telling a remote caller which one it hit is a free oracle — a good
 * decision, and it leaves this client unable to tell "walk over and approve me"
 * from "you were thrown out". So a browser somebody revoked from the desktop —
 * the safety net for a pairing left on a computer that is not theirs — sat there
 * reconnecting every twenty seconds, for as long as the tab stayed open, with a
 * banner that read as though approval were still coming.
 *
 * ## Why a timer is the honest answer and not a guess
 *
 * Because the two cases stop differing after a while. Approval happens in the
 * minute or two it takes to look at a screen somebody is standing in front of;
 * an hour of continuous refusal is not an approval running late. Knocking past
 * that point is battery on this side, an accept-and-scrypt on the other, and a
 * banner that keeps promising something.
 *
 * What it does **not** do is discard the credential. This client genuinely does
 * not know which refusal it got, and throwing away a good credential because
 * somebody was slow would be inventing certainty it does not have. It stops,
 * says so, and leaves the retry button — which `resume` also restarts on the
 * tab becoming visible, so coming back to it is the same as pressing it.
 */
const APPROVAL_PATIENCE_MS = 60 * 60_000

/* ----------------------------------------------------------------- main -- */

export class Connection {
  private socket: SocketLike | null = null
  private cancelRetry: (() => void) | null = null
  private cancelHeartbeat: (() => void) | null = null
  private cancelHandshake: (() => void) | null = null
  private awaitingPong = false
  private stopped = true
  private greeted = false
  /**
   * The device is paired but not approved, and every reconnect from here is a
   * poll for that approval.
   *
   * Held as its own flag rather than read back off `state.phase`, because
   * `connect` overwrites the phase with "connecting" — which is how an earlier
   * version lost the one sentence telling the user to go and press the button,
   * roughly half a second after showing it.
   */
  private awaitingApproval = false
  /**
   * When the current run of refusals started, so it can be given up on.
   *
   * Null whenever nothing is being waited for. Reset by `resume` rather than
   * only by success: somebody bringing the tab forward is somebody who thinks
   * it is worth trying again, and this client has no better information than
   * that. See {@link APPROVAL_PATIENCE_MS}.
   */
  private approvalSince: number | null = null
  /**
   * The desktop's own words for the approval wait, when it sent any.
   *
   * Null rather than a pre-filled sentence, because the fallback has to be
   * composed at the moment it is read: the noun in it depends on `platform`
   * below, and a string built in a field initialiser would have been built
   * before a single frame arrived — which is how this client came to tell a
   * Windows user to go and approve a device on "the Mac".
   */
  private approvalDetail: string | null = null
  /**
   * What kind of machine this socket is talking to, once it has said.
   *
   * Sticky for the life of the connection rather than reset on each attempt: a
   * machine does not change operating system between one reconnect and the next,
   * and the sentences that most need the right noun are the ones printed *after*
   * a socket has dropped. It starts at `unknown`, so a desktop that predates the
   * field — or one that has not answered yet — gets a neutral word instead of a
   * guess.
   */
  private platform: HostPlatform = 'unknown'
  private token: string
  private readonly open: (url: string) => SocketLike
  private readonly clock: Clock
  private readonly backoff: Backoff
  private state: ConnectionState = {
    phase: 'offline',
    detail: 'Not connected.',
    retryAt: null,
    attempts: 0,
  }

  constructor(private readonly options: ConnectionOptions) {
    this.token = options.token
    this.open = options.open ?? browserSocket
    this.clock = options.clock ?? systemClock
    this.backoff = new Backoff(options.backoff, options.random)
  }

  current(): ConnectionState {
    return this.state
  }

  /**
   * What kind of machine is on the other end, as far as this socket knows.
   *
   * `unknown` until a `welcome` says otherwise, and `unknown` forever against a
   * desktop old enough not to send the field. Callers turn it into a noun with
   * `machineNoun`; nothing here returns display text, because the same value
   * has to serve a heading, a button and a sentence.
   */
  hostPlatform(): HostPlatform {
    return this.platform
  }

  start(): void {
    if (!this.stopped) return
    this.stopped = false
    this.connect()
  }

  /** Deliberate teardown. No retry follows one of these. */
  stop(): void {
    this.stopped = true
    this.awaitingApproval = false
    this.approvalSince = null
    this.clearTimers()
    this.closeSocket(1000, 'client closed')
    this.set('offline', 'Not connected.', null)
  }

  /**
   * Try again now.
   *
   * Called when the OS says the network is back or the tab becomes visible. At
   * that moment the pending delay is describing a condition that has already
   * ended, and making someone watch out an 18-second timer while their wifi
   * bars are full is how an app earns a reputation for being slow.
   *
   * Refused in the two terminal states: a refused credential and a version
   * mismatch do not become true again because the phone came out of a pocket,
   * and `auth.ts` locks a device out for fifteen minutes after five failed
   * credential attempts, so retrying one is actively harmful.
   */
  resume(): void {
    if (this.stopped) return
    if (this.state.phase === 'rejected' || this.state.phase === 'incompatible') return
    if (this.state.phase === 'online' || this.state.phase === 'connecting') return
    this.backoff.reset()
    // A fresh hour of patience, because this is somebody saying "try again" —
    // by pressing the button, by bringing the tab forward, or by the network
    // coming back. Carrying the old clock forward would leave a client that gave
    // up an hour ago unable to be told to start over without a reload.
    this.approvalSince = null
    this.connect()
  }

  /**
   * Send, or say no.
   *
   * Never queues. A keystroke buffered while the socket is down arrives after
   * the reconnect, out of context, at a prompt that has moved on — and the user
   * saw it echo locally and believed it landed. Refusing lets the caller tell
   * the truth instead.
   */
  send(message: ClientMessage): boolean {
    if (this.socket === null || this.state.phase !== 'online') return false
    try {
      this.socket.send(encode(message))
      return true
    } catch {
      // A write that throws means the socket is already gone; the close handler
      // has either run or is about to.
      return false
    }
  }

  /* --------------------------------------------------------- internals -- */

  /**
   * What the banner says while a human is being waited on.
   *
   * The desktop's own sentence when it sent one — it knows more than this client
   * does about why it refused — and otherwise a sentence composed here, now,
   * with whatever noun is currently justified. Composed on every read rather
   * than stored, because `platform` can become known *after* the first refusal:
   * a desktop that mints a credential and then refuses sends the `welcome`
   * carrying `hostPlatform` first, so a sentence frozen at the moment the
   * refusal arrived would be one frame too early to be right.
   */
  private approvalSentence(): string {
    return this.approvalDetail ?? `Waiting for approval on the ${machineNoun(this.platform)}.`
  }

  private set(phase: ConnectionPhase, detail: string, retryAt: number | null): void {
    this.state = { phase, detail, retryAt, attempts: this.backoff.attempts }
    this.options.handlers.onState(this.state)
  }

  private connect(): void {
    this.clearTimers()
    this.closeSocket(1000, 'reconnecting')
    this.greeted = false
    // While waiting for approval the reconnects are the poll, and flipping the
    // banner to "Connecting…" every few seconds would bury the instruction.
    if (this.awaitingApproval) this.set('pending', this.approvalSentence(), null)
    else this.set('connecting', 'Connecting…', null)

    let socket: SocketLike
    try {
      socket = this.open(this.options.url)
    } catch {
      // `new WebSocket` throws synchronously on a URL the browser will not
      // accept — a mixed-content ws:// from an https page, most likely. Nothing
      // else reaches here: `relay-socket.ts` deliberately does not throw for a
      // handshake it could not build, because that is not an address problem and
      // this sentence would be a lie about one.
      this.scheduleRetry('That address cannot be opened from this page.')
      return
    }
    this.socket = socket

    socket.onopen = () => {
      // Open is not connected. The server has not authenticated us yet, and
      // saying "online" here would light the terminal up before the desktop has
      // agreed to talk to this device at all.
      socket.send(encode(helloMessage(this.token, this.options.device)))
    }

    socket.onmessage = (event) => {
      if (typeof event.data !== 'string') {
        // The protocol is JSON text. A binary frame is something else entirely
        // — most likely not our server on the other end.
        this.fail('The server sent something this client does not understand.')
        return
      }
      this.receive(event.data)
    }

    socket.onerror = () => {
      // Browsers deliberately give no detail here, to avoid leaking whether a
      // host exists. The close event that follows carries what there is.
    }

    socket.onclose = (event) => {
      if (this.socket !== socket) return
      this.socket = null
      this.clearHeartbeat()
      if (this.stopped) return
      if (this.state.phase === 'rejected' || this.state.phase === 'incompatible') return
      this.scheduleRetry(
        closeReason(event.code, this.greeted, machineNoun(this.platform), this.options.reach ?? 'direct'),
      )
    }

    this.cancelHandshake = this.clock.after(HANDSHAKE_TIMEOUT_MS, () => {
      this.cancelHandshake = null
      if (this.greeted) return
      this.fail('The desktop accepted the connection but never answered.')
    })
  }

  private receive(raw: string): void {
    const decoded = decodeServerMessage(raw)
    if (!decoded.ok) {
      // Not fatal on its own — a message type added on the desktop side arrives
      // here as garbage until this client is updated, and dropping it is better
      // than dropping the session.
      return
    }
    const message = decoded.message

    if (message.t === 'welcome') {
      // Read before the version check, and before anything decides whether this
      // welcome is an admission. It is a fact about the machine, true even of a
      // desktop this client is about to refuse to talk to — and the refusal is
      // one of the sentences that wants the right noun in it.
      this.platform = readHostPlatform(message.hostPlatform)
      if (message.protocol !== PROTOCOL_VERSION) {
        this.fatal(
          'incompatible',
          `The desktop speaks protocol ${message.protocol} and this client speaks ${PROTOCOL_VERSION}. Update whichever is older.`,
        )
        return
      }
      if (message.token !== null) {
        // Swap immediately. The pairing token is single-use and already spent;
        // reconnecting with it would be refused and would count against the
        // failed-attempt limiter.
        this.token = message.token
        this.options.handlers.onCredential(message.token)
      }
      this.greeted = true
      this.clearHandshake()
      this.awaitingApproval = false
      this.approvalSince = null
      this.backoff.reset()
      this.set('online', 'Connected.', null)
      this.startHeartbeat()
      this.options.handlers.onMessage(message, decoded.activity)
      return
    }

    // Only before the handshake has completed is an `error` frame about *this
    // device*. The desktop spends the same `unauthorized` code on in-session
    // refusals — "Attach to that session before typing into it", which it sends
    // without closing the socket — and reading one of those as "not approved
    // yet" tore a working connection down and put a pairing instruction on
    // screen over a live session. It is reachable: type into a session in the
    // window between it dying on the desktop and the client hearing about it.
    //
    // A refusal that really is about the device always arrives with the socket
    // closing behind it, so the state is reached on the next attempt instead,
    // one backoff step later, with the desktop's own sentence intact.
    if (message.t === 'error' && !this.greeted) {
      if (message.code === 'unauthenticated') {
        this.fatal(
          'rejected',
          message.message || `This device is not paired with that ${machineNoun(this.platform)} any more.`,
        )
        return
      }
      if (message.code === 'unauthorized') {
        // Paired but not approved — or revoked, or presenting a key the machine
        // does not know, all of which arrive here identically on purpose. The
        // fix for the first is a person walking to the machine, so this keeps
        // trying — slowly — rather than declaring failure at someone who is
        // three metres from the button. The backoff doubles as the poll
        // interval, and `APPROVAL_PATIENCE_MS` is what stops it being forever.
        this.awaitingApproval = true
        this.approvalSince ??= this.clock.now()
        if (message.message !== '') this.approvalDetail = message.message
        this.closeSocket(1000, 'awaiting approval')
        this.scheduleRetry(this.approvalSentence())
        return
      }
      if (message.code === 'version') {
        this.fatal('incompatible', message.message || 'The desktop refused this client’s protocol version.')
        return
      }
    }

    if (message.t === 'pong') {
      this.awaitingPong = false
      return
    }

    /*
     * A machine wants a GitHub login, and this client answers before it draws.
     *
     * Answered here rather than handed up to the app, because the first frame
     * back is the acknowledgement and it is the one thing in this feature that
     * must not wait on anything — not on a render, not on a handler somebody
     * might not have registered. The desktop gives a device a few seconds to say
     * it is there before it decides the device is asleep, and this client *is*
     * there, so it says so within the same tick as the frame arriving.
     *
     * What it can honestly say afterwards is in `credential.ts`, at length: this
     * page is served by the machine that is asking, so a token kept here would
     * be a token that machine could read, and there is no browser storage that
     * changes that. It refuses, and then tells the person what was asked and
     * what to do instead.
     */
    if (message.t === 'credential.request') {
      for (const answer of answerCredential(message)) this.send(answer)
      this.options.handlers.onCredentialAsked?.(credentialNotice(message, this.clock.now()))
      return
    }

    this.options.handlers.onMessage(message, decoded.activity)
  }

  /**
   * A failure this side detected: close and schedule the retry here.
   *
   * `closeSocket` unhooks the handlers first, so the close event never comes
   * back — an earlier version relied on it and left the client sitting in
   * "waiting" with no timer running and nothing to wake it.
   */
  private fail(detail: string): void {
    this.closeSocket(1002, 'protocol error')
    this.scheduleRetry(detail)
  }

  /** A failure retrying cannot fix. */
  private fatal(phase: 'rejected' | 'incompatible', detail: string): void {
    this.clearTimers()
    this.set(phase, detail, null)
    this.closeSocket(1000, phase)
  }

  private scheduleRetry(detail: string): void {
    // Every path to a retry comes through here, so this is the one place that
    // can guarantee there is never more than one in flight — two would double
    // the connection attempts on every subsequent round.
    this.cancelRetry?.()
    this.cancelRetry = null
    this.clearHandshake()

    // An hour of being refused is not an approval running late — see
    // `APPROVAL_PATIENCE_MS`. Stopping leaves the phase at `pending`, which is
    // the one the retry button stays visible in, and keeps the machine's own
    // sentence rather than replacing it with a summary written here.
    if (this.awaitingApproval && this.approvalSince !== null) {
      if (this.clock.now() - this.approvalSince >= APPROVAL_PATIENCE_MS) {
        this.set(
          'pending',
          `${this.approvalSentence()} Nothing has changed in an hour, so this stopped asking. Try again, or pair this browser with the ${machineNoun(this.platform)} once more.`,
          null,
        )
        return
      }
    }

    const delay = this.backoff.next()
    const retryAt = this.clock.now() + delay
    // Pending survives a reconnect: the device is still waiting for approval,
    // and flipping the banner back to a generic "connection lost" would lose
    // the one sentence that tells the user what to actually do.
    if (this.awaitingApproval) this.set('pending', this.approvalSentence(), retryAt)
    else this.set('waiting', detail, retryAt)
    this.cancelRetry = this.clock.after(delay, () => {
      this.cancelRetry = null
      if (!this.stopped) this.connect()
    })
  }

  private startHeartbeat(): void {
    this.clearHeartbeat()
    this.awaitingPong = false
    const beat = (): void => {
      if (this.socket === null) return
      this.awaitingPong = true
      this.send({ t: 'ping' })
      this.cancelHeartbeat = this.clock.after(PONG_GRACE_MS, () => {
        if (this.awaitingPong) {
          this.fail('The connection stopped answering.')
          return
        }
        // The remainder of the cycle, so a ping still leaves every
        // PING_EVERY_MS rather than every ping-plus-grace.
        this.cancelHeartbeat = this.clock.after(PING_EVERY_MS - PONG_GRACE_MS, beat)
      })
    }
    this.cancelHeartbeat = this.clock.after(PING_EVERY_MS, beat)
  }

  private clearHeartbeat(): void {
    this.cancelHeartbeat?.()
    this.cancelHeartbeat = null
    this.awaitingPong = false
  }

  private clearHandshake(): void {
    this.cancelHandshake?.()
    this.cancelHandshake = null
  }

  private clearTimers(): void {
    this.cancelRetry?.()
    this.cancelRetry = null
    this.clearHandshake()
    this.clearHeartbeat()
  }

  private closeSocket(code: number, reason: string): void {
    const socket = this.socket
    if (socket === null) return
    this.socket = null
    socket.onopen = null
    socket.onmessage = null
    socket.onerror = null
    socket.onclose = null
    try {
      socket.close(code, reason)
    } catch {
      // Closing an already-closed socket is not an error worth reporting.
    }
  }
}

/**
 * What to tell the user about a close code.
 *
 * `greeted` matters: the same code means different things before and after the
 * handshake. A close during the handshake is usually the desktop refusing this
 * device; the same code afterwards is usually the tunnel or the wifi.
 *
 * `noun` is what to call the far end — `machineNoun` of whatever the last
 * `welcome` said, which before any welcome is the neutral "desktop" these
 * sentences used to be hardcoded to. It is a required argument rather than one
 * with a default: a default is how a caller silently keeps the generic word
 * after the machine has told us its name, and every one of these sentences is
 * about a specific computer the reader is standing next to.
 *
 * `reach` decides one sentence and it is the sentence this client was wrong
 * about for its whole life. The last line here used to end "…and on the same
 * tailnet", unconditionally, because a tailnet was the only way this client
 * could reach anything. It is now the fallback rather than the requirement, and
 * telling somebody connecting through the relay to check their tailnet is
 * telling them to go and configure a product they have never heard of.
 */
export function closeReason(code: number, greeted: boolean, noun: string, reach: Reach = 'direct'): string {
  switch (code) {
    case CHANNEL_CLOSE.relayUnreached:
      return `Could not reach the ${noun}. It may be asleep, or not signed in to the relay.`
    case CHANNEL_CLOSE.relayLost:
      return greeted ? 'Connection lost.' : `Could not reach the ${noun}. It may be asleep, or not signed in to the relay.`
    case CHANNEL_CLOSE.sealedRefused:
      // Said as a fact about the machine rather than about this device: the
      // handshake proves who is answering, and a far end that cannot open it is
      // one that does not hold the key this browser was paired against.
      return `The ${noun} could not prove it is the one this device paired with. Pair it again.`
    case CHANNEL_CLOSE.sealedFault:
      return 'The sealed handshake could not run in this browser, so nothing was sent.'
    case CHANNEL_CLOSE.sealedVersion:
      return `The ${noun} speaks a different version of the sealed channel. Update whichever build is older.`
    case CHANNEL_CLOSE.malformed:
      return `Something on the way to the ${noun} answered with what is not ${BRAND.name}.`
    case 1000:
    case 1001:
      return greeted
        ? `The ${noun} closed the connection.`
        : `The ${noun} closed the connection before pairing finished.`
    case 1002:
    case 1003:
      return `The ${noun} rejected a message from this client.`
    case 1008:
      return `The ${noun} refused this device.`
    case 1009:
      return `A message was too large for the ${noun} to accept.`
    case 1013:
      return `The ${noun} asked this client to try again later.`
    case 1011:
      return `The ${noun} hit an internal error.`
    default:
      if (greeted) return 'Connection lost.'
      return reach === 'relay'
        ? `Could not reach the ${noun}. Check that it is awake and ${BRAND.name} is running on it.`
        : `Could not reach the ${noun}. Check that it is awake and on the same tailnet.`
  }
}
