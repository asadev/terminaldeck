import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react'
import { Terminal, type ILinkHandler, type ITheme } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { chordFor, formatChord } from '../keymap'
import { subscribeTheme } from '../theme'
import { pinnedScheme, subscribeTerminalScheme } from '../terminal-scheme'
import { xtermTheme } from '../../shared/terminal-theme'
import { attachRenderer } from '../terminal-renderer'
import { attachClipboardOsc, pasteFilesInto, pastedFiles } from '../terminal-clipboard'
import { TransferNote, useTransferNote } from './TransferNote'
import { draggingFiles, droppedPaths, droppedText, promptWord, resolveDropBridge } from '../terminal-drop'
import { registerTerminal } from '../driving/terminal-registry'
import { holdUntilFilled } from './terminal-backfill'

interface Props {
  sessionId: string
  visible: boolean
  /**
   * Appearance → Terminal font size. Optional so a caller that does not have
   * the settings yet still gets a terminal rather than nothing; the default
   * matches the schema's, so an untouched install looks the same either way.
   */
  fontSize?: number
  /** Appearance → Terminal font. Empty means the app's own monospace face. */
  fontFamily?: string
  /** General → Copy on select. */
  copyOnSelect?: boolean
}

/** Reads a CSS custom property so the terminal follows the app theme. */
function token(name: string, fallback: string): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || fallback
}

export const DEFAULT_TERMINAL_FONT_SIZE = 13

/**
 * The twenty colours a terminal takes from the app, resolved to literals.
 *
 * xterm paints on a canvas, so it cannot read a CSS custom property — the theme
 * has to be resolved to real values every time it is applied. The second
 * argument to each `token` call is only used when the variable is missing,
 * which happens exactly when tokens.css has not been applied to the document
 * yet.
 *
 * These fallbacks are kept in step with the dark theme in tokens.css on
 * purpose. They spent a long time as the purple-blue of a palette that had been
 * replaced twice over (#0e0f13 / #8588f2), so on the rare boot where they did
 * fire, the terminal came up in a colour scheme the rest of the app had not
 * used for months and nobody could reproduce it. If the dark theme's
 * --terminal-bg / --terminal-fg / --accent / --accent-soft change, change these
 * too — `tokens.test.ts` reads these lines and fails when they drift.
 *
 * ## Why the sixteen are here
 *
 * Four of these are the surface and two of the marks on it. The other sixteen
 * are the ANSI palette, and until now this function did not pass them, which
 * meant xterm kept its own Tango-derived defaults. That was invisible in the
 * dark theme, because those defaults were drawn for a near-black ground and
 * `--terminal-bg` is one. It was not invisible in the light theme, where the
 * same set sat on `#e8e8e8` paper at 2.05:1 for yellow and 1.01:1 for bright
 * yellow — output a program had gone to the trouble of colouring, rendered as
 * a blank line. `tokens.css` carries the derivation of the light sixteen and
 * the argument for each exception; this function's only job is to hand them
 * over, and to hand over the dark ones unchanged so a session that has always
 * looked a certain way still does.
 *
 * Passing them also makes the palette follow the theme *switch*: the object
 * below is literals by the time xterm has it, so `subscribeTheme` re-applies
 * the whole thing — see the note on that subscription further down for the bug
 * that taught this file the difference between a colour and a colour token.
 *
 * Not exported, and no longer what a terminal is built with: it is the answer
 * for the one case where nothing has been pinned. {@link terminalTheme} below
 * is what every terminal actually calls, and it is still the only function any
 * of them call — see the note there.
 */
