/**
 * This desktop, being somebody else's client.
 *
 * ## What this is the other half of
 *
 * `server.ts` is the host: it answers `hello`, decides who may attach, and
 * serves sessions. This file is the guest half of the same conversation — the
 * side a phone has always been — written for the main process so that a Mac can
 * open a session on a PC and the other way round.
 *
 * It is deliberately the *same protocol*. Nothing here is a machine-to-machine
 * dialect: the frames come from `remote/protocol.ts`, the parser is
 * `parseServerMessage` in that same file, and the host cannot tell a paired
 * desktop from a paired phone and does not try to. That is the uniform model
 * this feature is built on — every connected device is a device with folder
 * grants, and the rules are the rules whatever is holding it.
 *
 * ## Reconnecting is the normal state, not the error path
 *
 * A laptop sleeps, changes networks and moves between wifi and a hotspot, and
 * the relay itself restarts on deploys. Every one of those is a dead channel
 * that still looks alive. So a link that is *supposed* to be up redials with
 * exponential backoff and jitter, exactly the way `relay-client.ts` does on the
 * host side, and for the same reasons — including the jitter, because every
 * machine in the world reconnecting in the same millisecond after a relay
 * restart is how a relay gets knocked over twice.
 *
 * The backoff is also what makes approval work without polling anything. A
 * machine that has just paired is refused with "approve this device", and it is
 * already redialling on the same schedule as any other failure; when somebody
 * presses approve on the other machine, the next dial succeeds. There is no
 * timer watching for approval and nothing to switch off when it never comes.
 *
 * ## The one thing this file will not do
 *
 * It never writes to the store. `store.ts` owns what is on disk and `ipc.ts`
 * owns when a pairing is worth remembering; a connection that persisted its own
 * credential would be one that could persist a credential it got from a channel
 * that then failed its seal.
 */

import { hostname } from 'node:os'
import {
  CAPABILITY,
  PROTOCOL_VERSION,
  parseServerMessage,
  serialize,
  type ClientMessage,
  type LocalPort,
  type ProtocolErrorCode,
  type RemoteSession,
} from '../protocol'
import { dialMachine, type GuestChannel, type DialRequest } from './dial'
import type { MachineSecrets } from './store'

/* -------------------------------------------------------------- constants -- */

/** First retry, before jitter. Short enough that a relay deploy is invisible. */
const BASE_BACKOFF_MS = 1000

/**
 * Longest wait between dials. A minute is the point past which somebody
 * watching the panel decides the feature is broken, and short enough that a
 * machine that was off for an hour is picked up within a minute of coming back.
 */
const MAX_BACKOFF_MS = 60_000

/** A link that held this long failed for a new reason, not the old one. */
const STABLE_MS = 60_000

/** How long a `hello` may go unanswered before the channel is not one. */
const WELCOME_TIMEOUT_MS = 15_000

/* ------------------------------------------------------------------ state -- */

/**
 * What the window may say about a machine, and nothing it may not.
 *
 * Five states, and the two in the middle exist because collapsing them lies to
 * somebody. `connecting` and `offline` differ in whether anything is happening;
 * `pairing-approval` and `error` differ in whether the answer is "wait" or
 * "this is broken", and a machine that has just been paired is in the first for
 * as long as it takes a person to walk to the other keyboard.
 */
export type MachineState = 'offline' | 'connecting' | 'awaiting-approval' | 'online' | 'error'

export interface MachineLinkState {
  id: string
  state: MachineState
  /** Why, in a sentence somebody can act on. Null while it is working. */
  reason: string | null
  /** Sessions on that machine, as it last listed them. */
  sessions: RemoteSession[]
  /**
   * Folders that machine will start a session in for this device.
   *
   * Null and `[]` are different answers and the difference is the whole point of
   * the field — see `welcome.folders`. Null means it never said, which is every
   * build older than the field and every host that cannot start sessions at
   * all; `[]` means somebody chose no folders for this device, which is a real
   * state with a real remedy on the other machine.
   */
  folders: string[] | null
  capabilities: string[]
  /**
   * What is listening on **that** machine, as it last answered.
   *
   * The other half of remote localhost, and until now it did not exist on this
   * side at all: `web.open` was on the wire and only the phone sent it, so a Mac
   * could see a PC's sessions and had no idea what that PC was serving. His
   * words for the gap are about the row rather than the list — *"remote
   * localhost should list the remote machine's ports with the machine's icon"* —
   * and the icon is the panel's job; this is the list it draws.
   *
   * Empty for a machine that has not answered and for one that is genuinely
   * serving nothing, which is a distinction this field deliberately does not
   * make: the panel already knows whether the link is online, and a third state
   * here would be a second source of truth for the same fact.
   *
   * Asked once per connection, on the `welcome`, and not polled. A port list is
   * a scan of a process table on somebody else's machine — see
   * `feedback_events_not_polling`: the desktop pushes what it wants watched, and
   * this is a question rather than a subscription.
   */
  ports: LocalPort[]
  /** `darwin`, `win32`, `linux`, or empty. Never guessed. */
  hostPlatform: string
  /** When the next dial is due, epoch ms, or null when one is not scheduled. */
  retryAt: number | null
}

