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
 * phone at a different Mac by editing a field.
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

    root.append(this.header, this.banner, this.content)
  }

  /* ------------------------------------------------------------- startup -- */

  start(): void {
    // Taken, not read: the fragment is rewritten in the same breath, so the
    // one-time token is not left in the address bar or the back-forward list.
    const scanned = takePairToken(window.location, window.history)
    this.credential = loadCredential(window.localStorage)

    // A freshly scanned code wins over a stored credential. Someone standing at
    // the Mac scanning a new QR is re-pairing, most likely because the old
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
    }
    saveCredential(window.localStorage, this.credential)
  }

  private onMessage(message: ServerMessage, activity?: ReadonlyMap<string, number>): void {
    switch (message.t) {
      case 'welcome':
        this.credential = {
          token: this.credential?.token ?? '',
          deviceId: message.deviceId,
          deviceName: message.deviceName,
          pairedAt: this.credential?.pairedAt ?? Date.now(),
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
        if (message.code === 'unknown-session') {
          this.notice = 'That session is no longer running on the Mac.'
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
    this.renderContent()
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
      element('h2', undefined, 'Pair with your Mac'),
      element(
        'p',
        'screen__lead',
        `${BRAND.name} on the Mac shows a QR code holding a one-time token. Scanning it opens this page with the token attached, which is all the pairing there is.`,
      ),
    )

    const steps = element('ol', 'steps')
    for (const step of [
      'Open the Mac and show the pairing code.',
      'Scan it with this device’s camera.',
      'Approve this device on the Mac when it appears — pairing alone does not grant access.',
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

    if (this.sessions.length === 0) {
      screen.append(
        element(
          'p',
          'empty',
          this.state.phase === 'online'
            ? 'No sessions are running on the Mac.'
            : 'No sessions to show yet — this list is from the last time the Mac answered.',
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

    const forget = element('button', 'button button--quiet', 'Forget this Mac')
    forget.type = 'button'
    forget.style.margin = '20px 16px'
    forget.style.width = 'auto'
    forget.addEventListener('click', () => this.forget())
    screen.append(forget)
    return screen
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
   * One keystroke or paste on its way to the Mac.
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
