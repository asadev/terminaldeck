/**
 * The client itself: three screens, one socket, and no pretending.
 *
 * pair → sessions → terminal. The connection is owned here and lives across
 * all three, because a phone loses it constantly and re-establishing it must
 * not cost the user their place.
 *
 * The rule everything below serves: the banner tells the truth about the
 * connection at all times, and a terminal that is not live is dimmed, has a
 * still cursor, and refuses keys instead of swallowing them.
 */

// xterm's stylesheet first, ours second. Its rules and ours land on the same
// specificity — `.xterm .xterm-viewport` against `.terminal .xterm-viewport` —
// so the order in this file is the only thing that decides, and in the other
// order xterm painted a black gutter down the side of the terminal.
import '@xterm/xterm/css/xterm.css'
import './styles.css'

import { BRAND } from '../../src/shared/brand'
import { Connection, type ConnectionState, type SocketLike } from './connection'
import {
  CREDENTIAL_EXPLANATION,
  credentialHeadline,
  type CredentialNotice,
} from './credential'
import {
  DIRECT,
  hostKeyBytes,
  loadDeviceIdentity,
  type DeckEndpoint,
} from './endpoint'
import { folderOffer, foldersAfter, noFoldersSentence, pickerRows } from './folders'
import { machineNoun, readHostPlatform, type HostPlatform } from './host-platform'
import { createKeyBar, type KeyBarHandle } from './keybar'
import {
  CHECK_PATIENCE_MS,
  NO_LOCALHOST,
  cannotServeSentence,
  checkSentence,
  localhostOffered,
  localhostStep,
  noPortsSentence,
  portLabel,
  stalePortsSentence,
  type LocalhostAction,
  type LocalhostState,
} from './localhost'
import { watchPhysicalKeyboard, type KeyBarFit, type MatchMedia } from './physical-keyboard'
import {
  clearPairing,
  describeDevice,
  loadPairing,
  REMEMBERED_TTL_MS,
  renewed,
  savePairing,
  type StoredCredential,
} from './pair'
import { normaliseCode } from '../../src/shared/short-code'
import { asCodeField } from './code-field'
import { browserStores, type Remember } from './remember'
import { relaySocket } from './relay-socket'
import { lookupMachine } from './rendezvous'
import { chunkInput, type RemoteSession, type ServerMessage } from './protocol-client'
import { formatSince, sessionTone, shortenPath, sortSessions, statusLabel } from './sessions'
import { createTerminal, type TerminalHandle } from './terminal'

/**
 * Where a *direct* connection answers.
 *
 * Same origin as this page, always: on this route the client is served by the
 * very process it then talks to, so there is nothing to configure and no way to
 * point a paired browser at a different machine by editing a field.
 *
 * This used to be the only route, which meant this client worked for exactly one
 * kind of person — somebody already running Tailscale, because that is what
 * terminates the TLS on the address it is served from. It is now the fallback.
 * The relay is the product's network and `relay-socket.ts` is how this client
 * reaches it; `endpoint.ts` decides which of the two a given pairing is.
 */
// Kept in step with `WS_PATH` in src/main/remote/server.ts by hand, because
// that module is main-process code — importing it here would drag node:http
// into a browser bundle. It belongs in protocol.ts, where both sides could
// import it; see the handoff note.
const SOCKET_PATH = '/ws'