function appPaletteTheme(): ITheme {
  return {
    /* `--terminal-bg` / `--terminal-fg` rather than the app's canvas and ink.
       They are the same values in the dark theme and deliberately not in the
       light one, where the chrome is white and a white terminal on it stops
       looking like a terminal at all. */
    background: token('--terminal-bg', '#191919'),
    foreground: token('--terminal-fg', '#ededed'),
    cursor: token('--accent', '#3b8fee'),
    selectionBackground: token('--accent-soft', 'rgba(59,143,238,0.16)'),
    /* The sixteen, in the order the wire numbers them. Written out one per
       line rather than built from a table, because a fallback that has drifted
       from the sheet is the failure this whole block of comment is about, and
       `tokens.test.ts` reads these very lines to check each one against the
       dark theme's declaration. */
    black: token('--ansi-black', '#2e3436'),
    red: token('--ansi-red', '#cc0000'),
    green: token('--ansi-green', '#4e9a06'),
    yellow: token('--ansi-yellow', '#c4a000'),
    blue: token('--ansi-blue', '#3465a4'),
    magenta: token('--ansi-magenta', '#75507b'),
    cyan: token('--ansi-cyan', '#06989a'),
    white: token('--ansi-white', '#d3d7cf'),
    brightBlack: token('--ansi-bright-black', '#555753'),
    brightRed: token('--ansi-bright-red', '#ef2929'),
    brightGreen: token('--ansi-bright-green', '#8ae234'),
    brightYellow: token('--ansi-bright-yellow', '#fce94f'),
    brightBlue: token('--ansi-bright-blue', '#729fcf'),
    brightMagenta: token('--ansi-bright-magenta', '#ad7fa8'),
    brightCyan: token('--ansi-bright-cyan', '#34e2e2'),
    brightWhite: token('--ansi-bright-white', '#eeeeec'),
  }
}

/**
 * The colours this terminal is painted in, whichever way they were chosen.
 *
 * Two sources, one answer, and that is the whole point of the shape. Until a
 * person opens Appearance → Terminal, nothing is pinned and this is exactly
 * {@link appPaletteTheme} — the app's own theme, resolved from `tokens.css`,
 * unchanged from the day this file was written. Once a scheme is chosen, it is
 * that scheme's twenty-one colours instead, and the app's light/dark stops
 * having any say over the inside of a session.
 *
 * That second sentence is a decision and not a side effect. Somebody who picks
 * Solarized Light has picked Solarized Light; a terminal that threw it away
 * because the desktop went dark at sunset would be the app overruling the one
 * choice the pane exists to offer. Following the app is still available and
 * still the default — it is the first entry in the picker, and it is what
 * `null` here means.
 *
 * Exported because `RemoteTerminal` and `ServerTerminal` draw sessions from
 * other machines and have to look identical to a local one; it is the same
 * terminal to look at, which is the whole promise of opening a remote session
 * from here. The cast is the seam between `src/shared`, which must not import
 * a browser package for a type, and `ITheme`: every key in `XtermTheme` is an
 * `ITheme` key, which `terminal-scheme.test.ts` asserts field by field rather
 * than trusting this line.
 */
export function terminalTheme(): ITheme {
  const scheme = pinnedScheme()
  return scheme === null ? appPaletteTheme() : (xtermTheme(scheme) as ITheme)
}

/**
 * The keymap ids this component implements.
 *
 * Named rather than described, so the reachability test can tie the three
 * bindings in `KEYMAP` to the code that answers them. All three were printed
 * in the shortcuts sheet, under "In a session", with no implementation
 * anywhere: `run()` in App.tsx does not know them, so ⌘F, ⌘⇧K and ⌘⇧C fell
 * through to xterm, which does nothing with any of them. A sheet that lists a
 * chord the app ignores is the same lie as a roadmap that ticks a feature
 * nobody can reach.
 *
 * They live here rather than in the app-wide dispatcher because all three act
 * on *this* terminal, and the app has no handle on which one has focus.
 */
export const TERMINAL_COMMANDS = ['terminal.find', 'terminal.clear', 'terminal.copy'] as const

export type TerminalCommand = (typeof TERMINAL_COMMANDS)[number]

/** Which of them a keystroke is, if any. Pure, so it is testable without a DOM. */
export function terminalChord(event: {
  key: string
  metaKey?: boolean
  ctrlKey?: boolean
  shiftKey?: boolean
  altKey?: boolean
}): TerminalCommand | null {
  if (event.altKey) return null
  const mod = Boolean(event.metaKey) || Boolean(event.ctrlKey)
  if (!mod) return null
  const key = event.key.toLowerCase()
  if (key === 'f' && !event.shiftKey) return 'terminal.find'
  if (key === 'k' && event.shiftKey) return 'terminal.clear'
  if (key === 'c' && event.shiftKey) return 'terminal.copy'
  return null
}

