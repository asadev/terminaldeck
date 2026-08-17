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
import {
  NO_DEV,
  cannotOpenSentence,
  devRowView,
  devStep,
  devWaitingSentence,
  devserverOffered,
  type DevAction,
  type DevState,
} from './dev-server'
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
  stalePortsSentence,
  type LocalhostAction,
  type LocalhostState,
} from './localhost'
import {
  MACHINES_FOOTNOTE,
  clearBook as clearMachineBook,
  cleanNickname,
  currentMachine,
  endpointSummary,
  forgetMachine,
  lastReachedSentence,
  loadMachines,
  machineById,
  machineId,
  machineLabel,
  MAX_NICKNAME_LENGTH,
  NO_MACHINES,
  renameMachine,
  saveBook,
  selectMachine,
  withCredential,
  withMachine,
  type MachineBook,
  type StoredMachine,
} from './machines'
import { watchPhysicalKeyboard, type KeyBarFit, type MatchMedia } from './physical-keyboard'
import {
  clearPairing,
  describeDevice,
  REMEMBERED_TTL_MS,
  renewed,
  savePairing,
  type StoredCredential,
} from './pair'
import {
  NAMING_FOOTNOTE,
  categoryTitle,
  directAppPorts,
  portRowDetail,
  portRowTitle,
  secondAction,
  sections as portSections,
  type LocalhostRow,
  type LocalhostSection,
} from './port-catalog'
import { MAX_NAME_LENGTH, PortBook } from './port-book'
import {
  canGoLarger,
  canGoSmaller,
  largerText,
  readTextSize,
  smallerText,
  textSizeLabel,
  writeTextSize,
} from './text-size'
import { normaliseCode } from '../../src/shared/short-code'
import { asCodeField } from './code-field'
import { browserStores, type Remember } from './remember'
import { relaySocket } from './relay-socket'
import { lookupMachine } from './rendezvous'
import { chunkInput, type DevServerReport, type RemoteSession, type ServerMessage } from './protocol-client'
import { formatSince, sessionTone, shortenPath, sortSessions, statusLabel } from './sessions'
import { createTerminal, type TerminalHandle } from './terminal'
import {
  THEME_CHOICES,
  THEME_COLOR,
  THEME_DESCRIPTION,
  THEME_LABEL,
  readChoice,
  resolveAppearance,
  stampAppearance,
  watchSystemAppearance,
  writeChoice,
  type Appearance,
  type SystemAppearance,
  type ThemeChoice,
} from './theme'

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
type Screen = 'pair' | 'sessions' | 'localhost' | 'settings' | 'machines' | 'terminal'

/**
 * The three tabs, and why Machines is not one of them.
 *
 * The phone answered this first and the answer is followed rather than
 * re-litigated — see the header of `ios/TerminalDeck/Screens/DeckTabs.swift`, which
 * records him asking for four pills and then moving Machines off the bar a minute
 * later because pairing a machine is something done once, and a strip of tabs is
 * for the screens somebody moves between all day.
 *
 * So: Sessions, Localhost, Settings — and Machines is a screen pushed from
 * Settings, reached by a chevron row that says how many are paired. The one place
 * this client differs is that the strip stays visible on the Machines screen,
 * which is the same call the phone makes ("Pill should be on here only on the
 * homepage or machines or settings") for the same reason: a person who has pushed
 * one screen deep has not left the app.
 */