function socketUrl(location: Location): string {
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${location.host}${SOCKET_PATH}`
}

/**
 * The screens, and why `localhost` is one of them rather than a panel.
 *
 * A person on this page is doing one of two things — driving a session, or
 * looking at what the machine is serving — and on a phone those cannot share a
 * viewport. So it is a screen, reached from the same strip of tabs the session
 * list is, and it appears only when the desktop advertised `localhost`. See
 * `localhost.ts` for what that screen can honestly do from a browser tab and
 * what it deliberately does not pretend to.
 */
type Screen = 'pair' | 'sessions' | 'localhost' | 'terminal'

/**
 * Text on its way into the terminal rather than into the DOM.
 *
 * Everything printed between brackets by this client is written into an
 * emulator that executes what it is given, so a string that came off the socket
 * has its escapes taken away first. The desktop does not put remote text in its
 * refusals today; that is a property of the other side of the wire, and this is
 * the side that pays if it changes.
 */
function plain(text: string): string {
  // Escaped, never literal: a raw control byte in a character class is
  // invisible in every diff, which is the trap protocol.ts documents.
  return text.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 200)
}

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  if (className !== undefined) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

class Deck {
  private readonly root: HTMLElement
  private readonly header = element('header', 'header')
  private readonly back = element('button', 'header__back', '‹')
  private readonly title = element('h1', 'header__title')
  private readonly subtitle = element('p', 'header__subtitle')
  private readonly banner = element('div', 'banner')
  private readonly bannerText = element('span', 'banner__text')
  private readonly bannerAction = element('button', 'banner__action', 'Retry now')
  /**
   * Where a machine's request for a GitHub login is reported.
   *
   * A sibling of the content rather than part of a screen, because it has to be
   * readable from the terminal as well as from the session list — a `git push`
   * is asked for from inside a session, which is exactly where somebody is
   * looking when it happens.
   */
  private readonly credentialCard = element('section', 'ask')
  /**
   * The two places this client can be when it is not in a terminal.
   *
   * A strip rather than a menu, and a sibling of the content rather than part of
   * a screen, because it has to survive both of the screens it switches between
   * — a control that is redrawn by the thing it selects cannot show which thing
   * is selected. It is empty and hidden entirely against a desktop that does not
   * advertise `localhost`: one tab is not a choice, and the standing rule here is
   * that a control with one option is not drawn as one.
   */
  private readonly tabs = element('nav', 'tabs')
  private readonly content = element('main', 'content')

  private connection: Connection | null = null
  private state: ConnectionState = { phase: 'offline', detail: 'Not connected.', retryAt: null, attempts: 0 }
  /**
   * How this browser reaches the machine it is paired with.
   *
   * Held beside the credential rather than read off the connection, for the same
   * reason `hostPlatform` is: the pair screen has no socket by definition, and
   * the credential is written from more than one place. `DIRECT` until something
   * says otherwise, which is both the unpaired state and the state of every
   * browser that paired before the relay existed.
   */
  private endpoint: DeckEndpoint = DIRECT
  /**
   * The two places a pairing can live, and the rule about which.
   *
   * See `remember.ts`. Resolved once, because probing `localStorage` on a
   * browser that refuses it throws and the fallback has to be the same object
   * every time — a store that was memory on one call and real on the next would
   * lose a credential between writing it and reading it back.
   */
  private readonly stores = browserStores()
  /**
   * How long this pairing is meant to last, as the person answered it.
   *
   * `this-tab` is the default and it is the safe one. The premise of a browser
   * client is the computer you do not own, and the question is asked before
   * anything is written — so an unanswered state cannot exist, and if one
   * somehow did it would be the one that leaves nothing behind.
   *
   * Seeded from the pairing already in storage when there is one, so somebody
   * re-pairing a browser they had remembered is not asked to decide the same
   * thing twice. `forget` puts it back, because that is the person saying this
   * is not their machine any more.
   */
  private remember: Remember = 'this-tab'
  /**
   * This browser's own X25519 identity, as the machine knows it.
   *
   * Loaded once at startup rather than per connection. It is what
   * `isKnownDevice` on the machine matches every reconnect against, so a client
   * that generated a fresh one per socket would pair successfully and then be
   * refused by its own next attempt.
   *
   * Made in memory when there is none stored, and written only when a pairing
   * is — into the store that pairing chose. Opening this page on a borrowed
   * computer and closing it again leaves nothing.
   */
  private deviceKeys = loadDeviceIdentity(this.stores)
  /** Set while a typed code is being looked up at the relay. */
  private looking = false
  private screen: Screen = 'pair'
  private sessions: RemoteSession[] = []
  private activity = new Map<string, number>()
  private credential: StoredCredential | null = null
  private attachedId: string | null = null
  /** True once an `attach` has gone out for `attachedId` on this connection. */
  private attachSent = false
  private terminal: TerminalHandle | null = null
  private keybar: KeyBarHandle | null = null
  private terminalScreen: HTMLElement | null = null
  /** Set while a message needs saying on the sessions screen. */
  private notice: string | null = null
  /**
   * The last GitHub login a machine asked this browser for, until it is
   * dismissed.
   *
   * Kept rather than flashed: the person who needs to read it may have been
   * looking at the terminal when the push failed, and a toast that had already
   * gone would leave them with a git error and no explanation anywhere.
   */
  private credentialAsk: CredentialNotice | null = null
  /**
   * What kind of machine this client is paired to.
   *
   * Held here rather than read off the connection, because the screens that most
   * need it are drawn when there is no connection to ask: the pair screen has no
   * socket by definition, and the session list is painted from the stored
   * credential before the first frame arrives. Seeded from that credential on
   * launch, replaced by every `welcome`, and reset only when the machine is
   * deliberately forgotten.
   */
  private hostPlatform: HostPlatform = 'unknown'
  /**
   * What the desktop said it can do beyond protocol v1, from its last welcome.
   *
   * Nothing is offered that is not in here. A `create` sent to a host that
   * never advertised one is refused by its parser and the socket goes with it,
   * so a hopeful button is a broken client rather than an optimistic one.
   */
  private capabilities: string[] = []
  /**
   * The folders this device may start a session in, or null when the desktop
   * has never said.
   *
   * Null is not "none" and the two must not be folded together here either —
   * see `folders.ts`, which owns the whole rule. Replaced by `foldersAfter` on
   * every frame, so the pushed update lands without a reconnect.
   */
  private folders: string[] | null = null
  /** Set between asking for a session and being told about one. */
  private awaitingCreate = false
  /** Set while the folder list under New session is open. */
  private picking = false
  /** What the machine is serving, and the check in flight. See `localhost.ts`. */
  private localhost: LocalhostState = NO_LOCALHOST
  /** The timer behind `CHECK_PATIENCE_MS`, or null when nothing is being checked. */
  private checkTimer: number | null = null
  /**
   * Names the tunnels this client opens, and never repeats one.
   *
   * A counter rather than a random string, because the ids only have to be
   * unique against *this* connection — the desktop tears its hub down when the
   * socket goes — and a counter is the version a test can predict. It never
   * resets, so a reconnect cannot reuse an id the desktop is still holding.
   * `ID_RE` on the far side accepts it: a letter, then letters, digits and
   * hyphens.
   */
  private checks = 0
  /**
   * Whether the person reading this has an Esc key of their own.
   *
   * Watched rather than read once — an iPad leaves its keyboard mid-session. See
   * `physical-keyboard.ts`, which owns the whole question and explains why the
   * signal is the input hardware and not the user agent.
   */
  private keyboard: KeyBarFit | null = null
  /** The strip the key bar sits in, so its visibility can follow the hardware. */
  private keybarDock: HTMLElement | null = null

  constructor(root: HTMLElement) {
    this.root = root
    document.title = BRAND.name

    this.back.type = 'button'
    this.back.setAttribute('aria-label', 'Back')
    this.back.addEventListener('click', () => this.leaveTerminal())

    const titles = element('div', 'header__titles')
    titles.append(this.title, this.subtitle)
    this.header.append(this.back, titles)

    this.bannerAction.type = 'button'
    this.bannerAction.addEventListener('click', () => this.connection?.resume())
    this.banner.append(this.bannerText, this.bannerAction)

    root.append(this.header, this.banner, this.credentialCard, this.tabs, this.content)
  }

  /* ------------------------------------------------------------- startup -- */

  start(): void {
    const found = loadPairing(this.stores, Date.now())
    this.credential = found?.credential ?? null
    this.remember = found?.remember ?? 'this-tab'
    this.hostPlatform = this.credential?.hostPlatform ?? 'unknown'
    this.endpoint = this.credential?.endpoint ?? DIRECT

    /*
     * Nothing is read out of the URL here any more, and that is a deletion
     * rather than an omission.
     *
     * A pairing token used to arrive in the fragment of a link the desktop drew
     * as a QR code, and `start` took it out of the address bar before deciding
     * anything. There is no link and no QR, so nothing writes that fragment —
     * and a reader for a token nobody mints is a second, unexercised route into
     * the one function that puts a credential on a computer somebody may not
     * own.
     */
    if (this.credential !== null) {
      this.screen = 'sessions'
      this.render()
      this.connect(this.credential.token, this.endpoint)
    } else {
      this.screen = 'pair'
      this.render()
    }

    this.watchKeyboard()
    this.watchViewport()
    this.watchWakeups()
    // Every second, because the banner counts down. Cheap, and it stops the
    // moment there is nothing to count.
    window.setInterval(() => {
      if (this.state.retryAt !== null) this.renderBanner()
    }, 1000)
  }

  /**
   * Point the connection at a machine, by whichever of the two routes it is.
   *
   * The route decides one thing — what `open` returns — and nothing else.
   * `connection.ts` above it is untouched: the banner, the heartbeat, the
   * backoff, the refusal to buffer a keystroke and the whole pairing-approval
   * dance are the same code whether the bytes went through a relay or straight
   * down a tailnet. That seam is what made giving this client the relay a small
   * change rather than a second client.
   */
  private connect(token: string, endpoint: DeckEndpoint): void {
    this.connection?.stop()
    this.endpoint = endpoint

    let open: ((url: string) => SocketLike) | undefined
    let url = socketUrl(window.location)
    if (endpoint.kind === 'relay') {
      const hostPublicKey = hostKeyBytes(endpoint.hostKey)
      if (hostPublicKey === null) {
        // `asEndpoint` decodes the key before it will call something a relay
        // endpoint, so this is unreachable from storage — and it is checked
        // anyway, because the alternative to a sentence here is a handshake that
        // fails for a reason nobody can see.
        this.state = {
          phase: 'offline',
          detail: `That pairing is missing the ${this.noun}'s key, so nothing can be reached. Pair again.`,
          retryAt: null,
          attempts: 0,
        }
        this.renderBanner()
        return
      }
      const relay = endpoint
      url = relay.url
      open = () =>
        relaySocket({
          relayUrl: relay.url,
          hostId: relay.hostId,
          hostPublicKey,
          deviceKeys: this.deviceKeys,
        })
    }

    this.connection = new Connection({
      url,
      token,
      reach: endpoint.kind,
      open,
      device: describeDevice(navigator.userAgent),
      handlers: {
        onState: (state) => this.onState(state),
        onMessage: (message, activity) => this.onMessage(message, activity),
        onCredential: (credential) => this.onCredential(credential),
        onCredentialAsked: (notice) => this.onCredentialAsked(notice),
      },
    })
    this.connection.start()
  }

  /**
   * Follow the input hardware, so the key bar is there exactly when it is needed.
   *
   * `matchMedia` is passed rather than reached for, which is what keeps the
   * decision in a file the suite can ask questions of; a browser without it gets
   * `undefined` and keeps the bar. See `physical-keyboard.ts` for why that is the
   * right way to be wrong.
   */
  private watchKeyboard(): void {
    const media: MatchMedia | undefined =
      typeof window.matchMedia === 'function' ? (query) => window.matchMedia(query) : undefined
    this.keyboard = watchPhysicalKeyboard(media, () => this.applyKeyBar())
    this.applyKeyBar()
  }

  /**
   * Show or hide the key row for the hardware that is attached right now.
   *
   * The bar is hidden rather than destroyed. It holds the armed-Ctrl state that
   * `sendInput` folds characters through, and a tablet that leaves its keyboard
   * mid-session must get the row back with the terminal underneath it untouched
   * — rebuilding it would mean rebuilding the emulator, which loses focus and
   * reflows every line of scrollback.
   *
   * The refit is not cosmetic: the terminal is `flex: 1` above the dock, so
   * taking forty-eight pixels away gives it four more rows, and an emulator that
   * has not been told is one whose bottom four lines are painted over.
   */
  private applyKeyBar(): void {
    const dock = this.keybarDock
    if (dock === null) return
    dock.hidden = !(this.keyboard?.wanted ?? true)
    this.terminal?.fit()
  }

  /** Reconnect early when the OS gives us a reason to think it will work. */
  private watchWakeups(): void {
    window.addEventListener('online', () => this.connection?.resume())
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') this.connection?.resume()
    })
  }

  /* -------------------------------------------------------------- events -- */

  private onState(state: ConnectionState): void {
    const wasOnline = this.state.phase === 'online'
    this.state = state

    // Nothing in flight survives the socket that carried it. A `create` whose
    // answer was on its way when the connection dropped may or may not have
    // started something on the desktop — the next `list` says which — and the
    // one thing this client must not do meanwhile is keep a button spinning
    // against a socket that will never answer it.
    if (state.phase !== 'online') this.awaitingCreate = false
    // Same argument, for the same reason: a port check left spinning against a
    // socket that will never answer it is the lie this client exists not to
    // tell. The port list survives and is labelled as old rather than blanked.
    if (state.phase !== 'online') this.localhostDo({ t: 'offline' })

    if (state.phase === 'online' && !wasOnline) {
      // Re-attach rather than assume. The desktop kept running while we were
      // gone, so what is on screen is from before the gap; leaving it there
      // under a fresh connection is the lie this whole client is built to avoid.
      if (this.attachedId !== null) {
        this.terminal?.reset()
        this.attach(this.attachedId)
      }
      this.connection?.send({ t: 'list' })
      // The ports the desktop was serving before the gap say nothing about the
      // ports it is serving now — a reconnect is the one moment this list is
      // certainly stale, and the screen showing it is the one place that matters.
      if (this.screen === 'localhost') this.localhostDo({ t: 'list' })
    }

    if (state.phase === 'rejected') {
      // The credential is no good. Holding on to it would mean every launch
      // fails the same way with no route back to pairing — and on a computer
      // that is not this person's, it would be a dead secret left in a profile
      // somebody else will open. Both stores, because the tab's copy and the
      // durable one are the same pairing.
      clearPairing(this.stores)
      this.credential = null
      this.attachedId = null
      // Everything the refused machine told us about itself goes with it. A
      // folder list is a statement about a device this desktop no longer
      // recognises, and drawing a picker from it on the way back to the pair
      // screen would be offering somewhere to start that nothing will start in.
      this.capabilities = []
      this.folders = null
      this.picking = false
      // And what it was serving. A port list is a statement about a machine
      // that no longer recognises this browser, and it must not still be on
      // screen behind the pair form.
      this.forgetLocalhost()
      // Not merely hidden: the terminal holds this machine's scrollback, and a
      // device that has just been told it is no longer trusted should not still
      // be carrying it around in memory.
      this.destroyTerminal()
      this.screen = 'pair'
      this.render()
      return
    }

    this.terminal?.setLive(state.phase === 'online')
    this.renderBanner()
    // Both list screens redraw: what they offer — New session, Refresh, Check —
    // is drawn only while there is a socket to carry it.
    if (this.screen === 'sessions' || this.screen === 'localhost') this.renderContent()
  }

  /* ----------------------------------------------------------- localhost -- */

  /**
   * One transition of the localhost machine, and the frames it asked for.
   *
   * The state lives in `localhost.ts` precisely so this method is the only part
   * of it that cannot be tested: everything here is delivery. A frame that does
   * not reach the desktop puts the machine straight back to its offline state
   * rather than leaving a check spinning — `Connection.send` refuses only when
   * the socket is not up, and when it is not up the banner is already saying so
   * in the desktop's own words, which is a better sentence than one composed
   * here would be.
   */
  private localhostDo(action: LocalhostAction): void {
    const step = localhostStep(this.localhost, action)
    if (step.state === this.localhost && step.send.length === 0) return
    this.localhost = step.state

    for (const message of step.send) {
      if (this.connection?.send(message) === true) continue
      this.localhost = localhostStep(this.localhost, { t: 'offline' }).state
      break
    }

    this.armCheckTimer()
    if (this.screen === 'localhost') this.renderContent()
  }

  /**
   * Give up on a check that nothing has answered.
   *
   * Re-armed from scratch on every transition rather than cleared in the two
   * places a check can end, because "the timer matches whatever is in flight" is
   * one rule and "clear it here, and here, and here" is three that drift. A
   * fired timer that names a check which has already finished is ignored by the
   * machine itself, so the worst a stale one costs is a no-op.
   */
  private armCheckTimer(): void {
    if (this.checkTimer !== null) {
      window.clearTimeout(this.checkTimer)
      this.checkTimer = null
    }
    const checking = this.localhost.checking
    if (checking === null) return
    const id = checking.id
    this.checkTimer = window.setTimeout(() => {
      this.checkTimer = null
      this.localhostDo({ t: 'silence', id })
    }, CHECK_PATIENCE_MS)
  }

  /** Everything this client knew about what the machine was serving. */
  private forgetLocalhost(): void {
    if (this.checkTimer !== null) {
      window.clearTimeout(this.checkTimer)
      this.checkTimer = null
    }
    this.localhost = NO_LOCALHOST
    if (this.screen === 'localhost') this.screen = 'sessions'
  }

  private onCredential(token: string): void {
    const now = Date.now()
    this.credential = {
      token,
      deviceId: this.credential?.deviceId ?? '',
      deviceName: this.credential?.deviceName ?? 'This device',
      pairedAt: now,
      hostPlatform: this.hostPlatform,
      // Written with the credential, not after it. The credential is what the
      // next launch reconnects with and the endpoint is where it reconnects to;
      // saving one without the other leaves a browser holding a secret for a
      // machine it can no longer find.
      endpoint: this.endpoint,
      expiresAt: now + REMEMBERED_TTL_MS,
    }
    this.keep()
  }

  /**
   * Put the credential where the person said, or nowhere at all.
   *
   * One method rather than a `savePairing` call at each of the two places a
   * credential is minted or refreshed, because the argument that is easy to get
   * wrong is `this.remember` — and a single miss writes a durable secret onto a
   * machine whose owner answered "just for this visit". The device key rides
   * along inside `savePairing` for the same reason.
   */
  private keep(): void {
    if (this.credential === null || this.credential.token === '') return
    savePairing(this.stores, this.remember, this.credential, this.deviceKeys)
  }

  /**
   * A machine asked this browser for a GitHub login.
   *
   * It has already been acknowledged and refused by the time this runs — see
   * `credential.ts` for why this client cannot hold a token and why refusing is
   * the honest implementation rather than an unfinished one. What is left to do
   * is tell the person, because a refusal nobody sees is indistinguishable from
   * a feature that is broken.
   *
   * The newest question replaces the one on screen rather than stacking. A fetch
   * loop would otherwise fill the page with identical cards, and the second card
   * says nothing the first one did not: the answer is the same every time and
   * the remedy is the same every time.
   */
  private onCredentialAsked(notice: CredentialNotice): void {
    this.credentialAsk = notice
    this.renderCredentialAsk()
  }

  /** What to call the machine on the other end, in a sentence. */
  private get noun(): string {
    return machineNoun(this.hostPlatform)
  }

  private onMessage(message: ServerMessage, activity?: ReadonlyMap<string, number>): void {
    // Before the switch, and deliberately not inside two of its cases. The
    // folder list arrives in `welcome` *and* in a pushed frame, and the failure
    // to design against is a client that reads one of them: the pushed one is
    // what makes a folder removed at the desk disappear from the picker in
    // somebody's hand, rather than at the next launch.
    this.folders = foldersAfter(this.folders, message)
    // And before it, for the same reason: `ports`, `tunnel.opened` and
    // `tunnel.closed` are answers to questions the localhost screen asked, and
    // the switch below has no case for them by design — routing them through a
    // second `case` here would put half of that feature's rules in a file no
    // test can reach. Every other frame leaves the machine untouched and returns
    // the identical object, so this costs one comparison per line of output.
    this.localhostDo({ t: 'frame', message })

    switch (message.t) {
      case 'welcome':
        // Before the credential is rebuilt, because the credential now carries
        // it: this is the one frame that says what the machine is, and every
        // launch after this one reads the answer back out of storage rather
        // than waiting for a socket.
        this.hostPlatform = readHostPlatform(message.hostPlatform)
        this.capabilities = message.capabilities
        this.credential = renewed(
          {
            token: this.credential?.token ?? '',
            deviceId: message.deviceId,
            deviceName: message.deviceName,
            pairedAt: this.credential?.pairedAt ?? Date.now(),
            hostPlatform: this.hostPlatform,
            endpoint: this.endpoint,
            expiresAt: this.credential?.expiresAt ?? 0,
          },
          // A welcome is the only frame that proves this browser actually
          // reached the machine, which is what the sliding window measures. A
          // socket that merely opened proves nothing — the relay will open one
          // against a host id whose owner revoked this device an hour ago.
          Date.now(),
        )
        this.keep()
        this.applySessions(message.sessions, activity)
        if (this.screen === 'pair') this.screen = 'sessions'
        // A desktop that no longer offers tunnelling — a different machine on
        // the same pairing, or one launched with a narrower `offer` — must not
        // leave this browser sitting on a screen whose every control it would
        // now refuse.
        if (this.screen === 'localhost' && !localhostOffered(this.capabilities)) this.forgetLocalhost()
        // Asked on arrival rather than on the first tap, but only for somebody
        // already looking at it — which is the reconnect case, since the tab is
        // what asks otherwise.
        if (this.screen === 'localhost') this.localhostDo({ t: 'list' })
        this.render()
        return

      case 'sessions':
        this.applySessions(message.sessions, activity)
        if (this.screen === 'sessions') this.renderContent()
        return

      case 'folders':
        // The list itself has already been taken, above. What is left is the
        // redraw: the picker on screen is now describing a rule the desktop has
        // stopped enforcing, and every second it stays up is a tap that would
        // be refused. It stays *open* through an ordinary edit, which is the
        // point of the frame — the rows change under the finger.
        //
        // A list that has just been emptied is the exception: there is no
        // picker left to keep open, and leaving the flag set would spring one
        // open by itself the moment a folder was granted again.
        if (message.folders.length === 0) this.picking = false
        if (this.screen === 'sessions') this.renderContent()
        return

      case 'created': {
        this.awaitingCreate = false
        // Put in the list here rather than waiting for a `sessions` frame: the
        // desktop answers the phone that asked with the whole row and tells
        // everybody else with a plain list, so this is the only frame that says
        // *which* of the sessions is the new one. With two sessions in one
        // folder there is no way to guess right.
        if (!this.sessions.some((entry) => entry.id === message.session.id)) {
          this.sessions = [...this.sessions, message.session]
        }
        // A session that has just been started is a session that just did
        // something, and this client watched it happen — the same reason an
        // `output` or a `status` frame stamps the clock rather than leaving the
        // row with no time on it.
        this.activity.set(message.session.id, Date.now())
        // The tap that started it is the tap that opens it.
        this.openSession(message.session.id)
        return
      }

      case 'output':
        if (message.id !== this.attachedId) return
        this.terminal?.write(message.data)
        // Replay is scrollback from before this client arrived, so it says
        // nothing about when the session last did something.
        if (message.replay !== true) this.activity.set(message.id, Date.now())
        return

      case 'status': {
        const session = this.sessions.find((entry) => entry.id === message.id)
        if (session) session.status = message.status
        this.activity.set(message.id, Date.now())
        if (this.screen === 'sessions') this.renderContent()
        return
      }

      case 'exit': {
        const session = this.sessions.find((entry) => entry.id === message.id)
        if (session) session.exitCode = message.exitCode
        if (message.id === this.attachedId) {
          // Bracketed and dim, so it cannot be mistaken for program output.
          this.terminal?.write(`\r\n\x1b[2m[session exited with code ${message.exitCode}]\x1b[0m\r\n`)
        }
        if (this.screen === 'sessions') this.renderContent()
        return
      }

      case 'error':
        // A refused request is not going to be followed by a `created`, and a
        // button left reading "Starting…" over a session that will never exist
        // is the same lie as a live-looking cursor over a dead socket.
        this.awaitingCreate = false
        if (message.code === 'unknown-session') {
          this.notice = `That session is no longer running on the ${this.noun}.`
          this.leaveTerminal()
          return
        }
        this.notice = message.message
        // Said where the user is looking. An in-session refusal — the desktop
        // answers a keystroke for a session this client is no longer attached
        // to with one — arrives while the terminal is on screen, and a notice
        // parked on the sessions list behind it is a keystroke that vanished
        // with no explanation.
        if (this.screen === 'terminal') this.terminal?.write(`\r\n\x1b[2m[${plain(message.message)}]\x1b[0m\r\n`)
        else if (this.screen === 'sessions') this.renderContent()
        return

      default:
        return
    }
  }

  private applySessions(sessions: RemoteSession[], activity?: ReadonlyMap<string, number>): void {
    this.sessions = sessions
    if (activity) for (const [id, at] of activity) this.activity.set(id, at)
  }

  /* -------------------------------------------------------------- render -- */

  private render(): void {
    this.renderHeader()
    this.renderBanner()
    this.renderCredentialAsk()
    this.renderTabs()
    this.renderContent()
  }

  /**
   * The strip that switches between the session list and localhost.
   *
   * Absent — not disabled, and not drawn with one tab in it — whenever there is
   * nothing to switch *to*: on the pair screen, inside a terminal, and against
   * any desktop that did not advertise `localhost`. That is the same rule
   * `startBlock` follows for New session, and it is the reason a browser paired
   * to an older machine sees exactly what it saw before this existed.
   */
  private renderTabs(): void {
    const listing = this.screen === 'sessions' || this.screen === 'localhost'
    const show = listing && this.credential !== null && localhostOffered(this.capabilities)
    this.tabs.hidden = !show
    if (!show) {
      this.tabs.replaceChildren()
      return
    }

    const options: Array<{ screen: Screen; label: string }> = [
      { screen: 'sessions', label: 'Sessions' },
      { screen: 'localhost', label: 'Localhost' },
    ]
    this.tabs.replaceChildren(
      ...options.map((option) => {
        const here = this.screen === option.screen
        const tab = element('button', here ? 'tab tab--here' : 'tab', option.label)
        tab.type = 'button'
        // `aria-current` rather than `aria-pressed`: these are two places to be,
        // not two switches, and a screen reader should say "current page".
        if (here) tab.setAttribute('aria-current', 'page')
        tab.addEventListener('click', () => this.goTo(option.screen))
        return tab
      }),
    )
  }

  /**
   * Move between the two list screens.
   *
   * The port list is asked for on arrival rather than kept fresh in the
   * background: a `ports` frame runs a real `lsof` on somebody's machine, and
   * polling it while nobody is looking is the kind of cost that only shows up on
   * a laptop's battery. Asked once, and only when there is a socket — offline,
   * the screen shows the last answer and says how old it is.
   */
  private goTo(screen: Screen): void {
    if (this.screen === screen) return
    this.screen = screen
    if (screen === 'localhost' && this.localhost.ports === null && this.state.phase === 'online') {
      this.localhostDo({ t: 'list' })
    }
    this.render()
  }

  /**
   * What a machine asked for, and the sentence the desktop had no way to write.
   *
   * The three facts named here are the same three the approval prompt names on
   * the phones — the repository, the account, and the machine that asked — and
   * that is deliberate: this is the same event, reported by a client that cannot
   * answer it. What replaces the buttons is the explanation and the two routes
   * that do work.
   *
   * Everything variable in it goes through `plain`, like every other string that
   * came off this socket.
   */
  private renderCredentialAsk(): void {
    const ask = this.credentialAsk
    this.credentialCard.hidden = ask === null
    if (ask === null) {
      this.credentialCard.replaceChildren()
      return
    }

    const headline = element(
      'p',
      'ask__headline',
      plain(credentialHeadline(ask, `The ${this.noun}`)),
    )
    const why = element('p', 'ask__why', CREDENTIAL_EXPLANATION)
    const dismiss = element('button', 'button button--quiet', 'Dismiss')
    dismiss.type = 'button'
    dismiss.addEventListener('click', () => {
      this.credentialAsk = null
      this.renderCredentialAsk()
    })
    this.credentialCard.replaceChildren(headline, why, dismiss)
  }

  private renderHeader(): void {
    const attached = this.sessions.find((session) => session.id === this.attachedId)
    this.back.hidden = this.screen !== 'terminal'
    if (this.screen === 'terminal' && attached) {
      this.title.textContent = attached.title
      this.subtitle.textContent = `${attached.provider} · ${shortenPath(attached.cwd)}`
      return
    }
    this.title.textContent = BRAND.name
    // Named by the route it is actually on. Printing `location.host` for a relay
    // pairing was true of this page and false of the machine — the browser can
    // be served from anywhere now, and a subtitle that reads like an address is
    // read as one.
    this.subtitle.textContent =
      this.credential === null
        ? 'Not paired'
        : this.endpoint.kind === 'relay'
          ? this.endpoint.hostId.slice(0, 6)
          : window.location.host
  }

  private renderBanner(): void {
    const { phase, detail, retryAt } = this.state
    this.banner.className = `banner banner--${phase}`

    let text = detail
    if (retryAt !== null && (phase === 'waiting' || phase === 'pending')) {
      const seconds = Math.max(0, Math.ceil((retryAt - Date.now()) / 1000))
      text = seconds > 0 ? `${detail} Retrying in ${seconds}s.` : `${detail} Retrying…`
    }
    this.bannerText.textContent = text

    // A retry button on a state retrying cannot fix — or with no connection
    // behind it at all — is a button that does nothing when pressed.
    this.bannerAction.hidden =
      this.connection === null || phase === 'rejected' || phase === 'incompatible' || phase === 'connecting'
  }

  private renderContent(): void {
    if (this.screen === 'terminal') {
      this.showTerminalScreen()
      return
    }
    if (this.screen === 'pair') {
      this.content.replaceChildren(this.pairScreen())
      return
    }
    this.content.replaceChildren(this.screen === 'localhost' ? this.localhostScreen() : this.sessionsScreen())
  }

  /**
   * Pair, from the one thing a person can be holding: six digits.
   *
   * There used to be three shapes in this field — a `terminaldeck://pair?…`
   * link, a tailnet link with the token in its fragment, and a code — and a
   * function whose job was to tell them apart. Two of the three are gone, and
   * what is left is not a paste target at all: it is six digits read off the
   * other screen. `rendezvous.ts` explains why looking them up at a relay is
   * safe against a relay that would like to answer in the machine's place.
   *
   * ## The field is `inputmode="numeric"` and it is the point
   *
   * Half the argument for digits is what a phone puts under them. `type="text"`
   * with a numeric inputmode rather than `type="number"`: a number input strips
   * leading zeros, offers a spinner, and on some browsers refuses a paste that
   * is not a valid number — and `000042` is a perfectly good pairing code that
   * all three of those would destroy.
   *
   * It submits itself on the sixth digit. There is nothing to decide after it —
   * a code is exactly six long, so a button press at that point is a tap that
   * asks a question with one possible answer.
   */
  private pairScreen(): HTMLElement {
    // `screen--form`, which caps the column far tighter than the list screens
    // do. A six-digit field and a full-width primary button stretched across a
    // 27" monitor is not "using the window", it is a form nobody can aim at —
    // see the width rules at the foot of styles.css.
    const screen = element('div', 'screen screen--form')

    screen.append(
      // Neutral on a fresh install and neutral by design: nothing has answered
      // yet, so nothing here may claim to know what kind of computer is at the
      // other end. It sharpens to "Mac" or "PC" the moment one does — which for
      // a re-pair is immediately, because the stored credential remembers.
      element('h2', undefined, `Pair with your ${this.noun}`),
      element(
        'p',
        'screen__lead',
        `${BRAND.name} on the ${this.noun} shows a six-digit code. Type it here — the ${this.noun} does not ` +
          'need to be on the same network.',
      ),
    )

    const steps = element('ol', 'steps')
    for (const step of [
      `Open ${BRAND.name} on the ${this.noun} and show the pairing code.`,
      'Type the six digits below.',
      `Approve this browser on the ${this.noun} when it appears — pairing alone does not grant access.`,
    ]) {
      steps.append(element('li', undefined, step))
    }
    screen.append(steps)

    const label = element('p', 'screen__lead', 'The six digits on the other screen:')
    // Every attribute, and the reasoning for each, is in `code-field.ts` — where
    // a test can reach it. Nothing in this file can be rendered by the suite, so
    // a keypad decision written here is one that nothing checks.
    const input = asCodeField(element('input'))
    input.className = 'button button--quiet'
    input.style.textAlign = 'center'
    input.style.letterSpacing = '0.35em'
    input.style.fontVariantNumeric = 'tabular-nums'
    screen.append(label, input)

    screen.append(this.rememberChoice())

    const submit = element('button', 'button', this.looking ? 'Looking…' : 'Pair')
    submit.type = 'button'
    submit.disabled = this.looking
    submit.addEventListener('click', () => void this.startPairing(input.value))
    screen.append(submit)

    /*
     * Auto-submit, and the guard that makes it safe to have.
     *
     * `input` fires for a paste as well as for a keystroke, so pasting six
     * digits pairs without a tap — which is the common case on a laptop, where
     * the code came through a message. `startPairing` returns immediately while
     * `this.looking` is set, so a seventh `input` event (a character typed into
     * a full field, an autocomplete replacement) cannot start a second lookup.
     */
    input.addEventListener('input', () => {
      const typed = normaliseCode(input.value)
      if (typed === null || this.looking) return
      void this.startPairing(typed)
    })
    // Enter still works, for somebody who typed five digits and a sixth that
    // was rejected — the field is not the only way to ask.
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') void this.startPairing(input.value)
    })

    screen.append(
      element(
        'p',
        'note',
        'A code is good for one minute and one use. Everything between this browser and the ' +
          `${this.noun} is sealed end to end — the relay that carries it holds no key and cannot read a session.`,
      ),
    )
    // Focused after the tree is built, by the caller that puts it on screen —
    // see `renderContent`. Focusing an element that is not in the document does
    // nothing, and doing nothing quietly is how the keypad stopped appearing.
    queueMicrotask(() => input.focus())
    return screen
  }

  /**
   * "Is this browser yours?", asked once, before anything is written.
   *
   * ## Why this is on screen at all
   *
   * The iOS and Android clients never ask, and they are right not to: their
   * credential is in the Keychain or the Keystore, on a device that belongs to
   * the person holding it. This one has neither. What it has is storage any
   * script on the origin can read, and a reason to exist that is *specifically*
   * the computer somebody does not own — a work laptop, a machine in a lab, a
   * friend's desktop. A pairing left behind on one of those is a live shell on
   * the owner's machine, sitting in a browser profile, for whoever opens it next.
   *
   * There is no account to sign out of and there must not be. So the only place
   * this can be decided is here, at the one moment the person and the computer
   * are both present, and the honest thing to do is ask rather than guess.
   *
   * ## Why "just for this visit" is the default
   *
   * Because getting it wrong in that direction costs a re-pair, and getting it
   * wrong in the other direction leaves a shell on a stranger's machine. The
   * option that is right for the person's own laptop is one tap away and is
   * spelled out beside it; the option that is safe on every machine is the one
   * that happens if they read nothing at all.
   *
   * Radios rather than a checkbox because both answers get a sentence. A ticked
   * or unticked box explains one state and leaves the reader to infer the other,
   * and the design brief's bar is a screen somebody who has never seen it can
   * read.
   */
  private rememberChoice(): HTMLElement {
    const days = Math.round(REMEMBERED_TTL_MS / 86_400_000)
    const group = element('fieldset', 'remember')
    group.append(element('legend', 'remember__legend', 'Is this browser yours?'))

    const options: Array<{ value: Remember; title: string; note: string }> = [
      {
        value: 'this-tab',
        title: 'Just for this visit',
        note: 'The pairing is gone the moment you close this tab. Use this on a computer that is not yours.',
      },
      {
        value: 'this-browser',
        title: 'Remember this browser',
        note: `Stays paired in this browser until you unpair it, or ${days} days pass without using it. Anyone who uses this browser can open your sessions.`,
      },
    ]

    for (const option of options) {
      const row = element('label', 'remember__option')
      const radio = element('input')
      radio.type = 'radio'
      radio.name = 'terminaldeck-remember'
      radio.value = option.value
      radio.checked = this.remember === option.value
      radio.addEventListener('change', () => {
        this.remember = option.value
      })

      const text = element('span', 'remember__text')
      text.append(
        element('span', 'remember__title', option.title),
        element('span', 'remember__note', option.note),
      )
      row.append(radio, text)
      group.append(row)
    }
    return group
  }

  /**
   * Turn six typed digits into a connection, or say why not.
   *
   * The wait is the whole reason this is asynchronous — a memory-hard derivation
   * and a round trip to the relay take about a second between them, which is a
   * second with nothing on screen unless the button says so.
   *
   * ## Why a code that is not found still tries this page's own origin
   *
   * Because when this page was served *by the machine itself*, over the tailnet,
   * the address is the origin and there is nothing to look up. That is the one
   * case a rendezvous cannot help with and does not need to: the desktop mints
   * one shape of token for every client, so the same six digits are a legitimate
   * direct token as well as a possible rendezvous.
   *
   * Relay first and origin second, because the relay is the route that works
   * from anywhere and the origin only works when this page came from the
   * machine. Doing it the other way round would send every code to whatever
   * happens to be serving this page.
   *
   * It is two attempts and one sentence. The fallback is invisible unless it
   * works, and if neither reaches anything the banner is the connection's own
   * account of the second attempt rather than a summary written here.
   */
  private async startPairing(typed: string): Promise<void> {
    if (this.looking) return
    const code = normaliseCode(typed)
    if (code === null) {
      this.pairNotice('That is not a pairing code. It is six digits, like 123456.')
      return
    }

    this.looking = true
    this.pairNotice('Looking for that machine…')
    this.renderContent()
    let found: Awaited<ReturnType<typeof lookupMachine>> = null
    try {
      found = await lookupMachine({ code })
    } catch {
      // `lookupMachine` answers null for every ordinary failure, so reaching
      // here means the derivation itself could not run — a browser with no
      // `crypto.getRandomValues`, essentially. Caught rather than left to become
      // an unhandled rejection, because the only visible effect of one of those
      // is a button that stops saying "Looking…" and nothing else happening.
      this.looking = false
      this.renderContent()
      this.pairNotice('This browser could not run the pairing crypto, so nothing was sent.')
      return
    } finally {
      this.looking = false
    }
    this.renderContent()
    // The code is the pairing token as well as the address, which is the whole
    // shape of this scheme: `device-auth.ts` hashes what was typed and never
    // learns where it was looked up.
    this.connect(code, found ?? DIRECT)
  }

  /** One sentence on the pair screen, in the banner that is already there. */
  private pairNotice(detail: string): void {
    this.state = { phase: 'offline', detail, retryAt: null, attempts: 0 }
    this.renderBanner()
  }

  private sessionsScreen(): HTMLElement {
    const screen = element('div', 'screen')
    screen.style.padding = '0'

    if (this.notice !== null) {
      screen.append(element('p', 'empty', this.notice))
    }

    const start = this.startBlock()
    if (start !== null) screen.append(start)

    if (this.sessions.length === 0) {
      screen.append(
        element(
          'p',
          'empty',
          this.state.phase === 'online'
            ? `No sessions are running on the ${this.noun}.`
            : `No sessions to show yet — this list is from the last time the ${this.noun} answered.`,
        ),
      )
    }

    const list = element('ul', 'sessions')
    const now = Date.now()
    for (const session of sortSessions(this.sessions, this.activity)) {
      const row = element('li')
      const button = element('button', 'session')
      button.type = 'button'

      const dot = element('span', `session__dot session__dot--${sessionTone(session)}`)
      const body = element('div', 'session__body')
      body.append(element('div', 'session__title', session.title))

      const since = formatSince(now, this.activity.get(session.id) ?? null)
      const meta = element('div', 'session__meta')
      // The time is only printed when one is actually known — see formatSince.
      meta.textContent = [statusLabel(session), since, shortenPath(session.cwd)]
        .filter((part): part is string => part !== null)
        .join(' · ')
      body.append(meta)

      button.append(dot, body, element('span', 'session__chevron', '›'))
      button.addEventListener('click', () => this.openSession(session.id))
      row.append(button)
      list.append(row)
    }
    screen.append(list)

    const lifetime = this.lifetimeBlock()
    if (lifetime !== null) screen.append(lifetime)

    const forget = element('button', 'button button--quiet', `Forget this ${this.noun}`)
    forget.type = 'button'
    forget.style.margin = '20px 16px'
    forget.style.width = 'auto'
    forget.addEventListener('click', () => this.forget())
    screen.append(forget)
    return screen
  }

  /**
   * What the machine is serving, and whether it is answering.
   *
   * Everything on this screen is a value out of `localhost.ts`, including every
   * sentence — the rows, the three outcomes of a check, the empty states, and the
   * paragraph explaining why there is no button that opens a page. That is not
   * tidiness: a wording decision written into this file is one nothing can check,
   * and the sentence at the bottom of this screen is the one that has to stay
   * honest as the feature changes around it.
   *
   * The order of the page is the order of the questions. What is listening, then
   * one press per port to find out whether it really answers, then — last,
   * because it is the answer to a question somebody asks after they have looked
   * — why this client stops there.
   */
  private localhostScreen(): HTMLElement {
    const screen = element('div', 'screen')
    // Edge to edge, like the session list it sits beside: the rows carry their
    // own gutters so a row highlights across the full width of the column.
    screen.style.padding = '0'
    const { ports, listing, checking, outcome } = this.localhost
    const online = this.state.phase === 'online'

    // No heading. The tab above already says Localhost, and a title repeating
    // the control that got you here is exactly the "nothing extra" this pass was
    // asked for. Refresh exists only while there is a socket to carry it — the
    // standing rule against a control whose only function is to explain that it
    // does not function — so offline there is no row here at all rather than an
    // empty one, and the sentence under the list says how old it is instead.
    if (online) {
      const heading = element('div', 'localhost__head')
      const refresh = element('button', 'button button--quiet localhost__refresh', listing ? 'Asking…' : 'Refresh')
      refresh.type = 'button'
      refresh.disabled = listing
      refresh.addEventListener('click', () => this.localhostDo({ t: 'list' }))
      heading.append(refresh)
      screen.append(heading)
    }

    if (ports === null) {
      screen.append(
        element(
          'p',
          'empty',
          listing
            ? `Asking the ${this.noun} what is listening…`
            : `The ${this.noun} has not said what it is serving yet.`,
        ),
      )
    } else if (ports.length === 0) {
      screen.append(element('p', 'empty', noPortsSentence(this.noun)))
    } else {
      const list = element('ul', 'ports')
      for (const port of ports) {
        const row = element('li', 'port')
        const line = element('div', 'port__line')
        line.append(element('span', 'port__label', portLabel(port)))

        // One check at a time, and only with a socket. A second Check pressed
        // while one is running is refused by the machine itself; disabling it
        // is what stops somebody pressing a button that does nothing.
        if (online) {
          const here = checking?.port === port.port
          const check = element('button', 'port__check', here ? 'Checking…' : 'Check')
          check.type = 'button'
          check.disabled = checking !== null
          check.addEventListener('click', () => {
            this.checks += 1
            this.localhostDo({ t: 'check', port: port.port, id: `localhost-${this.checks}` })
          })
          line.append(check)
        }
        row.append(line)

        // The answer sits under the port it is about. A single result line at
        // the foot of the list would be correct and unreadable: three ports in,
        // nobody can tell which one "it answered" is about.
        if (outcome !== null && outcome.port === port.port) {
          const said = element(
            'p',
            outcome.kind === 'answered' ? 'port__result port__result--ok' : 'port__result',
            // Through `plain` like every other string that came off this socket:
            // a refusal is composed on the desktop, and this end is the one that
            // pays if that ever stops being true.
            plain(checkSentence(outcome, this.noun)),
          )
          row.append(said)
        }
        list.append(row)
      }
      screen.append(list)

      if (!online) screen.append(element('p', 'note localhost__note', stalePortsSentence(this.noun)))
    }

    screen.append(element('p', 'note localhost__note', cannotServeSentence(this.noun)))
    return screen
  }

  /**
   * What this browser is holding and for how long, plus the one press that
   * changes it.
   *
   * The question on the pair screen is answered once, in a hurry, by somebody
   * who is mid-task and standing at a second computer. Leaving it there would
   * make it a decision with no way back: a person who ticked "remember" on a
   * machine they later realised was not theirs would have to unpair and repair,
   * from the desktop, to undo it — and someone who chose "just for this visit"
   * on their own laptop would re-pair every morning without ever finding out
   * why.
   *
   * So it is stated where the pairing is, in the sentence that says what it
   * means rather than the name of a setting, and the button is the *action*
   * rather than a toggle: nobody has to work out which way a switch is pointing.
   * Nothing here is a second copy of the state — both halves read `remember`,
   * which is what `loadPairing` found in whichever store answered.
   */
  private lifetimeBlock(): HTMLElement | null {
    if (this.credential === null) return null
    const days = Math.round(REMEMBERED_TTL_MS / 86_400_000)
    const remembered = this.remember === 'this-browser'

    const block = element('section', 'lifetime')
    block.append(
      element(
        'p',
        'lifetime__note',
        remembered
          ? `This browser stays paired until you unpair it, or ${days} days pass without using it.`
          : 'This pairing ends when you close this tab. Nothing is left on this computer.',
      ),
    )

    const change = element(
      'button',
      'button button--quiet',
      remembered ? 'Stop remembering this browser' : 'Remember this browser',
    )
    change.type = 'button'
    change.addEventListener('click', () => {
      this.remember = remembered ? 'this-tab' : 'this-browser'
      // Moves the credential *and* this browser's key into the other store and
      // clears the one they came from — `savePairing` is the only thing that
      // touches either, precisely so the two cannot end up in different places.
      this.keep()
      this.renderContent()
    })
    block.append(change)
    return block
  }

  /**
   * New session, and the folders it may start in.
   *
   * Absent rather than disabled in the two cases where it cannot work — a
   * desktop that never advertised `create`, and a socket that is not up. That
   * is the design brief's rule and the repo's: a control whose only function is
   * to explain that it does not function is a fake feature.
   *
   * The third case is different in kind. A desktop that has granted this device
   * *no* folders is not broken and has not lost anything; it will simply refuse
   * every session this phone could ask for. What that state needs is not a
   * button but the sentence naming the machine and the screen where folders are
   * chosen — which is the whole of the bug being fixed here, since the version
   * of this app that showed one unexplained folder had nothing to say about
   * where the list came from either.
   */
  private startBlock(): HTMLElement | null {
    if (this.state.phase !== 'online' || !this.capabilities.includes('create')) return null

    const block = element('section', 'start')
    // The platform decides how two spellings of one path are compared — NTFS
    // does not distinguish case and a POSIX filesystem does. See `samePath`.
    const offer = folderOffer(this.folders, this.sessions, this.hostPlatform)
    if (offer.kind === 'none') {
      block.append(element('p', 'start__note', noFoldersSentence(this.noun)))
      return block
    }

    const rows = pickerRows(offer, this.noun)
    const label = this.awaitingCreate ? 'Starting…' : 'New session'

    // One destination is not a choice, so it is not drawn as one — the standing
    // rule against a picker with a single item in it. The folder goes under the
    // button instead of behind it, which puts the thing the old picker never
    // managed to say — *where this is about to start* — on screen before the
    // tap rather than after it.
    if (rows.length === 1) {
      const only = rows[0]
      const button = element('button', 'button', label)
      button.type = 'button'
      button.disabled = this.awaitingCreate
      button.addEventListener('click', () => this.startSession(only.folder))
      block.append(button)
      if (only.path) {
        // "Starts in" in the interface face, the path in mono. A bare path under
        // a button is ambiguous — it reads as easily as "you are here" — and the
        // two words are what make it a promise about the tap.
        const where = element('p', 'start__where')
        const path = element('span', undefined, only.label)
        // The line ellipsises, and a deep path is longer than a phone. The same
        // escape hatch the desktop's folder panel uses, for the same reason: a
        // browser adds no tooltip to overflowing text on its own, and this same
        // client is opened from a keyboard as often as from a phone.
        path.title = only.label
        where.append(element('span', 'start__where-label', 'Starts in'), path)
        block.append(where)
      }
      return block
    }

    const toggle = element('button', 'button', label)
    toggle.type = 'button'
    toggle.disabled = this.awaitingCreate
    toggle.setAttribute('aria-expanded', this.picking ? 'true' : 'false')
    toggle.addEventListener('click', () => {
      this.picking = !this.picking
      this.renderContent()
    })
    block.append(toggle)
    if (!this.picking) return block

    // Two words over the list, because three paths under a button are not
    // self-explanatory to somebody who has never seen this screen — and that is
    // the bar the design brief sets.
    block.append(element('p', 'start__caption', 'Start in'))
    const list = element('ul', 'start__folders')
    for (const row of rows) {
      const item = element('li')
      // The path is mono and the sentence is not: monospace is a promise that
      // the characters are exact and countable, which is true of a path and not
      // of "Wherever the Mac would".
      const choice = element('button', row.path ? 'start__folder start__folder--path' : 'start__folder', row.label)
      choice.type = 'button'
      // Two projects can share a last segment, so the whole value has to stay
      // reachable from a row that ellipsises — see the note on the line above.
      if (row.path) choice.title = row.label
      choice.addEventListener('click', () => this.startSession(row.folder))
      item.append(choice)
      list.append(item)
    }
    block.append(list)
    return block
  }

  /**
   * Ask the desktop for a session.
   *
   * No size travels with it, unlike `attach`. There is no emulator on this
   * screen to measure — the desktop starts at its own default and the attach a
   * frame later carries the real shape, which is the same correction every
   * client makes for a session it did not start.
   */
  private startSession(folder: string | null): void {
    if (this.awaitingCreate) return
    this.picking = false
    this.notice = null
    const sent =
      folder === null ? this.connection?.send({ t: 'create' }) : this.connection?.send({ t: 'create', cwd: folder })
    if (sent !== true) {
      // Said, not swallowed. The refusal above is a socket that went down
      // between the render and the tap, and a button that does nothing at all
      // is indistinguishable from one that is broken.
      this.notice = `That did not reach the ${this.noun}, so nothing was started.`
      this.renderContent()
      return
    }
    this.awaitingCreate = true
    this.renderContent()
  }

  /* ------------------------------------------------------------ terminal -- */

  private openSession(id: string): void {
    if (this.connection === null) return
    this.attachedId = id
    this.attachSent = false
    this.notice = null
    this.screen = 'terminal'
    this.buildTerminal()
    this.render()
    // A frame later, so the terminal has a box to measure. Attaching before
    // that would send a size of zero and then correct it, and the correction
    // reflows scrollback that has already been painted.
    requestAnimationFrame(() => {
      this.terminal?.fit()
      this.attach(id)
      this.terminal?.focus()
    })
  }

  /**
   * Ask for a session, carrying the size the phone actually is.
   *
   * The protocol lets `attach` take cols and rows precisely so the first screen
   * arrives the right shape — both or neither, never one.
   */
  private attach(id: string): void {
    const size = this.terminal?.size()
    const sent =
      size === undefined
        ? this.connection?.send({ t: 'attach', id })
        : this.connection?.send({ t: 'attach', id, cols: size.cols, rows: size.rows })
    this.attachSent = sent === true
  }

  private leaveTerminal(): void {
    if (this.attachedId !== null) this.connection?.send({ t: 'detach', id: this.attachedId })
    this.attachedId = null
    this.attachSent = false
    this.destroyTerminal()
    this.screen = 'sessions'
    this.connection?.send({ t: 'list' })
    this.render()
  }

  private buildTerminal(): void {
    this.destroyTerminal()

    const terminal = createTerminal({
      onData: (data) => this.sendInput(data),
      onResize: (size) => {
        // Only after the attach has gone out. A resize for a session the
        // server has not given us yet is answered with `unknown-session`.
        if (this.attachedId !== null && this.attachSent) {
          this.connection?.send({ t: 'resize', id: this.attachedId, cols: size.cols, rows: size.rows })
        }
      },
    })
    const keybar = createKeyBar({ onData: (data) => this.sendInput(data) })

    const dock = element('div', 'keybar-dock')
    dock.append(keybar.element)

    const screen = element('div', 'terminal-screen')
    screen.append(terminal.element, dock)

    this.terminal = terminal
    this.keybar = keybar
    this.keybarDock = dock
    this.terminalScreen = screen
    // Before the first paint, so a laptop never sees the row appear and go. It
    // is a fill of the frame's height either way, and a bar that flashes on for
    // one frame reads as a rendering fault rather than as a decision.
    this.applyKeyBar()
    terminal.setLive(this.state.phase === 'online')
  }

  private showTerminalScreen(): void {
    if (this.terminalScreen === null) return
    this.content.replaceChildren(this.terminalScreen)
  }

  private destroyTerminal(): void {
    this.keybar?.destroy()
    this.terminal?.dispose()
    this.keybar = null
    this.keybarDock = null
    this.terminal = null
    this.terminalScreen = null
  }

  /**
   * One keystroke or paste on its way to the desktop.
   *
   * Characters are folded through the key bar's armed modifier first, so a
   * Ctrl tapped on the toolbar combines with the letter typed on the soft
   * keyboard — the only place those two can meet, because the soft keyboard
   * reports no modifier we did not press ourselves.
   */
  private sendInput(data: string): void {
    if (this.attachedId === null) return
    const folded = data.length === 1 && this.keybar !== null ? this.keybar.handleCharacter(data) : data

    for (const chunk of chunkInput(folded)) {
      if (!this.connection?.send({ t: 'input', id: this.attachedId, data: chunk })) {
        // Refused rather than queued. Say so where the user is looking instead
        // of letting them believe a keystroke landed.
        //
        // Built from the connection's own sentence rather than from whatever
        // this banner is currently showing: appending to the latter meant every
        // key pressed while the socket was down added another copy of this
        // clause, and someone typing a command into a dead terminal produced a
        // banner of a dozen identical sentences.
        const detail = this.connection?.current().detail ?? this.state.detail
        this.state = { ...this.state, detail: `${detail} That keystroke was not sent.` }
        this.renderBanner()
        return
      }
    }
  }

  private forget(): void {
    clearPairing(this.stores)
    this.credential = null
    // Back to the safe answer. The next pairing on this browser asks again, and
    // it must not inherit "remember" from a machine this person has just said is
    // not theirs any more.
    this.remember = 'this-tab'
    // The route goes with the machine. Keeping a relay endpoint after the user
    // has said "that is not my machine any more" would put its host id under the
    // title on the pair screen.
    this.endpoint = DIRECT
    // Deliberately reset here and deliberately *not* reset on a refusal. This
    // is the user saying "that is not my machine any more", so the next pair
    // screen must not still be naming it; a refused credential, by contrast, is
    // the same computer at the same address telling us something, and keeping
    // its noun makes the re-pair read correctly.
    this.hostPlatform = 'unknown'
    this.capabilities = []
    this.folders = null
    this.picking = false
    this.awaitingCreate = false
    this.forgetLocalhost()
    this.sessions = []
    this.activity.clear()
    this.attachedId = null
    this.destroyTerminal()
    this.connection?.stop()
    this.connection = null
    this.screen = 'pair'
    this.render()
  }

  /* ------------------------------------------------------------ viewport -- */

  /**
   * Keep the frame inside the visual viewport.
   *
   * The soft keyboard on iOS does not shrink the layout viewport, so a bar at
   * the bottom of a full-height frame ends up underneath the keys. The visual
   * viewport is the part actually on screen; sizing to it puts the key bar
   * directly above the keyboard, which is the whole point of having one.
   */
  private watchViewport(): void {
    const viewport = window.visualViewport
    const apply = (): void => {
      if (viewport !== null) {
        this.root.style.height = `${viewport.height}px`
        this.root.style.transform = `translateY(${viewport.offsetTop}px)`
        const keyboard = window.innerHeight - viewport.height - viewport.offsetTop
        // The keyboard already covers the home-indicator strip; padding for it
        // as well lifts the bar visibly off the keys.
        this.root.style.setProperty('--dock-safe', keyboard > 24 ? '0px' : 'env(safe-area-inset-bottom, 0px)')
      }
      this.terminal?.fit()
    }

    if (viewport !== null) {
      viewport.addEventListener('resize', apply)
      viewport.addEventListener('scroll', apply)
    }
    window.addEventListener('resize', apply)
    window.addEventListener('orientationchange', () => requestAnimationFrame(apply))
    apply()
  }
}

/* --------------------------------------------------------------- bootstrap -- */

const root = document.getElementById('app')
if (root !== null) new Deck(root).start()

/**
 * The shell, and only the shell.
 *
 * Registered after load so it never competes with the first paint on a phone
 * that has just been handed a QR code. Failure is silent on purpose: a client
 * that works but cannot be installed offline is fine, and an error dialog about
 * a service worker is not something anyone can act on.
 */
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => undefined)
  })
}