/**
 * Put the selection on the clipboard, if there is one.
 *
 * Module-level rather than a `useCallback` inside the component, because two
 * different things need it — the ⌘⇧C chord, which now belongs to every terminal
 * in the app through {@link useTerminalFind}, and copy-on-select, which belongs
 * only to a local session. A hook cannot be called from the first and a closure
 * inside the component cannot be reached by it.
 */
export function copySelection(term: Terminal): void {
  const text = term.getSelection()
  if (!text) return
  void navigator.clipboard?.writeText(text).catch(() => {
    // Nothing is lost — the selection is still on screen.
  })
}

/**
 * Which session a link clicked in a terminal came out of.
 *
 * Both fields are optional because both are genuinely unknown in some terminal
 * this hook serves: a server shell has no local session id, and a session on
 * this machine has no machine id. Main is told what is known and refuses to
 * guess the rest — an unattributed URL still opens, it simply does not claim to
 * belong to a session it cannot name.
 */
export interface TerminalLink {
  sessionId?: string
  machineId?: string
}

/**
 * The two link handlers a terminal is given, and the defect they replace.
 *
 * ## What clicking a URL did before this
 *
 * `WebLinksAddon` was loaded with no handler at all, so it kept its own. In
 * `@xterm/addon-web-links` 0.12.0 — the copy in this repo's `node_modules` —
 * that default is:
 *
 *     const newWindow = window.open();
 *     if (newWindow) { …; newWindow.location.href = uri; }
 *     else { console.warn('Opening link blocked as opener could not be cleared'); }
 *
 * `window.open()` with **no argument**. In Electron that arrives at
 * `mainWindow.webContents.setWindowOpenHandler` in `main/index.ts` as
 * `about:blank`, and that handler answers `{ action: 'deny' }` — nothing in this
 * app should ever get a bare Chromium window. So `window.open()` returns `null`,
 * the addon takes its `else` branch, writes a line to a console nobody is
 * reading, and **the address is discarded**. Separately, the same handler passes
 * that `about:blank` to `openAppLink`, which routes it to a tab because
 * `isNavigationAllowed` accepts it (`main/browser-url.ts`) — so the visible
 * result of clicking a URL an agent printed is an **empty browser tab, with the
 * address thrown away**. Both halves are real and they are the same click.
 *
 * The OSC 8 half was worse in a different direction. `OscLinkProvider`'s
 * `defaultActivate` runs `confirm('Do you want to navigate to …\n\nWARNING: This
 * link could potentially be dangerous')` and then does the same discarded
 * `window.open()`, so a hyperlinked word printed by a well-behaved CLI raised a
 * raw browser dialog inside the app's own chrome. Setting `linkHandler` is what
 * xterm consults instead of that function — `OscLinkProvider.ts` picks between
 * the two on exactly that option — so it is the whole fix, not a workaround
 * layered over it.
 *
 * (Read from the shipped sources of both packages and from the two handlers in
 * `main/`, not from a click in a running build.)
 *
 * ## Why a factory taking a function
 *
 * `attach` is a `useCallback` registered once for the life of a terminal, and
 * these handlers live as long as the terminal does. A session id captured at
 * that moment would freeze, so the identity is *read* at click time rather than
 * closed over — the same reason `copyRef` exists below for copy-on-select.
 *
 * Module-level and exported so it can be tested without a DOM. This project's
 * test setup has none at all, so a handler that only exists inside a mounted
 * terminal is a handler nothing can exercise.
 */