const LISTING_SCREENS: readonly Screen[] = ['sessions', 'localhost', 'settings', 'machines']

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
   * Auto / Light / Dark, in the header rather than in a settings block.
   *
   * Part of the chrome and not of a screen, for the same reason the tab strip
   * is: it has to survive every screen it is drawn over, and it has to be
   * reachable before pairing — the pair screen is the first thing a new reader
   * sees, and it is a whole screen of paper or charcoal with nothing else on it.
   */
  private readonly appearanceStrip = element('div', 'appearance')
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
  /**
   * A sentence that has been said and will stop being said.
   *
   * The only floating thing in this client, and it is here rather than inside a
   * screen for the same reason the tab strip is: it is raised by a control on a
   * row that the very next frame from the desktop will rebuild, and a message
   * living inside that row would disappear with it before anybody read it.
   *
   * `aria-live` rather than a role, because it is an aside — nothing here is ever
   * the only place something is said, and a screen reader should mention it
   * without abandoning what the reader was on.
   */
  private readonly toast = element('div', 'toast')

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
  /**
   * Every machine this browser is paired with, and which one it is talking to.
   *
   * This used to be a single `StoredCredential`, and the whole of `machines.ts`
   * exists to explain why one was not enough once the phone grew a Machines
   * screen. Everything that reads "the credential" below now reads
   * `this.credential`, which is the current machine's — so the connection, the
   * banner, the session list and the terminal are untouched by the change. What
   * moved is only the answer to *which* machine.
   */
  private book: MachineBook = NO_MACHINES
  /**
   * The names this browser has given ports, and the groups it has folded, per
   * machine. See `port-book.ts`; the grouping that reads it is `port-catalog.ts`.
   *
   * Made in the constructor rather than here because it needs `this.stores`, and a
   * field initialiser cannot see another field that is declared after it.
   */
  private readonly portBook: PortBook
  /**
   * How big the terminal's characters are. See `text-size.ts`, which owns the
   * bounds and says why a browser needs this control when a phone barely does.
   */
  private textSize: number
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
  /** One row per project that can be served, and the start in flight. See `dev-server.ts`. */
  private dev: DevState = NO_DEV
  /**
   * The appearance, as the person answered it and as it is painted.
   *
   * Two fields rather than one, because they are two different facts: `system`
   * is a real answer and is not a palette. See `theme.ts`, which owns the whole
   * question and explains why the resolution happens here rather than in a
   * media query.
   */
  private themeChoice: ThemeChoice = 'system'
  private appearance: Appearance = 'dark'
  /** The `prefers-color-scheme` subscription, so a machine can change its mind. */
  private systemAppearance: SystemAppearance | null = null
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
  /**
   * The row whose actions are showing, by `LocalhostRow.id` or machine id.
   *
   * One at a time and held here rather than on the row, because the list is
   * rebuilt from scratch on every frame the desktop pushes — a flag living in the
   * DOM would be wiped by the next `ports` answer, which on this screen arrives
   * while somebody's finger is still on the button.
   */
  private openRow: string | null = null
  /** The port being renamed, and the text so far. See `port-book.ts`. */
  private renamingPort: number | null = null
  /** The machine being renamed, by id. */
  private renamingMachine: string | null = null
  /** What a rename field holds. Kept here so a redraw does not empty it. */
  private renameText = ''
  /**
   * A message that has been said and will stop being said.
   *
   * Copying an address is silent by nature; without this the action feels broken
   * even when it worked. The same two and a half seconds the phone waits.
   */
  private toastText: string | null = null
  private toastTimer: number | null = null
  /**
   * Set while the pair screen was reached from the Machines screen rather than by
   * having no machines at all.
   *
   * It is the difference between a first run and adding a second machine, and the
   * only thing it changes is whether there is a way back — a person part-way
   * through pairing a second machine must be able to abandon it without being
   * stranded on a screen that looks like they have been signed out.
   */
  private pairingAnother = false

  constructor(root: HTMLElement) {
    this.root = root
    document.title = BRAND.name
    this.portBook = new PortBook(this.stores, this.remember)
    this.textSize = readTextSize(this.stores.browser)

    this.back.type = 'button'
    this.back.setAttribute('aria-label', 'Back')
    this.back.addEventListener('click', () => this.goBack())

    const titles = element('div', 'header__titles')
    titles.append(this.title, this.subtitle)
    this.header.append(this.back, titles, this.appearanceStrip)

    this.bannerAction.type = 'button'
    this.bannerAction.addEventListener('click', () => this.connection?.resume())
    this.banner.append(this.bannerText, this.bannerAction)

    this.toast.hidden = true
    this.toast.setAttribute('aria-live', 'polite')

    root.append(this.header, this.banner, this.credentialCard, this.tabs, this.content, this.toast)
  }

  /* ------------------------------------------------------------- startup -- */

  start(): void {
    // Before anything is drawn. Everything below paints in whichever appearance
    // this settles on, and a page that renders once in the wrong one and then
    // corrects itself is a flash somebody sees on every visit.
    this.startTheme()

    // The book, or the single pairing every browser that has used this client
    // before is holding. `loadMachines` owns that migration and explains it.
    const found = loadMachines(this.stores, Date.now())
    this.book = found?.book ?? NO_MACHINES
    this.remember = found?.remember ?? 'this-tab'
    // Both follow whichever machine is current. Held as fields rather than read
    // through the book on every access because they are answered before the first
    // socket exists — the pair screen has no connection by definition — and
    // because `welcome` writes `hostPlatform` before the credential is rebuilt.
    this.hostPlatform = this.credential?.hostPlatform ?? 'unknown'
    this.endpoint = this.credential?.endpoint ?? DIRECT
    // The book is written where the pairing chose, so it has to be told which
    // that was before anything can change a name.
    this.portBook.setLifetime(this.remember)

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

  /* ------------------------------------------------------------ machines -- */

  /** The machine this browser is talking to, or null when there are none. */
  private get machine(): StoredMachine | null {
    return currentMachine(this.book)
  }

  /**
   * The current machine's credential.
   *
   * A getter rather than the field it used to be, so that every one of the two
   * dozen places below that ask "are we paired" keeps working unchanged while the
   * answer moves from *the* pairing to *this* pairing. Writing one goes through
   * `putCredential`, which knows the difference between renewing the machine on
   * screen and minting one for a machine being added.
   */
  private get credential(): StoredCredential | null {
    return this.machine?.credential ?? null
  }

  /**
   * Which machine the connection is currently pointed at, whether or not this
   * browser has a credential for it yet.
   *
   * The distinction matters exactly once, and it is the case that would otherwise
   * be a real bug: while a *second* machine is being paired, `this.endpoint` is the
   * new machine and `this.machine` is still the old one, so a credential written
   * against "the current machine" would overwrite the pairing somebody is using
   * with a token for a different computer.
   */
  private get dialledId(): string {
    return machineId(this.endpoint)
  }

  /**
   * Put a credential in the book against the machine it is actually for.
   *
   * Adds the machine when it is new — which is what makes "pair another machine" a
   * feature rather than a re-pair — and updates it in place when it is not, which
   * is what makes a renewed credential keep the nickname, the position in the list
   * and, because `port-book.ts` keys on the same id, the names its ports were
   * given.
   */
  private putCredential(credential: StoredCredential): void {
    const id = this.dialledId
    const known = machineById(this.book, id)
    // A machine is never *added* on a credential with no token in it. `welcome`
    // can arrive before `credential` has been redeemed on a route that has not
    // been seen, and a row written from that frame would be a machine in the list
    // that nothing can reconnect to — `loadCredential` refuses an empty token on
    // the way back in, so it would also vanish at the next launch with no
    // explanation. Renewing a machine that already has one is a different thing
    // and is allowed: the token is carried over by the caller.
    if (known === null && credential.token === '') return
    this.book = known === null
      ? withMachine(this.book, { id, nickname: null, credential })
      : selectMachine(withCredential(this.book, id, credential), id)
    this.keep()
  }

  /**
   * Talk to another machine.
   *
   * Everything the old machine told this browser goes with it, and that is the
   * whole method. A session list, a folder list, a port list and a capability set
   * are each a statement about *one* desktop, and carrying any of them across
   * would put the previous machine's sessions on screen under the new one's name —
   * which is the same stale truth the offline banner exists to prevent, with a
   * worse failure attached: tapping one of those rows would attach to an id the
   * new machine has never heard of.
   */
  private switchTo(id: string): void {
    const machine = machineById(this.book, id)
    if (machine === null || id === this.book.currentId) return
    this.connection?.stop()
    this.connection = null
    this.book = selectMachine(this.book, id)
    this.keep()

    this.sessions = []
    this.activity.clear()
    this.capabilities = []
    this.folders = null
    this.picking = false
    this.awaitingCreate = false
    this.notice = null
    this.credentialAsk = null
    this.openRow = null
    this.attachedId = null
    this.destroyTerminal()
    this.forgetLocalhost()

    this.hostPlatform = machine.credential.hostPlatform
    this.state = { phase: 'connecting', detail: `Connecting to ${machineLabel(machine, this.origin)}…`, retryAt: null, attempts: 0 }
    this.screen = 'sessions'
    this.render()
    this.connect(machine.credential.token, machine.credential.endpoint)
  }

  /**
   * Forget one machine, and only that one.
   *
   * The last machine is the interesting case: forgetting it is the old `forget()`
   * in full — every store cleared, the terminal destroyed, back to the pair screen
   * — because a browser with no machines is an unpaired browser. Forgetting one of
   * several is a much smaller event, and the promise the screen makes is that it
   * leaves every other machine alone.
   */
  private forgetMachine(id: string): void {
    if (machineById(this.book, id) === null) return
    const wasCurrent = id === this.book.currentId
    const next = forgetMachine(this.book, id)
    if (next.machines.length === 0) {
      this.forget()
      return
    }
    this.book = next
    this.keep()
    if (!wasCurrent) {
      this.render()
      return
    }
    // The machine being talked to has just been forgotten, so the socket has to
    // go before anything else — `switchTo` refuses a machine that is already
    // current, and after `forgetMachine` the current id is a different machine.
    this.connection?.stop()
    this.connection = null
    const moved = next.currentId
    this.book = { ...next, currentId: null }
    if (moved !== null) this.switchTo(moved)
  }

  /** The address this page was served from, for the rows that name it. */
  private get origin(): string {
    return window.location.host
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

  /* --------------------------------------------------------------- theme -- */

  /**
   * Settle the appearance, and keep following the machine if that is the answer.
   *
   * The stored choice comes out of `localStorage` rather than out of whichever
   * store the pairing chose — see `theme.ts`, which explains why a preference and
   * a bearer credential do not belong under the same rule.
   *
   * `matchMedia` is passed rather than reached for, the same way
   * `watchPhysicalKeyboard` takes it: that is what keeps the decision in a file
   * the suite can ask questions of.
   */
  private startTheme(): void {
    this.themeChoice = readChoice(this.stores.browser)
    const media: MatchMedia | undefined =
      typeof window.matchMedia === 'function' ? (query) => window.matchMedia(query) : undefined
    this.systemAppearance = watchSystemAppearance(media, () => {
      // Only while the answer is "follow the machine". A person who chose light
      // has said something this must not overrule, and the listener stays
      // subscribed rather than being torn down and rebuilt as the choice moves.
      if (this.themeChoice === 'system') this.applyAppearance()
    })
    this.applyAppearance()
  }

  /**
   * Paint the resolved appearance everywhere it has to be painted.
   *
   * Three places, and the third is the one that gets forgotten: the document,
   * the browser's own chrome, and **the emulator**. xterm takes a colour object
   * rather than reading the cascade, so a client that stamped the attribute and
   * stopped would leave a dark terminal in a white window — which looks like a
   * bug rather than like a choice, and is the failure this whole feature is
   * judged on.
   */
  private applyAppearance(): void {
    this.appearance = resolveAppearance(this.themeChoice, this.systemAppearance?.dark ?? true)
    stampAppearance(document.documentElement, this.appearance)
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta !== null) meta.setAttribute('content', THEME_COLOR[this.appearance])
    this.terminal?.setAppearance(this.appearance)
    this.renderAppearance()
  }

  /** The person moved the switch. */
  private chooseTheme(choice: ThemeChoice): void {
    if (choice === this.themeChoice) return
    this.themeChoice = choice
    writeChoice(this.stores.browser, choice)
    this.applyAppearance()
  }

  /**
   * The three pills, redrawn from the one source of truth.
   *
   * `aria-pressed` rather than `aria-current`: these are not two places to be,
   * they are one setting with three values, and the pressed state is what a
   * screen reader needs to say which one is on.
   */
  private renderAppearance(): void {
    this.appearanceStrip.replaceChildren(
      ...THEME_CHOICES.map((choice) => {
        const here = this.themeChoice === choice
        const pill = element(
          'button',
          here ? 'appearance__choice appearance__choice--here' : 'appearance__choice',
          THEME_LABEL[choice],
        )
        pill.type = 'button'
        pill.setAttribute('aria-pressed', here ? 'true' : 'false')
        // The label is two syllables because it lives in a phone's header; the
        // sentence that says what it actually does is free here.
        pill.setAttribute('aria-label', THEME_DESCRIPTION[choice])
        pill.addEventListener('click', () => this.chooseTheme(choice))
        return pill
      }),
    )
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
    // And a dev server left reading "Starting…" against a dead socket. The
    // server itself may well still be starting on the desktop — which is what
    // the re-ask on reconnect below is for.
    if (state.phase !== 'online') this.devDo({ t: 'offline' })

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
      // Same for the projects, and it is also what re-subscribes: the desktop
      // pushes a folder's changes only to connections that have asked about it
      // *on this connection*, so a reconnected client that did not re-ask would
      // draw rows that never change again.
      if (this.screen === 'localhost') this.askDevServers()
    }

    if (state.phase === 'rejected') {
      // The credential is no good. Holding on to it would mean every launch
      // fails the same way with no route back to pairing — and on a computer
      // that is not this person's, it would be a dead secret left in a profile
      // somebody else will open.
      //
      // **Only the machine that refused it.** This used to clear both stores
      // outright, which was right when there was one pairing and is wrong now: a
      // Mac that has revoked this browser says nothing whatsoever about the PC in
      // the next room, and signing somebody out of every machine because one of
      // them was re-imaged would be the client throwing away work it was told
      // nothing about. `forgetMachine` falls through to the full `forget()` when
      // that machine was the only one, which is the old behaviour exactly.
      const refused = this.dialledId
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
      this.sessions = []
      this.activity.clear()
      // Said only when there is somewhere to say it. With one machine this ends
      // on the pair screen, where the banner is already carrying the desktop's
      // own account of the refusal, and a second sentence parked on a session
      // list nobody will see again would be waiting for the next person to pair.
      if (this.book.machines.length > 1) {
        this.notice = `That ${this.noun} no longer recognises this browser, so it has been forgotten.`
      }
      // Which either moves to whatever is left, or — when that machine was the
      // only one — clears every store and lands on the pair screen, exactly as
      // this branch always did.
      this.forgetMachine(refused)
      return
    }

    this.terminal?.setLive(state.phase === 'online')
    this.renderBanner()
    // Every list screen redraws: what they offer — New session, Refresh, Check,
    // the machine rows' own status line — is drawn from the connection.
    if (LISTING_SCREENS.includes(this.screen)) this.renderContent()
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

  /* --------------------------------------------------------- dev servers -- */

  /**
   * One transition of the dev-server machine, and the frames it asked for.
   *
   * `localhostDo`'s twin, and deliberately its twin: the rules live in
   * `dev-server.ts` where the suite can reach them, and everything here is
   * delivery. A frame that does not reach the desktop puts the machine straight
   * back to its offline state rather than leaving a button spinning — the banner
   * is already saying why, in the desktop's own words.
   */
  private devDo(action: DevAction): void {
    const step = devStep(this.dev, action)
    if (step.state === this.dev && step.send.length === 0) return
    this.dev = step.state

    for (const message of step.send) {
      if (this.connection?.send(message) === true) continue
      this.dev = devStep(this.dev, { t: 'offline' }).state
      break
    }

    if (this.screen === 'localhost') this.renderContent()
  }

  /**
   * Ask the desktop about every folder it is offering this device.
   *
   * Sent on arrival at the screen, on reconnect while looking at it, and when
   * the folder list itself changes — never on a timer. After one of these the
   * desktop pushes that folder's changes on its own, so a client with a poll
   * loop would be asking a question that is already being answered.
   */
  private askDevServers(): void {
    if (!devserverOffered(this.capabilities) || this.state.phase !== 'online') return
    this.devDo({ t: 'ask', folders: this.folders ?? [] })
  }

  /**
   * Everything this client knew about what the machine was serving — the ports
   * and the projects both.
   *
   * One method for the two features because they are one screen and one fact:
   * a port list and a dev-server row are each a statement about a machine this
   * browser is no longer talking to, and leaving either on screen behind the
   * pair form is the stale truth this client exists not to tell.
   */
  private forgetLocalhost(): void {
    if (this.checkTimer !== null) {
      window.clearTimeout(this.checkTimer)
      this.checkTimer = null
    }
    this.localhost = NO_LOCALHOST
    this.dev = NO_DEV
    if (this.screen === 'localhost') this.screen = 'sessions'
  }

  private onCredential(token: string): void {
    const now = Date.now()
    // The machine this token is *for*, which during a second pairing is not the
    // machine on screen. See `dialledId`.
    const dialled = machineById(this.book, this.dialledId)
    this.putCredential({
      token,
      deviceId: dialled?.credential.deviceId ?? '',
      deviceName: dialled?.credential.deviceName ?? 'This device',
      pairedAt: now,
      hostPlatform: this.hostPlatform,
      // Written with the credential, not after it. The credential is what the
      // next launch reconnects with and the endpoint is where it reconnects to;
      // saving one without the other leaves a browser holding a secret for a
      // machine it can no longer find.
      endpoint: this.endpoint,
      expiresAt: now + REMEMBERED_TTL_MS,
    })
    // Whatever brought this browser to the pair screen is over. Leaving the flag
    // set would leave a back chevron on the session list pointing at a machine
    // list the person has just finished with.
    this.pairingAnother = false
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
    saveBook(this.stores, this.remember, this.book)
    const credential = this.credential
    if (credential === null || credential.token === '') return
    // The single-credential record `pair.ts` owns is still written, and it is
    // deliberately a *mirror of the current machine* rather than a second pairing:
    // a shell cached by the service worker before the Machines screen shipped
    // reads that key and nothing else, and `sw.js` does not `skipWaiting`, so one
    // more launch of the old shell is guaranteed. It is also what carries this
    // browser's X25519 key into the same store as the book — see `savePairing`,
    // which is the one function allowed to move the two together.
    savePairing(this.stores, this.remember, credential, this.deviceKeys)
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
    // And `dev.state`, which arrives **unsolicited**: after one `dev.status` for
    // a folder the desktop pushes that folder's every later change, which is why
    // this is here rather than in a `case` that only runs for an answer this
    // client is waiting on. It reads `error` too — a refused start comes back
    // with no folder in it, and the only honest thing to do with one is stop the
    // button spinning.
    this.devDo({ t: 'frame', message })

    switch (message.t) {
      case 'welcome':
        // Before the credential is rebuilt, because the credential now carries
        // it: this is the one frame that says what the machine is, and every
        // launch after this one reads the answer back out of storage rather
        // than waiting for a socket.
        this.hostPlatform = readHostPlatform(message.hostPlatform)
        this.capabilities = message.capabilities
        {
          // The machine that just said hello, which during a second pairing is
          // not the one on screen. See `dialledId`.
          const dialled = machineById(this.book, this.dialledId)
          this.putCredential(
            renewed(
              {
                token: dialled?.credential.token ?? '',
                deviceId: message.deviceId,
                deviceName: message.deviceName,
                pairedAt: dialled?.credential.pairedAt ?? Date.now(),
                hostPlatform: this.hostPlatform,
                endpoint: this.endpoint,
                expiresAt: dialled?.credential.expiresAt ?? 0,
              },
              // A welcome is the only frame that proves this browser actually
              // reached the machine, which is what the sliding window measures. A
              // socket that merely opened proves nothing — the relay will open one
              // against a host id whose owner revoked this device an hour ago.
              Date.now(),
            ),
          )
        }
        this.applySessions(message.sessions, activity)
        if (this.screen === 'pair') this.screen = 'sessions'
        // A desktop that offers neither tunnelling nor dev servers — a different
        // machine on the same pairing, or one launched with a narrower `offer` —
        // must not leave this browser sitting on a screen whose every control it
        // would now refuse.
        if (this.screen === 'localhost' && !this.servesLocalhost) this.forgetLocalhost()
        // Asked on arrival rather than on the first tap, but only for somebody
        // already looking at it — which is the reconnect case, since the tab is
        // what asks otherwise.
        if (this.screen === 'localhost' && localhostOffered(this.capabilities)) this.localhostDo({ t: 'list' })
        if (this.screen === 'localhost') this.askDevServers()
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
        // The dev-server rows are one per *folder*, so this frame is the one
        // that decides which of them may still exist. Re-asking prunes the rows
        // for folders that have gone and picks up any that have arrived — and it
        // is the only way to be subscribed to a new one, since the desktop
        // pushes only about folders this connection has named.
        if (this.screen === 'localhost') this.askDevServers()
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
    // The one thing the stylesheet cannot work out for itself: which screen this
    // is. A phone-width header inside a terminal has room for the session's name
    // or for the appearance control and not for both, and on that screen the name
    // is what somebody needs — see the width rules at the foot of styles.css.
    this.root.classList.toggle('is-terminal', this.screen === 'terminal')
    this.renderHeader()
    this.renderBanner()
    this.renderCredentialAsk()
    this.renderTabs()
    this.renderContent()
  }

  /**
   * The strip that switches between the list screens.
   *
   * Sessions, Localhost and Settings — the phone's three, in the phone's order.
   * Before Settings existed the strip was drawn only against a desktop that
   * advertised `localhost`, because two tabs is a choice and one is not; it is now
   * always at least two, so what varies is whether Localhost is among them. The
   * rule is unchanged and so is what a browser paired to an older machine sees:
   * nothing is offered that the desktop did not say it can do.
   *
   * Absent — not disabled — on the pair screen and inside a terminal. Present on
   * Machines, which is pushed from Settings and keeps Settings marked as the
   * current tab: a person one screen deep has not left it.
   */
  private renderTabs(): void {
    const show = LISTING_SCREENS.includes(this.screen) && this.credential !== null
    this.tabs.hidden = !show
    if (!show) {
      this.tabs.replaceChildren()
      return
    }

    const options: Array<{ screen: Screen; label: string }> = [
      { screen: 'sessions', label: 'Sessions' },
      ...(this.servesLocalhost ? [{ screen: 'localhost' as Screen, label: 'Localhost' }] : []),
      { screen: 'settings', label: 'Settings' },
    ]
    this.tabs.replaceChildren(
      ...options.map((option) => {
        // Machines is Settings' own screen rather than a fourth place to be, so
        // the strip keeps pointing at Settings while it is open. Without this the
        // pushed screen would leave every tab unmarked, which reads as having
        // fallen out of the app.
        const here =
          this.screen === option.screen || (option.screen === 'settings' && this.screen === 'machines')
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
    // A menu or a rename field belongs to the row it was opened on, and that row
    // is not on this screen. Left set, the next visit to the screen it came from
    // would arrive with a field already open under somebody's finger.
    this.openRow = null
    this.renamingPort = null
    this.renamingMachine = null
    if (
      screen === 'localhost' &&
      this.localhost.ports === null &&
      this.state.phase === 'online' &&
      localhostOffered(this.capabilities)
    ) {
      this.localhostDo({ t: 'list' })
    }
    // The dev-server ask is unconditional on arrival rather than "only if we
    // have no rows", and that is the difference between the two features: a port
    // list is a scan somebody pays for, while `dev.status` reads a `package.json`
    // the desktop has usually already read — and asking is also what subscribes
    // this connection to the pushes.
    if (screen === 'localhost') this.askDevServers()
    this.render()
  }

  /**
   * Whether the second tab has anything behind it.
   *
   * Two capabilities, one screen. `localhost` fills the port list and `devserver`
   * fills the projects below it, and a desktop may advertise either without the
   * other — the public demo box deliberately withholds `localhost` so a stranger
   * is not offered a byte pipe to its loopback. So the tab appears when *either*
   * half can be drawn, and each half checks for itself.
   */
  private get servesLocalhost(): boolean {
    return localhostOffered(this.capabilities) || devserverOffered(this.capabilities)
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

  /**
   * The bar over everything, and the three questions it answers.
   *
   * What this is, where the back chevron goes, and — the part that is new —
   * *which machine you are looking at*. That last one had nowhere to live while
   * there was only one machine; the subtitle simply printed its host id. With
   * several it is the single most important fact on the screen, because every row
   * under it belongs to one of them.
   *
   * So the subtitle becomes a button, and only when there is something to press it
   * for. One machine is not a choice and is not drawn as one — the standing rule
   * in this client, the same one that decides whether the folder picker appears —
   * and the label is the machine's name rather than its address, which is the whole
   * reason `machines.ts` has nicknames.
   */
  private renderHeader(): void {
    const attached = this.sessions.find((session) => session.id === this.attachedId)
    this.back.hidden = this.backTarget() === null
    this.title.textContent = BRAND.name
    if (this.screen === 'terminal' && attached) {
      this.title.textContent = attached.title
      this.subtitle.replaceChildren(`${attached.provider} · ${shortenPath(attached.cwd)}`)
      return
    }
    if (this.screen === 'machines') this.title.textContent = 'Machines'
    if (this.screen === 'settings') this.title.textContent = 'Settings'

    const machine = this.machine
    if (machine === null) {
      this.subtitle.replaceChildren('Not paired')
      return
    }
    // Named by the person, or by the route it is actually on. Printing
    // `location.host` for a relay pairing was true of this page and false of the
    // machine — the browser can be served from anywhere now, and a subtitle that
    // reads like an address is read as one.
    const label = machineLabel(machine, this.origin)
    if (this.book.machines.length < 2 || this.screen === 'machines') {
      this.subtitle.replaceChildren(label)
      return
    }
    const switcher = element('button', 'header__machine', label)
    switcher.type = 'button'
    switcher.setAttribute('aria-label', `${label} — choose a machine`)
    switcher.addEventListener('click', () => this.goTo('machines'))
    // The chevron is a separate node so the name can ellipsise without taking the
    // affordance with it. A nickname is up to twenty-four characters and a phone
    // header is not. It is the same turned `›` the group headers use rather than a
    // `⌄`, for the same measured reason: the two glyphs sit on different baselines
    // in this face and the downward one hangs visibly below the text it follows.
    this.subtitle.replaceChildren(switcher, element('span', 'header__machine-mark', '›'))
  }

  /**
   * Where the back chevron goes from here, or null when it is not drawn.
   *
   * One function rather than a `hidden` rule beside a click handler, because those
   * are two statements of one fact and they have already been one negation apart
   * once — `.header__back[hidden]` carries a comment about the time the chevron
   * sat on the pair screen pointing at nothing.
   */
  private backTarget(): Screen | null {
    if (this.screen === 'terminal') return 'sessions'
    if (this.screen === 'machines') return 'settings'
    // The pair screen has a way back only when it was reached deliberately from
    // the Machines screen. A browser with no machines has nowhere to go back to,
    // and a chevron there would be the bug that rule exists to prevent.
    if (this.screen === 'pair' && this.pairingAnother && this.book.machines.length > 0) return 'machines'
    return null
  }

  /** The chevron was pressed. Leaving a terminal is its own operation. */
  private goBack(): void {
    const target = this.backTarget()
    if (target === null) return
    if (this.screen === 'terminal') {
      this.leaveTerminal()
      return
    }
    if (this.screen === 'pair') {
      // Abandoning a half-finished second pairing. The connection was pointed at
      // whatever the typed code found, so it goes back to the machine that was
      // being used — anything else leaves a socket dialling a machine this
      // browser has no credential for.
      this.pairingAnother = false
      const current = this.book.currentId
      this.screen = target
      this.render()
      if (current !== null && this.dialledId !== current) {
        this.book = { ...this.book, currentId: null }
        this.switchTo(current)
      }
      return
    }
    this.goTo(target)
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
    switch (this.screen) {
      case 'terminal':
        this.showTerminalScreen()
        return
      case 'pair':
        this.content.replaceChildren(this.pairScreen())
        return
      case 'localhost':
        this.content.replaceChildren(this.localhostScreen())
        return
      case 'settings':
        this.content.replaceChildren(this.settingsScreen())
        return
      case 'machines':
        this.content.replaceChildren(this.machinesScreen())
        return
      case 'sessions':
        this.content.replaceChildren(this.sessionsScreen())
        return
    }
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
    // One class, and the presentation lives in the sheet with the rest of it.
    // It used to borrow `.button--quiet` and then patch three inline styles on
    // top, which meant the one field on the screen wore the *secondary* ink and
    // no stylesheet could be held to it.
    input.className = 'code-field'
    screen.append(label, input)

    // Asked once per browser, not once per machine.
    //
    // The question is about *this computer* — whether a credential may outlive the
    // tab — and it is answered on the first pairing. Asking it again while adding a
    // second machine would be asking somebody to re-decide something they have
    // already decided, on a screen where the honest answer is "the same as last
    // time"; worse, the two answers cannot differ, because `remember` is one field
    // and one store. So the second time it is *stated* instead, with the one place
    // it can be changed named.
    screen.append(this.book.machines.length === 0 ? this.rememberChoice() : this.lifetimeAlready())

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
   * What this browser has already been told to do with a pairing.
   *
   * One line, on the pair screen, when there is already a machine. It is not a
   * control: the control is in Settings and there must not be two of it — that is
   * the same rule that keeps the appearance out of Settings and in the header.
   */
  private lifetimeAlready(): HTMLElement {
    const days = Math.round(REMEMBERED_TTL_MS / 86_400_000)
    return element(
      'p',
      'note',
      this.remember === 'this-browser'
        ? `This browser is remembered, so this ${this.noun} will be too — until you unpair it, or ${days} days ` +
            'pass without using it. Settings is where that changes.'
        : 'This pairing will end when you close this tab, like the machine you are already paired with. ' +
            'Settings is where that changes.',
    )
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
      meta.append(
        element(
          'span',
          undefined,
          [statusLabel(session), since].filter((part): part is string => part !== null).join(' · '),
        ),
      )
      // Which agent is in there. It was only ever visible from inside the
      // session, under the title, which is the one place somebody already knows
      // — the list is where it decides which row to open.
      if (session.provider !== '') meta.append(element('span', 'session__provider', session.provider))
      body.append(meta)

      // The folder, on its own line and in mono. It used to be the last clause
      // of the meta line, where it was the first thing to be ellipsised away and
      // read as more prose; a path is not prose. The whole value stays reachable
      // from a row that ellipsises, which is what the title is for.
      const where = element('div', 'session__where', shortenPath(session.cwd))
      where.title = session.cwd
      body.append(where)

      button.append(dot, body, element('span', 'session__chevron', '›'))
      button.addEventListener('click', () => this.openSession(session.id))
      row.append(button)
      list.append(row)
    }
    screen.append(list)
    /*
     * Nothing else. This screen used to end with the lifetime block and a "Forget
     * this Mac" button, and both have moved — the lifetime question to Settings,
     * where it sits with the other things that are about this browser rather than
     * about a session, and Forget onto the machine's own row, where it can name
     * which machine it is about.
     *
     * That is the phone's arrangement and the phone's argument for it: everything
     * that was not a session lived behind one control in a corner, *"which is
     * where features go to be undiscovered"*, and the fix was to give them a
     * screen rather than to leave them at the bottom of this one. A session list
     * that ends in two settings is the same problem upside down.
     */
    return screen
  }

  /**
   * Everything the machine is serving, and everything it could serve, on one
   * screen that is not a wall.
   *
   * Asad, opening the phone app: *"I can already see a big list of local hosts. So
   * it should not be like that… we need to fold it in a better way"*, and then the
   * three things that would fix it — rename them, categorise them, and *"I don't
   * see any kind of option here to make anyone up or make anyone activated"*. He
   * then said the same thing about this client in one line: *"I mean web app also,
   * improve according to the new things."*
   *
   * What this screen was: `portsInto` drew every port the desktop named, in one
   * flat list, and `devInto` drew a second flat list of projects underneath it —
   * so a machine serving nine things showed nine identical `2019 · wslrelay` rows
   * and then said "Dev servers" and did it again. Three things happen to it now,
   * and all three are the phone's, ported as rules rather than as code.
   *
   * ## 1. It is grouped, from facts
   *
   * `port-catalog.ts` holds the rules and the reasoning. The short version is that
   * every group is derived from something the wire carries — a process name, a
   * proven dev-server port, the socket this browser is connected on — and the
   * three groups that are noise start folded rather than hidden.
   *
   * ## 2. Rows can be named, and naming one promotes it
   *
   * `port-book.ts` holds the names, in this browser, against the machine and the
   * port. A named port is lifted to the top group, which is the whole of *"we can
   * keep some in the list and we can keep some folded"* — one gesture, one meaning.
   *
   * ## 3. The dev servers are on the same list, joined to their own ports
   *
   * The port list can only ever say what is *already* running; a project whose
   * server is not up is a row with a Start on it. They are one list because they
   * answer one question, and a `ready` dev server is **joined** to its port row
   * rather than drawn beside it — see "one row per server, never two".
   *
   * ## What is deliberately not ported
   *
   * The phone's swipe actions. `.swipeActions` is a `List` affordance that exists
   * on iOS and nowhere in a browser, and hand-rolling a drag here would give a
   * gesture with no rubber band, no interaction with the back gesture at the left
   * edge, and a different depth from every other page the reader has open. What
   * carries across is the *behaviour* — every row has its actions — and in a
   * browser those live behind the `…` he asked for in the same breath: *"maybe
   * three dots and more options and stuff like that"*.
   *
   * ## There is no Stop, and it is not an oversight
   *
   * A dev server runs in an **ordinary session** — the desktop opens a shell in the
   * project folder and types the command into it — so stopping one is Ctrl-C in
   * that session, which is why the wire has no stop verb to send. What this screen
   * will not do is type the interrupt blindly from a button: the desktop decides a
   * folder is `ready` and only stops saying so when the *session* exits, which a
   * Ctrl-C into a shell does not do. The row would go on offering an address for a
   * server that had gone — the one thing `DevServerReport` says a client of that
   * frame must never display. So the action opens the session, with the interrupt
   * one key away on the key bar, and the honest fix is a stop verb on the desktop.
   */
  private localhostScreen(): HTMLElement {
    const screen = element('div', 'screen')
    // Edge to edge, like the session list it sits beside: the rows carry their
    // own gutters so a row highlights across the full width of the column.
    screen.style.padding = '0'
    const online = this.state.phase === 'online'
    const tunnels = localhostOffered(this.capabilities)

    // Refresh exists only while there is a socket to carry it — the standing rule
    // against a control whose only function is to explain that it does not
    // function — so offline there is no row here at all rather than an empty one,
    // and the sentence under the list says how old it is instead.
    if (online && (tunnels || devserverOffered(this.capabilities))) {
      const heading = element('div', 'localhost__head')
      const refresh = element(
        'button',
        'button button--quiet localhost__refresh',
        this.localhost.listing ? 'Asking…' : 'Refresh',
      )
      refresh.type = 'button'
      refresh.disabled = this.localhost.listing
      refresh.addEventListener('click', () => {
        if (tunnels) this.localhostDo({ t: 'list' })
        // The projects are re-asked too. It is one Refresh over one screen, and a
        // button that refreshed half of what is under it would be the sort of
        // thing somebody presses twice and still does not trust.
        this.askDevServers()
      })
      heading.append(refresh)
      screen.append(heading)
    }

    const groups = this.localhostSections()
    if (groups.length === 0) {
      screen.append(element('p', 'empty', this.nothingServedSentence(online, tunnels)))
    } else {
      for (const section of groups) screen.append(this.sectionBlock(section, online, tunnels))
      // The rule nothing else on screen states — that naming a port is what moves
      // it up — because a folded group is otherwise a thing somebody has to
      // discover twice. It comes before the paragraph about serving because it is
      // about the list, and that one is about the whole feature.
      screen.append(element('p', 'note localhost__note', NAMING_FOOTNOTE))
    }

    const ports = this.localhost.ports
    if (!online && ports !== null && ports.length > 0) {
      screen.append(element('p', 'note localhost__note', stalePortsSentence(this.noun)))
    }

    // The screen's footnote, and it is the last thing on purpose: it answers a
    // question somebody asks *after* they have looked at the list and wondered why
    // nothing here opens a page. It covers the dev servers' addresses as well,
    // which is why the shorter version below is written only when this one is
    // absent.
    if (tunnels) screen.append(element('p', 'note localhost__note', cannotServeSentence(this.noun)))
    else if (this.dev.rows.some((row) => row.status === 'ready' && row.url !== undefined)) {
      screen.append(element('p', 'note localhost__note', cannotOpenSentence(this.noun)))
    }
    return screen
  }

  /**
   * The grouped rows, from the two halves this screen is made of.
   *
   * Both halves are gated on their own capability and neither assumes the other.
   * A desktop can advertise `localhost` without `devserver` or the other way round
   * — the public demo box deliberately withholds `localhost`, so a stranger is not
   * offered a byte pipe to its loopback — and the screen is whatever it actually
   * offers.
   *
   * The names are read here rather than inside the catalog, so that file stays a
   * pure function over values and never learns which machine it is describing.
   */
  private localhostSections(): LocalhostSection[] {
    const host = this.machine?.id ?? ''
    const ports = localhostOffered(this.capabilities) ? (this.localhost.ports ?? []) : []
    const devServers = devserverOffered(this.capabilities) ? this.dev.rows : []
    // A `ready` dev server's port is nameable too, even on a machine that does not
    // offer the port list at all: that address came off `dev.state`.
    const nameable = [
      ...ports.map((entry) => entry.port),
      ...devServers.map((row) => row.port).filter((port): port is number => port !== undefined),
    ]
    return portSections({
      ports,
      devServers,
      // Empty for a relay pairing, and that is correct rather than a gap: nothing
      // on this side knows which local port a relayed desktop bound. See
      // `directAppPorts`.
      appPorts: this.endpoint.kind === 'direct' ? directAppPorts(window.location) : [],
      names: this.portBook.namesFor(host, nameable),
    })
  }

  /**
   * Nothing to show, and which of the four reasons it is.
   *
   * A machine that does not offer the capability at all is a different fact from
   * one that offers it and is serving nothing, and both are different from a
   * socket that is down — saying "nothing is running" over a dead connection is a
   * claim nobody checked.
   */
  private nothingServedSentence(online: boolean, tunnels: boolean): string {
    if (tunnels && this.localhost.ports === null) {
      return this.localhost.listing
        ? `Asking the ${this.noun} what is listening…`
        : `The ${this.noun} has not said what it is serving yet.`
    }
    // One sentence for the round trip between arriving here and the first answer,
    // and nothing like it once the answer is "no project here has a dev script".
    if (!tunnels && devserverOffered(this.capabilities) && online && (this.folders?.length ?? 0) > 0) {
      return devWaitingSentence(this.noun)
    }
    return noPortsSentence(this.noun)
  }

  /**
   * One group, and its header, which is also the control that folds it.
   *
   * The whole header is the hit target rather than a chevron beside it, because a
   * 12px chevron is not a touch target and the row is already the shape of one.
   * The count is on it for the same reason the phone's is: a folded group has to
   * be worth opening before anybody opens it, and *"Other services · 9"* answers
   * that where *"Other services ›"* does not.
   */
  private sectionBlock(section: LocalhostSection, online: boolean, tunnels: boolean): HTMLElement {
    const host = this.machine?.id ?? ''
    const folded = this.portBook.isFolded(host, section.category)
    const group = element('section', 'portgroup')

    const head = element('button', 'portgroup__head')
    head.type = 'button'
    head.setAttribute('aria-expanded', folded ? 'false' : 'true')
    head.append(
      // One glyph, turned rather than swapped — see the stylesheet, where the two
      // spellings this used to have are written down along with what they did to
      // the header's baseline.
      element('span', folded ? 'portgroup__mark' : 'portgroup__mark portgroup__mark--open', '›'),
      element('span', 'portgroup__title', categoryTitle(section.category)),
      element('span', 'portgroup__count', String(section.rows.length)),
    )
    head.addEventListener('click', () => {
      this.portBook.setFolded(!folded, host, section.category)
      this.renderContent()
    })
    group.append(head)

    if (!folded) {
      const list = element('ul', 'ports')
      for (const row of section.rows) list.append(this.portRow(row, online, tunnels))
      group.append(list)
    }
    return group
  }

  /**
   * One row, whichever kind it is.
   *
   * The two kinds share a shell — the same list item, the same actions, the same
   * rename field — and differ only in the lines inside it. A second row type
   * saying the same things in a slightly different order is how two halves of one
   * screen end up disagreeing about what `failed` looks like.
   */
  private portRow(row: LocalhostRow, online: boolean, tunnels: boolean): HTMLElement {
    const item = element('li', 'port')
    const port = row.port

    /*
     * One line carries the row's identity **and** its controls, and that is the
     * shape rather than a saving.
     *
     * The first version put the controls on a line of their own, on the reasoning
     * that a 390px phone cannot hold a label, a Check and a menu at once. Rendered,
     * it was wrong twice over: a port row became 215 points tall, so five of them
     * filled a phone, and at 1440px the menu was stranded a thousand pixels from
     * the row it belongs to. A flexible label between them is what actually solves
     * both — it eats the space on a monitor and gives it up on a phone.
     */
    const line = element('div', 'port__line')
    if (row.dev !== null) this.devHeadInto(line, row)
    else {
      // Mono while the port number is the identity, and the interface face once a
      // name has replaced it. Monospace is a promise that the characters are exact
      // and countable, which is true of `localhost:3000` and not of "client
      // billing app".
      const named = row.name !== null
      line.append(element('span', named ? 'port__label port__label--named' : 'port__label', portRowTitle(row)))
    }

    // One check at a time, and only with a socket. A second Check pressed while
    // one is running is refused by the machine itself; disabling it is what stops
    // somebody pressing a button that does nothing.
    if (online && tunnels && port !== null) {
      const checking = this.localhost.checking
      const here = checking?.port === port
      const check = element('button', 'port__check', here ? 'Checking…' : 'Check')
      check.type = 'button'
      check.disabled = checking !== null
      check.addEventListener('click', () => {
        this.checks += 1
        this.localhostDo({ t: 'check', port, id: `localhost-${this.checks}` })
      })
      line.append(check)
    }
    if (port !== null) {
      const open = this.openRow === row.id
      const more = element('button', 'port__more', '···')
      more.type = 'button'
      more.setAttribute('aria-expanded', open ? 'true' : 'false')
      more.setAttribute('aria-label', `Actions for ${portRowTitle(row)}`)
      more.addEventListener('click', () => {
        this.openRow = open ? null : row.id
        this.renamingPort = null
        this.renderContent()
      })
      line.append(more)
    }
    item.append(line)

    if (row.dev !== null) this.devLinesInto(item, row)
    else {
      const detail = portRowDetail(row)
      if (detail !== null) item.append(element('p', 'port__detail', detail))
    }

    // The row's own verb, on a line of its own — unlike Check and the menu, which
    // are the same two controls on every row. A Start belongs under the project it
    // will start, at the width its label needs.
    const action = this.rowAction(row)
    if (action !== null) {
      const actions = element('div', 'port__controls')
      actions.append(action)
      item.append(actions)
    }

    if (this.renamingPort !== null && this.renamingPort === port) {
      item.append(
        this.renameField(this.renameText, `localhost:${port} on this ${this.noun}`, MAX_NAME_LENGTH, (value) => {
          this.portBook.setName(value, this.machine?.id ?? '', port)
          this.renamingPort = null
          this.openRow = null
          this.renderContent()
        }),
      )
    } else if (this.openRow === row.id && port !== null) {
      item.append(this.portMenu(row, port))
    }

    // The answer sits under the port it is about. A single result line at the foot
    // of the list would be correct and unreadable: three ports in, nobody can tell
    // which one "it answered" is about.
    const outcome = this.localhost.outcome
    if (outcome !== null && outcome.port === port) {
      item.append(
        element(
          'p',
          outcome.kind === 'answered' ? 'port__result port__result--ok' : 'port__result',
          // Through `plain` like every other string that came off this socket: a
          // refusal is composed on the desktop, and this end is the one that pays
          // if that ever stops being true.
          plain(checkSentence(outcome, this.noun)),
        ),
      )
    }
    return item
  }

  /**
   * The identity of a dev-server row: its state, its name, and the project it is.
   *
   * When the person has named the row's port, their name leads and the project's
   * own name becomes a chip beside it. Replacing one with the other would lose the
   * fact that this row is a project at all.
   */
  private devHeadInto(line: HTMLElement, row: LocalhostRow): void {
    const report = row.dev
    if (report === null) return
    const view = this.devView(report)
    line.append(
      element('span', `dev__dot dev__dot--${view.tone}`),
      element('span', 'dev__name', row.name ?? view.name),
    )
    if (row.name !== null) line.append(element('span', 'dev__project', view.name))
  }

  /**
   * The lines under a dev-server row, in whichever of its five states it is in.
   *
   * Every word is `devRowView`'s and every rule with it; this is delivery. Two of
   * those rules are worth naming where somebody editing the DOM will see them: the
   * rows are whatever the reducer holds, never assembled from `folders` — a folder
   * with no dev script has no row — and `note` is process output, drawn as text
   * through `plain` and never parsed.
   */
  private devLinesInto(item: HTMLElement, row: LocalhostRow): void {
    const report = row.dev
    if (report === null) return
    const view = this.devView(report)
    // The whole path, reachable from a row that shows only the project's name. The
    // same escape hatch the folder picker uses, for the same reason: two checkouts
    // can share a last segment.
    item.title = view.folder
    item.append(element('p', view.exact ? 'dev__line dev__line--exact' : 'dev__line', plain(view.line)))
    if (view.note !== null) item.append(element('p', 'dev__note', plain(view.note)))
    if (view.address !== null) item.append(element('p', 'dev__address', plain(view.address)))
  }

  /** One row's view, asked for by both halves of the row that draws it. */
  private devView(report: DevServerReport): ReturnType<typeof devRowView> {
    return devRowView(report, {
      online: this.state.phase === 'online',
      starting: this.dev.starting === report.folder,
    })
  }

  /**
   * The row's own verb, or nothing.
   *
   * Which one it is lives in `port-catalog.ts`, so the answer to "what does start
   * do in each of the five states" is a value a unit test can read rather than a
   * branch inside a render that only a paired browser with a project on the far
   * machine could exercise. `copyAddress` is the one case that is not a button
   * here — it is in the `…` menu, because a Copy on every row would be the loudest
   * thing on a screen whose whole complaint was noise.
   */
  private rowAction(row: LocalhostRow): HTMLElement | null {
    const action = secondAction(row)
    if (action.kind === 'none' || action.kind === 'copyAddress') return null
    if (this.state.phase !== 'online') return null
    if (action.kind === 'openSession') {
      // Labelled for what it does. It is also how a dev server is stopped — Ctrl-C
      // is on the key bar in there — and calling the button "Stop" would be naming
      // it after the thing the *next* tap does. See this screen's header.
      const open = element('button', 'button button--quiet port__action', 'Open session')
      open.type = 'button'
      open.addEventListener('click', () => this.openSession(action.id))
      return open
    }
    // Not a Start drawn as though nothing had happened, when it is a retry:
    // `dev.start` re-reads the folder, so a `package.json` fixed since the failure
    // is picked up rather than the old answer being replayed.
    const folder = action.folder
    const start = element('button', 'button port__action', action.kind === 'retry' ? 'Try again' : 'Start')
    start.type = 'button'
    // Disabled while *any* start is in flight, not just this row's: the desktop
    // allows one at a time and refuses the second with a sentence, so a live-looking
    // button on the row below is a press that produces an error message rather than
    // a dev server.
    start.disabled = this.dev.starting !== null
    start.addEventListener('click', () => this.devDo({ t: 'start', folder }))
    return start
  }

  /**
   * The three dots he asked for, opened in place.
   *
   * *"maybe three dots and more options and stuff like that"*. A popover would be
   * the desktop's answer; in a page that is a fixed frame with one scrolling region
   * inside it, an absolutely-positioned menu has to be dismissed, repositioned on
   * a resize and kept inside the viewport — three problems, none of which is the
   * feature. Opening in the row costs one row of height and cannot be misplaced.
   */
  private portMenu(row: LocalhostRow, port: number): HTMLElement {
    const menu = element('div', 'port__menu')
    const named = row.name !== null

    const rename = element('button', 'port__menu-item', named ? 'Rename' : 'Name this port')
    rename.type = 'button'
    rename.addEventListener('click', () => {
      this.renamingPort = port
      this.renameText = row.name ?? ''
      this.renderContent()
    })
    menu.append(rename)

    if (named) {
      // Not "delete": nothing on the machine changes and the port stays in the
      // list. It goes back to being called by the process holding it.
      const clear = element('button', 'port__menu-item', 'Clear name')
      clear.type = 'button'
      clear.addEventListener('click', () => {
        this.portBook.setName(null, this.machine?.id ?? '', port)
        this.openRow = null
        this.renderContent()
      })
      menu.append(clear)
    }

    const copy = element('button', 'port__menu-item', 'Copy address')
    copy.type = 'button'
    copy.addEventListener('click', () => {
      this.openRow = null
      void this.copyAddress(port)
    })
    menu.append(copy)
    return menu
  }

  /**
   * `http://localhost:<port>`, on the clipboard, and said out loud.
   *
   * The address is the *machine's* loopback and not this reader's, which is the
   * whole point of the footnote at the bottom of this screen — so what this is for
   * is pasting into a terminal on that machine, or into a message to somebody
   * sitting at it.
   *
   * A clipboard write can be refused: the API needs a secure context and, in some
   * browsers, a permission. A refusal is said rather than swallowed, because a
   * silent copy that did not happen is indistinguishable from one that did.
   */
  private async copyAddress(port: number): Promise<void> {
    const address = `http://localhost:${port}`
    try {
      await navigator.clipboard.writeText(address)
      this.say(`Copied ${address}`)
    } catch {
      this.say(`This browser would not let the page copy ${address}.`)
    }
    this.renderContent()
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
   * So it is stated in the sentence that says what it means rather than the name
   * of a setting, and the button is the *action* rather than a toggle: nobody has
   * to work out which way a switch is pointing. Nothing here is a second copy of
   * the state — both halves read `remember`, which is what `loadMachines` found in
   * whichever store answered.
   *
   * It used to sit at the foot of the session list, and it is on the Settings
   * screen now. Same block, same words, one screen over: this is a fact about the
   * browser rather than about the sessions, and a list of somebody's running work
   * is not where a storage decision belongs.
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
      // Moves the machines, the mirrored credential *and* this browser's key into
      // the other store and clears the one they came from. The port names go with
      // them: they are the person's own text about a machine, and leaving them in
      // a profile on a computer whose owner has just said "just for this visit" is
      // exactly the residue that answer promises there will not be.
      this.keep()
      this.portBook.setLifetime(this.remember)
      this.renderContent()
    })
    block.append(change)
    return block
  }

  /* ------------------------------------------------------------ settings -- */

  /**
   * The things that belong to this browser rather than to a machine.
   *
   * Three groups and two sentences. Asad on the desktop's settings page: *"we
   * don't need this much of big descriptions under each. The whole page is going
   * to be used just because of the big descriptions."* So each row is a line, and
   * the only prose is the two paragraphs that say something no row can — what
   * changing the text size does to a session that is already open, and the one
   * thing this client genuinely cannot do.
   *
   * ## What is here, and what is deliberately not
   *
   * The phone's Settings has Machines, GitHub, Alerts, Text size and About. Two of
   * those are missing here and neither is an omission:
   *
   *  - **GitHub.** This client refuses a machine's request for a git credential
   *    and says so on a card of its own — see `credential.ts`, which explains at
   *    length why a browser served by the machine that would be asking is the one
   *    place that would be dishonest. A row that opened a sign-in this client will
   *    not complete is the definition of a fake feature.
   *  - **Alerts.** There is no notification path in this client at all, and the
   *    closing paragraph says so rather than a switch pretending otherwise.
   *
   * The appearance is not here either, and that one is a placement rather than an
   * absence: it is in the header, on every screen including the pair screen,
   * because it is the one preference somebody changes *because of what is on the
   * screen right now*. A second copy of it here would be two controls for one
   * setting.
   */
  private settingsScreen(): HTMLElement {
    const screen = element('div', 'screen')
    const paired = this.book.machines.length

    const machines = element('div', 'group')
    const row = element('button', 'setting')
    row.type = 'button'
    row.append(
      element('span', 'setting__title', 'Machines'),
      element('span', 'setting__value', paired === 1 ? '1 paired' : `${paired} paired`),
      element('span', 'setting__mark', '›'),
    )
    row.addEventListener('click', () => this.goTo('machines'))
    machines.append(row)
    screen.append(machines)

    screen.append(element('p', 'caption', 'Terminal'))
    screen.append(this.textSizeGroup())
    screen.append(
      element(
        'p',
        'note note--plain',
        'A session already open picks this up straight away — the column count is the font, so changing ' +
          `it resizes the session on the ${this.noun}.`,
      ),
    )

    screen.append(element('p', 'caption', 'This browser'))
    const lifetime = this.lifetimeBlock()
    if (lifetime !== null) screen.append(lifetime)

    screen.append(
      element(
        'p',
        'note note--plain',
        `This page talks to your own machines. There is no notification server in ${BRAND.name} and there ` +
          'is nowhere for one to send anything — a browser tab that is closed is not running, so a session ' +
          'that needs you is found when you come back rather than announced while you are away.',
      ),
    )
    return screen
  }

  /**
   * How big the terminal's characters are.
   *
   * The same setting the phone puts in its Settings, for the same two reasons: it
   * is a property of the person's eyes rather than of one session, and a control
   * you can only reach from inside a session is one that somebody with a
   * nine-pixel terminal cannot read well enough to find.
   *
   * Two buttons and the value, rather than a slider: the range is thirteen whole
   * pixels, every one of them is a distinct answer, and a slider on a phone is a
   * control you cannot land on a specific one of thirteen values with.
   */
  private textSizeGroup(): HTMLElement {
    const group = element('div', 'group')
    const row = element('div', 'setting setting--static')
    row.append(element('span', 'setting__title', 'Text size'))
    row.append(element('span', 'setting__value', textSizeLabel(this.textSize)))

    const stepper = element('span', 'setting__stepper')
    const smaller = element('button', 'setting__step', '−')
    smaller.type = 'button'
    smaller.setAttribute('aria-label', 'Smaller text')
    smaller.disabled = !canGoSmaller(this.textSize)
    smaller.addEventListener('click', () => this.chooseTextSize(smallerText(this.textSize)))

    const larger = element('button', 'setting__step', '+')
    larger.type = 'button'
    larger.setAttribute('aria-label', 'Larger text')
    larger.disabled = !canGoLarger(this.textSize)
    larger.addEventListener('click', () => this.chooseTextSize(largerText(this.textSize)))

    stepper.append(smaller, larger)
    row.append(stepper)
    group.append(row)
    return group
  }

  /**
   * The person moved the size.
   *
   * The emulator is told, and then measured. A font change without a `fit` leaves
   * xterm holding the column count it computed for the old face, which is a
   * terminal drawing eighty columns into a box that now fits sixty — and the
   * machine still sending eighty. The resize frame that follows is what makes the
   * far end agree, and `terminal.ts` clamps it so a size the protocol would refuse
   * cannot close the socket.
   */
  private chooseTextSize(size: number): void {
    if (size === this.textSize) return
    this.textSize = size
    writeTextSize(this.stores.browser, size)
    this.terminal?.setFontSize(size)
    this.terminal?.fit()
    this.renderContent()
  }

  /* ------------------------------------------------------------ machines -- */

  /**
   * Every machine this browser is paired with, on a screen instead of nowhere.
   *
   * Asad on the desktop's equivalent: *"I am not able to edit the name of this
   * account and I don't know where it belongs to… I should be able to edit the
   * account, delete and add."* Same three verbs, here, in one place — and the
   * screen answers the second complaint on every row, because the line under the
   * name is the endpoint and says who can read the session.
   *
   * ## Why only one row has a connection on it
   *
   * The phone holds a socket to every paired machine from launch, because it
   * delivers alerts and a machine nobody is looking at is still a machine that
   * might need you. This client has no notifications and cannot have any, so a
   * second socket would buy nothing and cost a real thing — see the header of
   * `machines.ts`. What the other rows say instead is when this browser last got
   * through, which is a fact rather than a guess: the credential's window is
   * pushed out by `renewed()` on every `welcome`, and a `welcome` is the only frame
   * that proves this browser reached the machine at all.
   */
  private machinesScreen(): HTMLElement {
    const screen = element('div', 'screen')
    const now = Date.now()

    const list = element('ul', 'machines')
    for (const machine of this.book.machines) {
      list.append(this.machineRow(machine, now))
    }
    screen.append(list)

    const add = element('button', 'button button--quiet machines__add', 'Pair another machine')
    add.type = 'button'
    add.addEventListener('click', () => {
      this.pairingAnother = true
      this.screen = 'pair'
      this.render()
    })
    screen.append(add)

    screen.append(element('p', 'note note--plain', MACHINES_FOOTNOTE))
    return screen
  }

  /**
   * One machine.
   *
   * The name leads because it is what somebody is looking for. The endpoint under
   * it is mono and dimmed because it is data — and here it is also the answer to
   * *"I don't know where it belongs to"*. The status line is a sentence about the
   * row rather than the row itself, so it is quieter than both.
   *
   * Pressing the row switches to that machine; the `···` beside it renames or
   * forgets it. The two are separated because one of them is a thing people do
   * twenty times a day and the other is a thing they do once and regret.
   */
  private machineRow(machine: StoredMachine, now: number): HTMLElement {
    const item = element('li', 'machine')
    const current = machine.id === this.book.currentId
    const label = machineLabel(machine, this.origin)

    const line = element('div', 'machine__line')
    const choose = element('button', 'machine__choose')
    choose.type = 'button'
    choose.append(
      element('span', current ? 'machine__dot machine__dot--here' : 'machine__dot'),
      element('span', 'machine__name', label),
    )
    choose.addEventListener('click', () => {
      if (current) return
      this.switchTo(machine.id)
    })
    line.append(choose)

    const open = this.openRow === machine.id
    const more = element('button', 'port__more', '···')
    more.type = 'button'
    more.setAttribute('aria-expanded', open ? 'true' : 'false')
    more.setAttribute('aria-label', `Actions for ${label}`)
    more.addEventListener('click', () => {
      this.openRow = open ? null : machine.id
      this.renamingMachine = null
      this.renderContent()
    })
    line.append(more)
    item.append(line)

    // Two lines, wrapped, rather than one truncated. The summary is a host id, a
    // relay and how it is protected; cut at either end it loses one of the three,
    // and this is a screen with room — unlike the header, where the same machine
    // is named by its first six characters.
    item.append(element('p', 'machine__where', endpointSummary(machine, this.origin)))
    item.append(element('p', 'machine__state', this.machineState(machine, current, now)))

    if (this.renamingMachine === machine.id) {
      item.append(
        this.renameField(this.renameText, endpointSummary(machine, this.origin), MAX_NICKNAME_LENGTH, (value) => {
          this.book = renameMachine(this.book, machine.id, cleanNickname(value))
          this.renamingMachine = null
          this.openRow = null
          this.keep()
          this.render()
        }),
      )
    } else if (open) {
      const menu = element('div', 'port__menu')
      const rename = element('button', 'port__menu-item', machine.nickname === null ? 'Name this machine' : 'Rename')
      rename.type = 'button'
      rename.addEventListener('click', () => {
        this.renamingMachine = machine.id
        this.renameText = machine.nickname ?? ''
        this.renderContent()
      })
      menu.append(rename)

      // Named, because this menu is opened on a row and a browser paired with
      // three machines is three identical menus.
      const forget = element('button', 'port__menu-item port__menu-item--warn', `Forget ${label}`)
      forget.type = 'button'
      forget.addEventListener('click', () => {
        this.openRow = null
        this.forgetMachine(machine.id)
      })
      menu.append(forget)
      item.append(menu)
    }
    return item
  }

  /**
   * What the row says the machine is doing.
   *
   * Sessions while it is up, because that is the number worth switching for; the
   * connection's own sentence when it is not, because then the session count is
   * history. For a machine this browser is not talking to there is no connection
   * to describe at all, and the honest answer is when it was last reached — never
   * a dot, and never a count from the last time somebody looked.
   */
  private machineState(machine: StoredMachine, current: boolean, now: number): string {
    if (!current) return lastReachedSentence(machine, now)
    if (this.state.phase !== 'online') return this.state.detail
    const running = this.sessions.filter((session) => session.exitCode === undefined).length
    if (running === 0) return 'nothing running'
    return running === 1 ? '1 session' : `${running} sessions`
  }

  /* --------------------------------------------------------------- bits -- */

  /**
   * The one field this client has besides the pairing code.
   *
   * Written once and used by both renames, because the two are the same
   * interaction — a name, the thing it is about underneath it, Save and Cancel —
   * and a second copy is how one of them ends up without an Enter handler.
   *
   * `maxLength` is set from the store's own bound rather than left to the cleaner
   * afterwards, so the field cannot show more than will be kept. Saving with the
   * field emptied is how a name is removed; `cleanLabel` folds empty and
   * whitespace onto nothing, which is why there is no separate Clear here.
   */
  private renameField(
    value: string,
    about: string,
    maximum: number,
    save: (value: string) => void,
  ): HTMLElement {
    const block = element('div', 'rename')
    block.append(element('p', 'rename__about', about))

    const field = element('input')
    field.type = 'text'
    field.className = 'rename__field'
    field.value = value
    field.maxLength = maximum
    field.placeholder = 'A name you will recognise'
    field.setAttribute('aria-label', 'Name')
    field.addEventListener('input', () => {
      // Held here rather than read off the element at save time, because a frame
      // pushed by the desktop rebuilds this list — and with it this input — while
      // somebody is still typing into it.
      this.renameText = field.value
    })
    field.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') save(field.value)
      if (event.key === 'Escape') {
        this.renamingPort = null
        this.renamingMachine = null
        this.renderContent()
      }
    })

    const actions = element('div', 'rename__actions')
    const confirm = element('button', 'button rename__save', 'Save')
    confirm.type = 'button'
    confirm.addEventListener('click', () => save(field.value))
    const cancel = element('button', 'button button--quiet', 'Cancel')
    cancel.type = 'button'
    cancel.addEventListener('click', () => {
      this.renamingPort = null
      this.renamingMachine = null
      this.renderContent()
    })
    actions.append(confirm, cancel)

    block.append(field, actions)
    // After the tree is built, by the caller that puts it on screen — focusing an
    // element that is not in the document does nothing, and doing nothing quietly
    // is how the pair screen's keypad stopped appearing once already.
    queueMicrotask(() => {
      field.focus()
      field.select()
    })
    return block
  }

  /**
   * Say something that will stop being said.
   *
   * Two and a half seconds, the same as the phone's. It is not a notification and
   * must never be used as one: everything that matters — the connection, a refused
   * request, a machine asking for a login — has a surface that stays on screen
   * until it stops being true.
   */
  private say(message: string): void {
    this.toastText = message
    if (this.toastTimer !== null) window.clearTimeout(this.toastTimer)
    this.toastTimer = window.setTimeout(() => {
      this.toastTimer = null
      this.toastText = null
      this.renderToast()
    }, 2500)
    this.renderToast()
  }

  private renderToast(): void {
    const message = this.toastText
    this.toast.hidden = message === null
    this.toast.textContent = message ?? ''
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

    const terminal = createTerminal(
      {
        onData: (data) => this.sendInput(data),
        onResize: (size) => {
          // Only after the attach has gone out. A resize for a session the
          // server has not given us yet is answered with `unknown-session`.
          if (this.attachedId !== null && this.attachSent) {
            this.connection?.send({ t: 'resize', id: this.attachedId, cols: size.cols, rows: size.rows })
          }
        },
      },
      // Built in the appearance that is on screen, rather than built dark and
      // corrected: xterm paints its first frame from the theme it was constructed
      // with, and a terminal that flashes charcoal before going white is the
      // failure this feature is judged on, in miniature.
      this.appearance,
      // And at the size that was chosen, for exactly the same reason: a terminal
      // that appears at 13px and reflows to 18px one frame later is the same
      // failure with a different property.
      this.textSize,
    )
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

  /**
   * Forget everything — every machine, and this browser's own identity with it.
   *
   * Reached from the last machine's Forget, and from nowhere else. With several
   * machines the row's Forget is `forgetMachine`, which leaves the others alone;
   * this is the state where there is nothing left to leave alone, and a browser
   * holding no machines is an unpaired browser.
   */
  private forget(): void {
    clearPairing(this.stores)
    clearMachineBook(this.stores)
    this.book = NO_MACHINES
    this.notice = null
    this.openRow = null
    this.renamingPort = null
    this.renamingMachine = null
    this.pairingAnother = false
    // Back to the safe answer. The next pairing on this browser asks again, and
    // it must not inherit "remember" from a machine this person has just said is
    // not theirs any more.
    this.remember = 'this-tab'
    this.portBook.setLifetime(this.remember)
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
