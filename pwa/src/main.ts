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
import { Connection, type ConnectionState } from './connection'
import {
  CREDENTIAL_EXPLANATION,
  credentialHeadline,
  type CredentialNotice,
} from './credential'
import { folderOffer, foldersAfter, noFoldersSentence, pickerRows } from './folders'
import { machineNoun, readHostPlatform, type HostPlatform } from './host-platform'
import { createKeyBar, type KeyBarHandle } from './keybar'
import {
  clearCredential,
  describeDevice,
  loadCredential,
  readPairInput,
  saveCredential,
  takePairToken,
  type StoredCredential,
} from './pair'
import { chunkInput, type RemoteSession, type ServerMessage } from './protocol-client'
import { formatSince, sessionTone, shortenPath, sortSessions, statusLabel } from './sessions'
import { createTerminal, type TerminalHandle } from './terminal'

/**
 * Where the desktop answers.
 *
 * Same origin as this page, always: the client is served by the very process it
 * then talks to, so there is nothing to configure and no way to point a paired
 * phone at a different desktop by editing a field.
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

type Screen = 'pair' | 'sessions' | 'terminal'

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
  private readonly content = element('main', 'content')

  private connection: Connection | null = null
  private state: ConnectionState = { phase: 'offline', detail: 'Not connected.', retryAt: null, attempts: 0 }
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

    root.append(this.header, this.banner, this.credentialCard, this.content)
  }

  /* ------------------------------------------------------------- startup -- */

  start(): void {
    // Taken, not read: the fragment is rewritten in the same breath, so the
    // one-time token is not left in the address bar or the back-forward list.
    const scanned = takePairToken(window.location, window.history)
    this.credential = loadCredential(window.localStorage)
    this.hostPlatform = this.credential?.hostPlatform ?? 'unknown'

    // A freshly scanned code wins over a stored credential. Someone standing at
    // the desktop scanning a new QR is re-pairing, most likely because the old
    // device row was revoked, and using the stale credential would fail in a
    // way that looks like the QR not working.
    const token = scanned ?? this.credential?.token ?? null
    this.screen = token === null ? 'pair' : 'sessions'
    this.render()
    if (token !== null) this.connect(token)

    this.watchViewport()
    this.watchWakeups()
    // Every second, because the banner counts down. Cheap, and it stops the
    // moment there is nothing to count.
    window.setInterval(() => {
      if (this.state.retryAt !== null) this.renderBanner()
    }, 1000)
  }

  private connect(token: string): void {
    this.connection?.stop()
    this.connection = new Connection({
      url: socketUrl(window.location),
      token,
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

    if (state.phase === 'online' && !wasOnline) {
      // Re-attach rather than assume. The desktop kept running while we were
      // gone, so what is on screen is from before the gap; leaving it there
      // under a fresh connection is the lie this whole client is built to avoid.
      if (this.attachedId !== null) {
        this.terminal?.reset()
        this.attach(this.attachedId)
      }
      this.connection?.send({ t: 'list' })
    }

    if (state.phase === 'rejected') {
      // The credential is no good. Holding on to it would mean every launch
      // fails the same way with no route back to pairing.
      clearCredential(window.localStorage)
      this.credential = null
      this.attachedId = null
      // Everything the refused machine told us about itself goes with it. A
      // folder list is a statement about a device this desktop no longer
      // recognises, and drawing a picker from it on the way back to the pair
      // screen would be offering somewhere to start that nothing will start in.
      this.capabilities = []
      this.folders = null
      this.picking = false
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
    if (this.screen === 'sessions') this.renderContent()
  }

  private onCredential(token: string): void {
    this.credential = {
      token,
      deviceId: this.credential?.deviceId ?? '',
      deviceName: this.credential?.deviceName ?? 'This device',
      pairedAt: Date.now(),
      hostPlatform: this.hostPlatform,
    }
    saveCredential(window.localStorage, this.credential)
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

    switch (message.t) {
      case 'welcome':
        // Before the credential is rebuilt, because the credential now carries
        // it: this is the one frame that says what the machine is, and every
        // launch after this one reads the answer back out of storage rather
        // than waiting for a socket.
        this.hostPlatform = readHostPlatform(message.hostPlatform)
        this.capabilities = message.capabilities
        this.credential = {
          token: this.credential?.token ?? '',
          deviceId: message.deviceId,
          deviceName: message.deviceName,
          pairedAt: this.credential?.pairedAt ?? Date.now(),
          hostPlatform: this.hostPlatform,
        }
        if (this.credential.token !== '') saveCredential(window.localStorage, this.credential)
        this.applySessions(message.sessions, activity)
        if (this.screen === 'pair') this.screen = 'sessions'
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
    this.renderContent()
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
    this.subtitle.textContent = this.credential === null ? 'Not paired' : window.location.host
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
    this.content.replaceChildren(this.screen === 'pair' ? this.pairScreen() : this.sessionsScreen())
  }

  private pairScreen(): HTMLElement {
    const screen = element('div', 'screen')
    screen.append(
      // Neutral on a fresh install and neutral by design: nothing has answered
      // yet, so nothing here may claim to know what kind of computer is at the
      // other end. It sharpens to "Mac" or "PC" the moment one does — which for
      // a re-pair is immediately, because the stored credential remembers.
      element('h2', undefined, `Pair with your ${this.noun}`),
      element(
        'p',
        'screen__lead',
        `${BRAND.name} on the ${this.noun} shows a QR code holding a one-time token. Scanning it opens this page with the token attached, which is all the pairing there is.`,
      ),
    )

    const steps = element('ol', 'steps')
    for (const step of [
      `Open the ${this.noun} and show the pairing code.`,
      'Scan it with this device’s camera.',
      `Approve this device on the ${this.noun} when it appears — pairing alone does not grant access.`,
    ]) {
      steps.append(element('li', undefined, step))
    }
    screen.append(steps)

    // The camera route does not exist on a desktop browser, and this same
    // client is meant to work from the Windows box on the tailnet.
    const label = element('p', 'screen__lead', 'No camera? Paste the link or the code:')
    const input = element('input')
    input.type = 'text'
    input.placeholder = 'https://…/#t=…'
    input.autocapitalize = 'off'
    input.autocomplete = 'off'
    input.spellcheck = false
    input.className = 'button button--quiet'
    input.style.textAlign = 'left'

    const submit = element('button', 'button', 'Pair')
    submit.type = 'button'
    submit.addEventListener('click', () => {
      const token = readPairInput(input.value)
      if (token === null) {
        this.state = {
          phase: 'offline',
          detail: 'That does not look like a pairing link.',
          retryAt: null,
          attempts: 0,
        }
        this.renderBanner()
        return
      }
      this.connect(token)
    })

    screen.append(label, input, submit)
    screen.append(
      element(
        'p',
        'note',
        'The token is good for one minute and one use. It is kept in the page fragment, which browsers never send to a server.',
      ),
    )
    return screen
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

    const forget = element('button', 'button button--quiet', `Forget this ${this.noun}`)
    forget.type = 'button'
    forget.style.margin = '20px 16px'
    forget.style.width = 'auto'
    forget.addEventListener('click', () => this.forget())
    screen.append(forget)
    return screen
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
    const offer = folderOffer(this.folders, this.sessions)
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
    this.terminalScreen = screen
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
    clearCredential(window.localStorage)
    this.credential = null
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