export function terminalLinkHandlers(read: () => TerminalLink): {
  /** For `WebLinksAddon`: a bare URL xterm found by matching the screen. */
  web: (event: MouseEvent, uri: string) => void
  /** For `Terminal.options.linkHandler`: an OSC 8 hyperlink. */
  osc: ILinkHandler
} {
  const open = (url: string): void => {
    // Not awaited: a click is not a place to wait on the main process, and the
    // answer is a route the terminal has nothing to do with — main opens the
    // page, or hands it to the machine, and says which in the browser strip.
    void window.deck.openLink({ url, ...read() })
  }
  return {
    web: (_event, uri) => open(uri),
    osc: {
      activate: (_event, text) => open(text),
      // `allowNonHttpProtocols` is deliberately left off. With it, a page could
      // print an OSC 8 sequence carrying any scheme it liked and have this app
      // hand it onward; xterm drops those before `activate` is reached while it
      // is off, which is the same posture `NEVER_LEAVES` takes in
      // `main/link-open.ts` one layer down.
    },
  }
}

/**
 * What a terminal gets from this hook: the addons, the chords, and the bar.
 *
 * `attach` is called once, on a terminal that has already been `open`ed, from
 * inside the effect that built it. It loads no state of its own into React, so
 * a terminal that is replaced simply calls it again.
 */
export interface TerminalFind {
  /** Load search and links, and take this terminal's three chords. */
  attach(term: Terminal): void
  /** The find bar, when it is up. Render it inside a positioned element. */
  bar: ReactElement | null
}

/**
 * Find, clickable links and the session chords — for **every** terminal in the
 * app, not only a local one.
 *
 * ## The gap this closes
 *
 * `RemoteTerminal` and `ServerTerminal` loaded `FitAddon` and nothing else. So a
 * session on another machine had no ⌘F, no clickable URLs and no ⌘⇧C, while a
 * session on this one had all three — and both were drawn as the same terminal,
 * in the same window, deliberately identical down to the sixteen ANSI colours.
 * Asad has now said the rule four times:
 *
 *   > *"the shape of the application should not be changing for local and remote
 *   > devices. It should act like that same."*
 *
 * Both of those files carried the opposite decision in a comment — *"the
 * behaviour deliberately is not [shared]: no find bar, no clear, no copy
 * chords, because those are keymap bindings that belong to a focused session in
 * the main window and this is a pane inside a panel"* — and that argument was
 * true when it was written and is not any more. A server shell is a **tab** now,
 * with a row in the rail and its own ⌘W, mounted by the window exactly like a
 * session; a device session is a pane somebody types into all day. Neither is a
 * rectangle on a page, which is what "a pane inside a panel" meant.
 *
 * ## Why the hook lives in this file
 *
 * Same reason `terminalTheme()` does, and it is the precedent this repository
 * has already tested: `wiring.test.ts` pins `RemoteTerminal` to importing the
 * palette *from here* so that no second copy can drift. The chord ids also have
 * to stay in this file — `reachable.test.ts` reads `TerminalView.tsx` for the
 * literal `terminal.find` and calls the binding unimplemented if it is not
 * there — and a hook that answers those chords belongs next to the table that
 * names them.
 *
 * The three addons are built per terminal, inside `attach`, because an addon
 * belongs to one terminal and dies with it. Nothing here has to be disposed by
 * the caller: `term.dispose()` disposes every addon loaded into it.
 *
 * ## The link argument, and why it is optional
 *
 * `link` says which session this terminal is, so a URL clicked in it can be
 * opened in that session's own browser window rather than left to leave the app
 * — see {@link terminalLinkHandlers} for what it was doing instead. It is
 * optional because a caller that does not pass one is still far better off than
 * before: the address reaches the main process and opens somewhere, it simply
 * arrives unattributed. Nothing here invents a session id to fill the gap.
 */
