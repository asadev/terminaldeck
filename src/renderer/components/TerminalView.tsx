import { useCallback, useEffect, useRef, useState } from 'react'
import { Terminal, type ITheme } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { chordFor, formatChord } from '../keymap'
import { subscribeTheme } from '../theme'
import { registerTerminal } from '../driving/terminal-registry'

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
 * Exported because `RemoteTerminal` draws a session from another machine and
 * has to look identical to a local one; it is the same terminal to look at,
 * which is the whole promise of opening a remote session from here.
 */
export function terminalTheme(): ITheme {
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
  const searchRef = useRef<SearchAddon | null>(null)
  const findInputRef = useRef<HTMLInputElement>(null)
  const [finding, setFinding] = useState(false)
  const [query, setQuery] = useState('')
  /**
   * Read inside xterm's own callbacks, which are registered once for the life
   * of the terminal. A captured boolean would freeze at whatever the setting
   * was when the session started.
   */
  const copyRef = useRef(copyOnSelect)
  copyRef.current = copyOnSelect

  const copySelection = useCallback((term: Terminal) => {
    const text = term.getSelection()
    if (!text) return
    void navigator.clipboard?.writeText(text).catch(() => {
      // Nothing is lost — the selection is still on screen.
    })
  }, [])

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
    const search = new SearchAddon()
    term.loadAddon(fit)
    term.loadAddon(search)
    term.loadAddon(new WebLinksAddon())
    term.open(host)

    termRef.current = term
    fitRef.current = fit
    searchRef.current = search

    /**
     * The session's own chords, taken before xterm sees them.
     *
     * Handled here rather than in App's global listener because all three act
     * on *this* terminal, and the app has no handle on which one has focus.
     * Returning false is how xterm is told not to pass the key to the pty.
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

    // Status is classified in the main process, which sees output for every
    // session including ones whose terminal isn't currently rendered.
    const offData = window.deck.onSessionData((id, data) => {
      if (id === sessionId) term.write(data)
    })

    const offExit = window.deck.onSessionExit((id) => {
      if (id === sessionId) term.write('\r\n\x1b[2m[process exited]\x1b[0m\r\n')
    })

    const inputDisposable = term.onData((data) => window.deck.writeToSession(sessionId, data))

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

    // Restore anything printed before this component mounted.
    void window.deck.getScrollback(sessionId).then((buf) => {
      if (buf) term.write(buf)
    })

    return () => {
      unregister()
      offTheme()
      offData()
      offExit()
      inputDisposable.dispose()
      selectionDisposable.dispose()
      ro.disconnect()
      term.dispose()
      termRef.current = null
      fitRef.current = null
      searchRef.current = null
    }
  }, [sessionId, copySelection])

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

  useEffect(() => {
    if (finding) findInputRef.current?.select()
  }, [finding])

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
    termRef.current?.focus()
  }, [])

  return (
    <div className="terminal-host" data-visible={visible}>
      <div ref={hostRef} className="terminal-surface" />
      {finding && (
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
      )}
    </div>
  )
}
