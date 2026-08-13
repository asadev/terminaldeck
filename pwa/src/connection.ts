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

import { Backoff, type BackoffOptions } from './backoff'
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

/* ---------------------------------------------------------------- state -- */

export type ConnectionPhase =
  | 'offline'
  | 'connecting'
  | 'online'
  /** Paired, but a human at the Mac has not approved this device yet. */
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
  private approvalDetail = 'Waiting for approval on the Mac.'
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

  start(): void {
    if (!this.stopped) return
    this.stopped = false
    this.connect()
  }

  /** Deliberate teardown. No retry follows one of these. */
  stop(): void {
    this.stopped = true
    this.awaitingApproval = false
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
    if (this.awaitingApproval) this.set('pending', this.approvalDetail, null)
    else this.set('connecting', 'Connecting…', null)

    let socket: SocketLike
    try {
      socket = this.open(this.options.url)
    } catch {
      // `new WebSocket` throws synchronously on a URL the browser will not
      // accept — a mixed-content ws:// from an https page, most likely.
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
      this.scheduleRetry(closeReason(event.code, this.greeted))
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
    // window between it dying on the Mac and the client hearing about it.
    //
    // A refusal that really is about the device always arrives with the socket
    // closing behind it, so the state is reached on the next attempt instead,
    // one backoff step later, with the desktop's own sentence intact.
    if (message.t === 'error' && !this.greeted) {
      if (message.code === 'unauthenticated') {
        this.fatal('rejected', message.message || 'This device is not paired with that Mac any more.')
        return
      }
      if (message.code === 'unauthorized') {
        // Paired but not approved. The fix is a person walking to the Mac, so
        // this keeps trying — slowly — rather than declaring failure at someone
        // who is three metres from the button. The backoff doubles as the poll
        // interval.
        this.awaitingApproval = true
        if (message.message !== '') this.approvalDetail = message.message
        this.closeSocket(1000, 'awaiting approval')
        this.scheduleRetry(this.approvalDetail)
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
    const delay = this.backoff.next()
    const retryAt = this.clock.now() + delay
    // Pending survives a reconnect: the device is still waiting for approval,
    // and flipping the banner back to a generic "connection lost" would lose
    // the one sentence that tells the user what to actually do.
    if (this.awaitingApproval) this.set('pending', this.approvalDetail, retryAt)
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
 */
export function closeReason(code: number, greeted: boolean): string {
  switch (code) {
    case 1000:
    case 1001:
      return greeted ? 'The desktop closed the connection.' : 'The desktop closed the connection before pairing finished.'
    case 1002:
    case 1003:
      return 'The desktop rejected a message from this client.'
    case 1008:
      return 'The desktop refused this device.'
    case 1009:
      return 'A message was too large for the desktop to accept.'
    case 1013:
      return 'The desktop asked this client to try again later.'
    case 1011:
      return 'The desktop hit an internal error.'
    default:
      return greeted
        ? 'Connection lost.'
        : 'Could not reach the desktop. Check that it is awake and on the same tailnet.'
  }
}