export function useTerminalFind(link?: TerminalLink): TerminalFind {
  const termRef = useRef<Terminal | null>(null)
  const searchRef = useRef<SearchAddon | null>(null)
  const findInputRef = useRef<HTMLInputElement>(null)
  const [finding, setFinding] = useState(false)
  const [query, setQuery] = useState('')

  /*
   * Held in a ref and rewritten on every render, for the reason `copyRef` is in
   * the component below: `attach` is a `useCallback` with an empty dependency
   * list, so anything it closes over is frozen at the moment the terminal was
   * built. A session that was later re-pointed at another machine would still be
   * opening its links against the identity it had on the day it started.
   */
  const linkRef = useRef<TerminalLink>(link ?? {})
  linkRef.current = link ?? {}

  useEffect(() => {
    if (finding) findInputRef.current?.select()
  }, [finding])

  const attach = useCallback((term: Terminal) => {
    const search = new SearchAddon()
    term.loadAddon(search)
    /*
     * Links, handled by this app rather than by whatever the two packages do on
     * their own — which was to throw the address away twice over.
     * {@link terminalLinkHandlers} carries the whole of that.
     *
     * `options.linkHandler` is assigned here rather than passed to
     * `new Terminal({…})`, and that is what makes the OSC 8 fix reach every
     * terminal in the app instead of only the local one: `RemoteTerminal` and
     * `ServerTerminal` build their own terminals and share only this hook.
     * xterm re-reads the option inside `provideLinks` on every scan, so setting
     * it on a terminal that is already open is not a race.
     */
    const links = terminalLinkHandlers(() => linkRef.current)
    term.loadAddon(new WebLinksAddon(links.web))
    term.options.linkHandler = links.osc
    termRef.current = term
    searchRef.current = search

    /**
     * The session's own chords, taken before xterm sees them.
     *
     * Handled per terminal rather than in App's global listener because all
     * three act on *this* terminal, and the app has no handle on which one has
     * focus. Returning false is how xterm is told not to pass the key to
     * whatever is on the other end — a pty here, a device or a server elsewhere.
     */
    term.attachCustomKeyEventHandler((event) => {
      if (event.type !== 'keydown') return true
      const chord = terminalChord(event)
      if (!chord) return true
      event.preventDefault()
      if (chord === 'terminal.find') setFinding(true)
      else if (chord === 'terminal.clear') term.clear()
      else copySelection(term)
      return false
    })
  }, [])

  const step = useCallback(
    (back: boolean) => {
      if (!query) return
      const search = searchRef.current
      if (!search) return
      if (back) search.findPrevious(query)
      else search.findNext(query)
    },
    [query],
  )

  const closeFind = useCallback(() => {
    searchRef.current?.clearDecorations()
    setFinding(false)
    try {
      termRef.current?.focus()
    } catch {
      // The terminal this bar was opened over has been disposed — a session
      // that ended, or a pane that was closed with the bar up. There is
      // nothing left to give the keyboard back to, and that is not an error.
    }
  }, [])

  const bar = !finding ? null : (
    <div className="terminal-find" role="search">
      <input
        ref={findInputRef}
        className="terminal-find-input"
        type="search"
        value={query}
        placeholder="Find in this session"
        aria-label="Find in this session"
        onChange={(event) => {
          setQuery(event.target.value)
          searchRef.current?.findNext(event.target.value)
        }}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            event.preventDefault()
            closeFind()
          } else if (event.key === 'Enter') {
            event.preventDefault()
            step(event.shiftKey)
          }
        }}
      />
      <button
        type="button"
        className="terminal-find-btn"
        aria-label="Previous match"
        // ⇧↩ is Apple's way of writing it and means nothing on a Windows
        // keyboard, where the same two keys are printed Shift and Enter.
        title={`Previous match (${formatChord('shift+enter')})`}
        onClick={() => step(true)}
      >
        ↑
      </button>
      <button
        type="button"
        className="terminal-find-btn"
        aria-label="Next match"
        title={`Next match (${formatChord('enter')})`}
        onClick={() => step(false)}
      >
        ↓
      </button>
      <button
        type="button"
        className="terminal-find-btn"
        aria-label="Close find"
        title={`Close (Esc) · reopen with ${chordFor('terminal.find') ?? 'the find shortcut'}`}
        onClick={closeFind}
      >
        ✕
      </button>
    </div>
  )

  return { attach, bar }
}

/**
 * One xterm instance per session. The element stays mounted when the tab is
 * hidden (display:none) so scrollback and cursor position survive tab switches.
 *
 * The three appearance settings are applied to the *live* terminal rather than
 * only at construction. Settings has offered a font size and a font name since
 * the window was written and neither reached a terminal — they rendered a
 * preview in the settings pane and nothing else, which is a control that looks
 * like it works.
 */