export interface MachineLink {
  /** Begin dialling, and keep dialling. Safe to call twice. */
  connect(): void
  /** Stop, drop the channel, and stay stopped. Safe to call twice. */
  disconnect(): void
  state(): MachineLinkState
  /** Ask for a session's screen. `cols`/`rows` travel so the first paint fits. */
  attach(sessionId: string, cols: number, rows: number): boolean
  detach(sessionId: string): boolean
  input(sessionId: string, data: string): boolean
  resize(sessionId: string, cols: number, rows: number): boolean
  /** Start a session over there. Refused unless that machine advertised `create`. */
  create(request: { cwd?: string; provider?: string; resume?: boolean }): boolean
  /** Ask again what is listening over there. Refused unless it advertised `localhost`. */
  ports(): boolean
  /**
   * Open a page **on that machine**, in its own browser.
   *
   * The half of remote localhost this desktop could not do. A tunnel would bring
   * the page here and this end opens no listener; what it can do is drive — ask
   * the far machine to put the page on its own screen, which is the same verb
   * the phone sends and the same one his review asked for on every surface.
   *
   * Refused unless that machine advertised `web`, which it withholds from a host
   * with no window and from a device it treats as a guest. So a button drawn off
   * this capability is never a button that discovers it does not work.
   */
  openThere(url: string): boolean
  /** The machine woke up. Redial now rather than waiting out the backoff. */
  wake(): void
}

export interface MachineLinkOptions {
  id: string
  secrets: MachineSecrets
  /** Told on every change, including the ones nobody asked for. */
  onState(state: MachineLinkState): void
  /** One chunk of a session's screen. `replay` marks scrollback. */
  onOutput(sessionId: string, data: string, replay: boolean): void
  /** A `welcome` landed. The store records the connection and the platform. */
  onWelcome(hostPlatform: string): void
  now?: () => number
  /** Seams for the tests, so nothing here dials the public internet. */
  dial?: (request: DialRequest) => Promise<GuestChannel>
  baseBackoffMs?: number
  maxBackoffMs?: number
}

/**
 * How this desktop introduces itself to another one.
 *
 * The hostname, because that is what the person approving it on the other
 * machine will recognise, and the platform so the far end can print a noun
 * rather than guess one — the same field, in the same vocabulary, that
 * `welcome.hostPlatform` carries in the other direction. Display text on both
 * ends and treated as untrusted by both.
 */
export function describeThisMachine(): { name: string; platform: string } {
  const name = hostname().replace(/\.local$/i, '').trim()
  return { name: name === '' ? 'A desktop' : name, platform: process.platform }
}