export function TerminalView({
  sessionId,
  visible,
  fontSize = DEFAULT_TERMINAL_FONT_SIZE,
  fontFamily = '',
  copyOnSelect = false,
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  /*
   * Destructured rather than held as one object, and that is load-bearing: the
   * hook returns a fresh `{ attach, bar }` on every render, so putting it in the
   * dependency list below would tear down and rebuild the terminal — the pty's
   * whole scrollback with it — every time the find field takes a keystroke.
   * `attach` is stable; `bar` is the part that changes and it is only rendered.
   *
   * The object handed in is rebuilt every render and that is deliberately fine:
   * the hook copies it into a ref rather than depending on it, so it never
   * reaches the dependency list this comment is about. A session on this machine
   * has no machine id, which is what the empty field means everywhere else here.
   */
  const { attach: attachFind, bar: findBar } = useTerminalFind({ sessionId })
  /**
   * Read inside xterm's own callbacks, which are registered once for the life
   * of the terminal. A captured boolean would freeze at whatever the setting
   * was when the session started.
   */
  const copyRef = useRef(copyOnSelect)
  copyRef.current = copyOnSelect
  /*
   * The one line this pane may draw over the terminal.
   *
   * New here, and it is the R5 half of the clipboard work: a paste of an image
   * into a session on **this** computer can fail — the pixels have to become a
   * file on this disk before anything can be handed a path to them — and a local
   * pane that refused in silence while the remote pane beside it said so would
   * be the app changing shape between local and remote. `TransferNote` carries
   * the argument and is the same component the remote pane draws.
   */
  const { line: note, say } = useTransferNote()

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    const term = new Terminal({
      fontFamily: token('--font-mono', 'JetBrains Mono, Menlo, monospace'),
      fontSize: DEFAULT_TERMINAL_FONT_SIZE,
      lineHeight: 1.35,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 10_000,
      theme: terminalTheme(),
    })

    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(host)

    termRef.current = term
    fitRef.current = fit

    // Search, links and the three session chords — the same set every terminal
    // in this app gets, from the one hook that owns them.
    attachFind(term)

    /*
     * The GPU, or deliberately not it.
     *
     * After `open`, because a renderer can only replace a DOM that exists, and
     * on `host` rather than on xterm's own element because `host` is the box
     * the layout shows and hides — which is what decides whether this terminal
     * is one of the few holding a WebGL context. `terminal-renderer.ts` carries
     * the whole argument, the measurements and the four rules it has to meet.
     */
    const detachRenderer = attachRenderer(term, host)

    // Size once the element has real dimensions, then tell the PTY.
    const syncSize = () => {
      try {
        fit.fit()
        window.deck.resizeSession(sessionId, term.cols, term.rows)
      } catch {
        /* element not laid out yet */
      }
    }
    requestAnimationFrame(syncSize)

    const ro = new ResizeObserver(syncSize)
    ro.observe(host)

    /*
     * Nothing paints until this terminal has its history in it.
     *
     * A local session's terminal is rebuilt far more often than it looks: every
     * pane in this window is drawn by one function, so opening Files, Settings,
     * a session on another machine or the split layout unmounts every terminal
     * and coming back builds them again. Each rebuild re-wrote the whole
     * scrollback, and xterm yields to the renderer every 12 ms while it parses —
     * so the session scrolled its own history past before settling. See
     * `terminal-backfill.ts`, which carries the measurement.
     *
     * `release` is called with the buffer below, so a local session is held for
     * exactly one round trip to the main process rather than on a timer.
     */
    const backfill = holdUntilFilled(term, host)

    // Status is classified in the main process, which sees output for every
    // session including ones whose terminal isn't currently rendered.
    const offData = window.deck.onSessionData((id, data) => {
      if (id === sessionId) backfill.push(data)
    })

    const offExit = window.deck.onSessionExit((id) => {
      if (id === sessionId) backfill.push('\r\n\x1b[2m[process exited]\x1b[0m\r\n')
    })

    const inputDisposable = term.onData((data) => window.deck.writeToSession(sessionId, data))

    /*
     * A program in this session putting something on this machine's clipboard.
     *
     * OSC 52, which xterm.js does not implement — so a `tmux` copy, a `vim`
     * yank or an agent copying its own output was parsed, matched nothing and
     * was dropped in silence. Attached here as well as on a remote pane, and
     * that symmetry is the point: *"the shape of the application should not be
     * changing for local and remote devices."* No refusal callback, because a
     * local session has no line to draw one on — `terminal-clipboard.ts` says
     * what each refusal is.
     */
    const detachClipboard = attachClipboardOsc(term, (line) => say(line))

    /*
     * A file or an image on the clipboard, pasted at a session on this machine.
     *
     * The same handler the remote pane has, running the same function, and that
     * symmetry is the requirement rather than tidiness: *"it should not matter
     * which device I am on currently running the session."* A file copied in
     * Finder already has a path and is typed straight at the prompt; a clipboard
     * image has no file anywhere, so its bytes are written to one first — see
     * `main/local-stage.ts` for where and why.
     *
     * In the capture phase and on the host element, so this runs before xterm's
     * own paste handler on the textarea inside it. A plain text paste never
     * reaches any of this and is untouched.
     */
    const onPaste = (event: ClipboardEvent): void => {
      const carried = pastedFiles(event.clipboardData, resolveDropBridge())
      if (carried.length === 0) return
      event.preventDefault()
      event.stopPropagation()
      void pasteFilesInto(carried, { machineId: '' }, () => termRef.current, say)
    }
    host.addEventListener('paste', onPaste, true)

    /**
     * Copy on select, the Unix terminal idiom.
     *
     * Guarded on a non-empty selection: xterm fires this when a selection is
     * *cleared* too, and writing '' to the clipboard on every click would wipe
     * whatever the user had copied from somewhere else.
     */
    const selectionDisposable = term.onSelectionChange(() => {
      if (copyRef.current) copySelection(term)
    })

    /**
     * Repaint when the app's theme changes, not only when a terminal is built.
     *
     * The colours above are literals by the time xterm has them, so switching
     * Appearance → Theme left every terminal that was already on screen in the
     * old palette: flip to Light and an open session was a black slab in a
     * white window; flip back and a session made while light was a white slab
     * in a black one. Remounting fixed it, which is why the same session looked
     * right in Split mode — a different tree, a new terminal — and wrong in
     * Terminal mode a second later. Nothing in the code says "colour" at that
     * moment, which is exactly why it survived: it is invisible in a diff and
     * unmissable in a screenshot.
     *
     * `subscribeTheme` has existed for this since the theme controller was
     * written ("e.g. to recolour the terminals") and nothing had ever called
     * it. `wiring.test.ts` now pins the two together.
     */
    const offTheme = subscribeTheme(() => {
      term.options.theme = terminalTheme()
    })

    /*
     * And when the *scheme* changes, which the app theme knows nothing about.
     *
     * Appearance → Terminal can move all twenty-one colours without the app's
     * light/dark moving at all, so `subscribeTheme` above never fires for it.
     * Without this, choosing a scheme repainted only the terminals built after
     * the choice — which on a window with three sessions open is two sessions
     * in the old colours and one in the new, the exact defect the theme
     * subscription above was written for, one layer along.
     */
    const offScheme = subscribeTerminalScheme(() => {
      term.options.theme = terminalTheme()
    })

    /*
     * Publish this terminal so the copilot's focus overlay can point at it.
     *
     * The overlay is a window-level surface with no React relationship to any
     * pane — it draws one box over whichever session is on screen — so it needs
     * a terminal it does not own and cannot be handed as a prop without
     * threading a ref through four components that have no use for one.
     * `driving/terminal-registry.ts` carries the argument in full.
     *
     * Registered here rather than beside `term.open()` above so it lands after
     * the addons: the registry's geometry reads `.xterm-screen`, which only
     * exists once xterm has built its DOM.
     */
    const unregister = registerTerminal(sessionId, { term, host })

    /*
     * Restore anything printed before this component mounted.
     *
     * Handed to `release` rather than written, and that also settles an ordering
     * this effect used to get backwards: anything the session printed while the
     * read was in flight was written *first* and the history appended after it.
     * Held chunks go in behind the buffer now, which is the order they happened
     * in.
     *
     * `catch` releases too. A read that fails is a terminal with no history to
     * show, not a terminal that never appears.
     */
    void window.deck
      .getScrollback(sessionId)
      .then((buf) => backfill.release(buf))
      .catch(() => backfill.release())

    return () => {
      backfill.stop()
      unregister()
      offTheme()
      offScheme()
      offData()
      offExit()
      inputDisposable.dispose()
      host.removeEventListener('paste', onPaste, true)
      detachClipboard()
      selectionDisposable.dispose()
      ro.disconnect()
      // Before `term.dispose()`: the pool has to take its seat out of the count
      // while the terminal it belongs to still exists, or the next terminal to
      // come on screen is refused a context that nothing is using.
      detachRenderer()
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
  }, [sessionId, attachFind])

  /**
   * Type, applied to the terminal that already exists.
   *
   * Changing either metric changes how many columns fit, so the PTY has to be
   * told — without the refit the shell keeps wrapping at the old width and the
   * output goes ragged.
   */
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    const family = fontFamily.trim() || token('--font-mono', 'JetBrains Mono, Menlo, monospace')
    if (term.options.fontSize === fontSize && term.options.fontFamily === family) return
    term.options.fontSize = fontSize
    term.options.fontFamily = family
    try {
      fitRef.current?.fit()
      window.deck.resizeSession(sessionId, term.cols, term.rows)
    } catch {
      /* not laid out */
    }
  }, [fontSize, fontFamily, sessionId])

  // Re-fit when this tab becomes visible again — xterm cannot measure a hidden element.
  useEffect(() => {
    if (!visible) return
    const id = requestAnimationFrame(() => {
      try {
        fitRef.current?.fit()
        const term = termRef.current
        if (term) window.deck.resizeSession(sessionId, term.cols, term.rows)
        term?.focus()
      } catch {
        /* not laid out */
      }
    })
    return () => cancelAnimationFrame(id)
  }, [visible, sessionId])

  /**
   * Something dropped on a session running on this machine.
   *
   * The file is already here, so there is nothing to send: what a drop means is
   * the path, quoted, at the prompt — which is what every terminal emulator on
   * this platform does with a dropped file, and what the phone does with the
   * path a Mac answers an upload with. Nothing else is written and no Return is
   * sent; what to do with the path is the person's decision.
   *
   * Before this existed there was no drop handler on any terminal in this app,
   * so a file dragged from Finder reached Chromium's default and **navigated the
   * window to it** — the application replaced by a picture of the photo. The
   * `preventDefault` on the first line of both handlers is what stops that, and
   * it has to be on `dragOver` too or `drop` never fires at all.
   *
   * `term.paste` rather than a raw write, so a session in bracketed-paste mode
   * receives this exactly as it would receive a ⌘V of the same text.
   */
  const onDrop = useCallback((event: React.DragEvent<HTMLDivElement>): void => {
    event.preventDefault()
    const term = termRef.current
    if (!term) return
    const files = Array.from(event.dataTransfer?.files ?? [])
    const bridge = files.length === 0 ? null : resolveDropBridge()
    const paths = bridge ? droppedPaths(files, bridge) : []
    if (paths.length > 0) {
      for (const path of paths) term.paste(promptWord(path))
      return
    }
    /*
     * Nothing on this disk was dropped — dragged text, or an image out of a web
     * page, both of which produce `File`-shaped items with no path behind them.
     * The same drag almost always carries the text or the URL, and typing that
     * is a better answer than the gesture doing nothing at all, which is the
     * failure this whole pass is about.
     */
    const text = droppedText(event.dataTransfer?.getData('text/plain') ?? '')
    if (text !== '') term.paste(text)
  }, [])

  return (
    <div
      className="terminal-host"
      data-visible={visible}
      onDragOver={(event) => {
        if (!draggingFiles(event.dataTransfer) && !event.dataTransfer?.types.includes('text/plain')) return
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
      }}
      onDrop={onDrop}
    >
      <div ref={hostRef} className="terminal-surface" />
      {findBar}
      <TransferNote line={note} />
    </div>
  )
}