export function createMachineLink(options: MachineLinkOptions): MachineLink {
  const now = options.now ?? Date.now
  const dial = options.dial ?? dialMachine
  const baseBackoffMs = options.baseBackoffMs ?? BASE_BACKOFF_MS
  const maxBackoffMs = options.maxBackoffMs ?? MAX_BACKOFF_MS

  let channel: GuestChannel | null = null
  let dialling = false
  let stopped = true
  let attempts = 0
  let connectedAt = 0
  let retry: ReturnType<typeof setTimeout> | null = null
  let welcomeTimer: ReturnType<typeof setTimeout> | null = null
  /** Has a `welcome` ever landed from this machine? Decides "waiting" vs "broken". */
  let everWelcomed = false
  /**
   * The last `error` that arrived on a serving connection, kept only until that
   * connection ends.
   *
   * Its whole job is the sentence. If the far end refused a *request* the
   * channel stays open and this is never read again; if it was refusing the
   * *connection* the close follows within a frame or two, and `closed` reports
   * this instead of the socket's own description — "the relay closed the
   * connection" says nothing to somebody whose device was just revoked.
   */
  let refusal: { message: string; code: ProtocolErrorCode | null } | null = null

  let current: MachineLinkState = {
    id: options.id,
    state: 'offline',
    reason: null,
    sessions: [],
    folders: null,
    capabilities: [],
    ports: [],
    hostPlatform: '',
    retryAt: null,
  }

  function publish(patch: Partial<MachineLinkState>): void {
    current = { ...current, ...patch }
    try {
      options.onState(current)
    } catch (error) {
      // The listener's own bookkeeping threw. It must not take the link down.
      console.error('[machines] a state listener threw:', error)
    }
  }

  function send(message: ClientMessage): boolean {
    if (channel === null || current.state !== 'online') return false
    channel.send(serialize(message))
    return true
  }

  function schedule(): void {
    if (retry !== null || stopped || dialling || channel !== null) return
    const ceiling = Math.min(maxBackoffMs, baseBackoffMs * 2 ** Math.min(attempts, 6))
    // Full jitter across the top half of the window, for the reason at the top
    // of this file: without it every machine redials in the same millisecond.
    const delay = Math.round(ceiling / 2 + Math.random() * (ceiling / 2))
    attempts += 1
    publish({ retryAt: now() + delay })
    retry = setTimeout(() => {
      retry = null
      publish({ retryAt: null })
      void open()
    }, delay)
    retry.unref?.()
  }

  /**
   * The channel is gone. Say why, and arrange to try again unless told not to.
   *
   * `state` is decided rather than passed in: a refusal from a machine that has
   * never let this one in is a pairing waiting on a human, and printing that as
   * an error would send somebody to the wrong screen.
   */
  function drop(reason: string, refused: ProtocolErrorCode | null): void {
    const live = channel
    channel = null
    refusal = null
    if (welcomeTimer !== null) clearTimeout(welcomeTimer)
    welcomeTimer = null
    if (live !== null) live.close()

    const wasStable = connectedAt !== 0 && now() - connectedAt >= STABLE_MS
    connectedAt = 0
    if (wasStable) attempts = 0

    if (stopped) {
      publish({ state: 'offline', reason: null, sessions: [], ports: [], retryAt: null })
      return
    }
    publish({
      state: refused === 'unauthorized' && !everWelcomed ? 'awaiting-approval' : 'error',
      reason,
      // The list belonged to a connection that is over. Keeping it would leave
      // rows on screen that open nothing, which is the same lie as a hover state
      // on something that is not clickable. The ports go for the same reason and
      // more strongly: a port list describes what is running on a machine, and
      // the most likely reason this link dropped is that the machine stopped.
      sessions: [],
      ports: [],
    })
    schedule()
  }

  function onMessage(text: string): void {
    const parsed = parseServerMessage(text)
    if (!parsed.ok) {
      // Not fatal on its own — a frame this build has never heard of is exactly
      // what the capability rule expects an older end to see — but it is worth a
      // line, because the other reading is a captive portal answering with HTML.
      console.error(`[machines] ${options.id} sent something unreadable: ${parsed.reason}`)
      return
    }
    const message = parsed.message
    switch (message.t) {
      case 'welcome': {
        if (welcomeTimer !== null) clearTimeout(welcomeTimer)
        welcomeTimer = null
        if (message.protocol !== PROTOCOL_VERSION) {
          drop(
            `That machine speaks protocol ${message.protocol} and this one speaks ${PROTOCOL_VERSION}. Update whichever build is older.`,
            null,
          )
          return
        }
        everWelcomed = true
        connectedAt = now()
        attempts = 0
        // A new connection carries none of the old one's refusals.
        refusal = null
        publish({
          state: 'online',
          reason: null,
          sessions: message.sessions,
          capabilities: message.capabilities,
          // Belonged to a connection that is over, exactly like the session
          // list. A port that was listening ten minutes ago on a machine that
          // has since rebooted is a row that opens nothing.
          ports: [],
          hostPlatform: message.hostPlatform ?? '',
          // Spread rather than assigned, so "never said" survives as null. See
          // the field's own comment.
          ...(message.folders === undefined ? {} : { folders: message.folders }),
          retryAt: null,
        })
        options.onWelcome(message.hostPlatform ?? '')
        /*
         * And ask what it is serving, once, here.
         *
         * On the welcome rather than when a panel opens, for the reason the
         * phone asks here too: the answer is one small frame, it is what the
         * panel needs the instant somebody looks at it, and a question asked on
         * first paint is a panel that is empty for a round trip every time it is
         * opened. Gated on the advertisement — a host that never offered
         * `localhost` answers this verb by closing the channel, and a button
         * that disconnects you is worse than a button that is not offered.
         */
        if (message.capabilities.includes(CAPABILITY.localhost)) send({ t: 'ports' })
        return
      }
      case 'sessions':
        publish({ sessions: message.sessions })
        return
      case 'created':
        // Merged rather than replacing the list: this frame is the one session
        // that was just started, and the rest of the list is still true.
        //
        // `reason` is cleared with it. A refusal printed under the row is about
        // the request that was refused, and leaving it there next to a session
        // that has just started would describe the wrong thing.
        refusal = null
        publish({
          reason: null,
          sessions: [
            message.session,
            ...current.sessions.filter((session) => session.id !== message.session.id),
          ],
        })
        return
      case 'folders':
        publish({ folders: message.folders })
        return
      case 'ports':
        publish({ ports: message.ports })
        return
      case 'web.opened':
        /*
         * The page is open over there, and there is nothing here to change.
         *
         * Deliberately not published as state. The confirmation is a window
         * appearing on the other machine — that is what was asked for and it is
         * what happened — and a panel that also announced it would be narrating
         * a thing the person can see. A *failure* is a plain `error` and does
         * reach the panel through `reason`, which is the asymmetry that matters:
         * silence means it worked.
         */
        return
      case 'output':
        options.onOutput(message.id, message.data, message.replay === true)
        return
      case 'status':
        publish({
          sessions: current.sessions.map((session) =>
            session.id === message.id ? { ...session, status: message.status } : session,
          ),
        })
        return
      case 'exit':
        publish({
          sessions: current.sessions.map((session) =>
            session.id === message.id
              ? { ...session, status: 'exited', exitCode: message.exitCode }
              : session,
          ),
        })
        return
      case 'error': {
        /*
         * Two completely different frames share this shape, and telling them
         * apart is the difference between a sentence and a disconnection.
         *
         * One is the connection being refused: a credential the far end will
         * not take, a device somebody revoked, a protocol frame it could not
         * read. `server.ts` sends those through `refuse`, which closes the
         * socket in the same breath.
         *
         * The other is one *request* being refused on a connection that is
         * working perfectly — `create` naming a folder that device has not been
         * granted, `attach` naming a session that has already exited, a tunnel
         * or an upload turned down. Those are answered and nothing is closed.
         *
         * This handler used to drop the link for both, and on real machines
         * that was the more common one by far. Asking a paired Windows PC for a
         * folder its grant list no longer carried took the whole link down:
         * `online` → `error` with the session list blanked → `connecting` →
         * `online`, measured at 1.9 seconds, for a mistake whose entire correct
         * outcome is one line of red text. Every remote session on that machine
         * vanished from the screen and came back, and any attach in flight was
         * lost with them.
         *
         * There is no request id on this wire to match an answer to a question,
         * so the discriminator is the state of the link: once `welcome` has
         * landed and this thing is serving, a refusal is a refused *request*.
         * A refused connection is still refused — the close follows immediately
         * and `closed` reports it with this sentence rather than the socket's.
         */
        const sentence = message.message === '' ? 'That machine refused the connection.' : message.message
        if (current.state === 'online') {
          refusal = { message: sentence, code: message.code }
          // Published so the sentence reaches the person who caused it. The
          // panel already draws `reason` under the row whatever the state is,
          // and the far end wrote this text for a reader — this end knows less
          // about why it said no than it does.
          publish({ reason: sentence })
          return
        }
        drop(sentence, message.code)
        return
      }
      case 'attached':
      case 'detached':
      case 'pong':
        // Acknowledgements. The screen is driven by `output`, and a state change
        // on the strength of an ack would be a second source of truth for the
        // same fact.
        return
    }
  }

  async function open(): Promise<void> {
    if (stopped || dialling || channel !== null) return
    dialling = true
    publish({ state: 'connecting', reason: null })

    let opened: GuestChannel
    try {
      opened = await dial({
        relayUrl: options.secrets.relayUrl,
        hostId: options.secrets.hostId,
        hostPublicKey: options.secrets.hostPublicKey,
        guestKeys: options.secrets.guestKeys,
        handlers: {
          message: onMessage,
          closed: (reason) => {
            if (channel === null) return
            // A refusal that arrived a moment ago was about this connection
            // after all, so its sentence wins over the socket's: "This device
            // is not allowed in." rather than "the relay closed the channel".
            drop(refusal?.message ?? reason, refusal?.code ?? null)
          },
        },
      })
    } catch (error) {
      dialling = false
      publish({ state: 'error', reason: error instanceof Error ? error.message : String(error) })
      schedule()
      return
    }

    dialling = false
    // Switched off while the dial was in the air. Without this the channel is
    // installed after `disconnect()` has run and then stays open for good:
    // nothing reconnects it and nothing is left holding it to close.
    if (stopped) {
      opened.close()
      return
    }
    channel = opened

    // The credential goes out immediately; there is nothing to wait for. A
    // channel that has completed the handshake has already proved the far end
    // holds the key this machine paired against, which is why sending a bearer
    // secret down it is safe.
    opened.send(
      serialize({
        t: 'hello',
        protocol: PROTOCOL_VERSION,
        token: options.secrets.credential,
        device: describeThisMachine(),
      }),
    )

    // A `hello` that is never answered is the shape of a relay that stapled this
    // channel to something that is not listening. Without this the link sits in
    // `connecting` forever and the panel says nothing at all.
    welcomeTimer = setTimeout(() => {
      welcomeTimer = null
      drop('That machine did not answer. It may be asleep or switched off.', null)
    }, WELCOME_TIMEOUT_MS)
    welcomeTimer.unref?.()
  }

  return {
    connect(): void {
      if (!stopped) return
      stopped = false
      attempts = 0
      void open()
    },
    disconnect(): void {
      if (stopped) return
      stopped = true
      if (retry !== null) clearTimeout(retry)
      retry = null
      if (welcomeTimer !== null) clearTimeout(welcomeTimer)
      welcomeTimer = null
      const live = channel
      channel = null
      live?.close()
      publish({ state: 'offline', reason: null, sessions: [], ports: [], retryAt: null })
    },
    state: () => current,
    attach: (sessionId, cols, rows) => send({ t: 'attach', id: sessionId, cols, rows }),
    detach: (sessionId) => send({ t: 'detach', id: sessionId }),
    input: (sessionId, data) => send({ t: 'input', id: sessionId, data }),
    resize: (sessionId, cols, rows) => send({ t: 'resize', id: sessionId, cols, rows }),
    create(request): boolean {
      // Refused here rather than sent and refused there, because the far end
      // answers an unadvertised verb by closing the channel. A button that
      // disconnects you is worse than a button that is not offered.
      if (!current.capabilities.includes('create')) return false
      return send({
        t: 'create',
        ...(request.cwd === undefined ? {} : { cwd: request.cwd }),
        ...(request.provider === undefined ? {} : { provider: request.provider }),
        ...(request.resume === undefined ? {} : { resume: request.resume }),
      })
    },
    ports(): boolean {
      // Refused here rather than sent and refused there, for the reason
      // `create` gives: the far end answers an unadvertised verb by closing the
      // channel.
      if (!current.capabilities.includes(CAPABILITY.localhost)) return false
      return send({ t: 'ports' })
    },
    openThere(url): boolean {
      if (!current.capabilities.includes(CAPABILITY.web)) return false
      // The URL is not checked here and deliberately is not. The far machine
      // puts every one through the same gate an untrusted link goes through,
      // because a client is not something a machine gets to trust about what it
      // opens — and a second, weaker check written on this side would be the one
      // somebody later mistook for the real one.
      return send({ t: 'web.open', url })
    },
    wake(): void {
      if (stopped) return
      // A channel that slept through a suspend is dead and still looks alive,
      // and the welcome timer would take fifteen seconds to say so. Redialling
      // costs one handshake and gets the machine back a great deal sooner; the
      // backoff resets because waking is not a failed attempt.
      attempts = 0
      if (retry !== null) clearTimeout(retry)
      retry = null
      const live = channel
      channel = null
      live?.close()
      if (welcomeTimer !== null) clearTimeout(welcomeTimer)
      welcomeTimer = null
      publish({ retryAt: null })
      void open()
    },
  }
}
