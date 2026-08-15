import { useEffect, useRef } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { terminalTheme } from '../components/TerminalView'
import { subscribeTheme } from '../theme'
import type { MachinesBridge } from './types'

/**
 * A session on another machine, on this screen.
 *
 * ## Why this is not `TerminalView`
 *
 * `TerminalView` is the app's terminal and it is bound to `window.deck`'s
 * session channels by name — `writeToSession`, `onSessionData`, `getScrollback`
 * — with the session id as its only handle. A session on another machine has
 * two handles, the machine and the session, and its bytes arrive on a different
 * channel. Threading a transport through `TerminalView` would put a branch in
 * the one component every local session already depends on, for the sake of a
 * feature that is one screen away.
 *
 * So the *xterm setup* is duplicated here and the *behaviour* deliberately is
 * not: no find bar, no clear, no copy chords, because those are keymap bindings
 * that belong to a focused session in the main window and this is a pane inside
 * a panel. What is shared is what has to be — the theme comes from the same CSS
 * custom properties, so this terminal and a local one are the same terminal to
 * look at, which is the whole point of "opening a remote session must feel like
 * opening a local one".
 *
 * If a third caller ever needs a terminal, the right move is to lift the setup
 * into a hook that takes a transport, not to add a second flag to either of
 * these files.
 *
 * ## Scrollback comes from the far machine, not from here
 *
 * There is no `getScrollback` equivalent: the protocol replays what the session
 * has already printed as `output` frames marked `replay` the moment this end
 * attaches. Nothing here has to tell the two apart — replayed bytes and live
 * bytes are both just bytes to a terminal — and the flag exists on the wire for
 * clients that want to suppress a notification for scrollback, which this one
 * has none of.
 */

/** Reads a CSS custom property, so the terminal follows the app theme. */
function token(name: string, fallback: string): string {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

interface Props {
  machineId: string
  sessionId: string
  bridge: MachinesBridge
  /**
   * Subscribe to this session's bytes.
   *
   * Passed in rather than resolved here because the panel is already holding
   * one subscription to `onMachineOutput` for every session on screen, and a
   * second one per terminal would deliver the same chunk twice to whichever
   * pane happened to be mounted first.
   */
  subscribe(handler: (data: string) => void): () => void
  fontSize?: number
  fontFamily?: string
}

export const DEFAULT_REMOTE_FONT_SIZE = 13

export function RemoteTerminal({
  machineId,
  sessionId,
  bridge,
  subscribe,
  fontSize = DEFAULT_REMOTE_FONT_SIZE,
  fontFamily = '',
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    const term = new Terminal({
      fontFamily: token('--font-mono', 'JetBrains Mono, Menlo, monospace'),
      fontSize: DEFAULT_REMOTE_FONT_SIZE,
      lineHeight: 1.35,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 10_000,
      // The local terminal's own colours, from the one function that resolves
      // them — a remote session that did not match a local one would be the
      // first thing anybody noticed about this pane. It is applied again below
      // whenever the theme changes, for the reason written out there.
      theme: terminalTheme(),
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(host)
    termRef.current = term
    fitRef.current = fit

    // Fitted before the attach, so the first screen the far machine paints is
    // already the shape of this pane. Attaching first and resizing after makes
    // every session open with one reflow of scrambled output.
    try {
      fit.fit()
    } catch {
      // The pane can be zero-sized on the first frame — a panel that has not
      // been laid out yet — and the observer below fits it the moment it is not.
    }
    void bridge.attachMachineSession(machineId, sessionId, term.cols, term.rows)

    // Switching the app's theme has to reach a terminal that already exists.
    // Resolved colours do not follow the sheet on their own, so without this a
    // remote session stays in the palette it was opened in — see the note in
    // `TerminalView`, where the same omission left every session a black slab
    // on a white app.
    const offTheme = subscribeTheme(() => {
      term.options.theme = terminalTheme()
    })

    const offData = subscribe((data) => term.write(data))
    const input = term.onData((data) => {
      void bridge.writeToMachineSession(machineId, sessionId, data)
    })

    const observer = new ResizeObserver(() => {
      try {
        fit.fit()
      } catch {
        // Mid-teardown, or a pane with no size. Neither is worth an error.
        return
      }
      void bridge.resizeMachineSession(machineId, sessionId, term.cols, term.rows)
    })
    observer.observe(host)

    return () => {
      observer.disconnect()
      input.dispose()
      offTheme()
      offData()
      // Detached explicitly. The far machine keeps the session running — that
      // is the point of a session — but it stops sending output to a terminal
      // that no longer exists, and a link that is still up would otherwise carry
      // the bytes of every pane anybody had ever opened.
      void bridge.detachMachineSession(machineId, sessionId)
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
  }, [machineId, sessionId, bridge, subscribe])

  // Applied to the live terminal rather than only at construction, so a change
  // in Appearance reaches a pane that is already open. Settings has shipped a
  // font size that never reached a terminal once already.
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    term.options.fontSize = fontSize
    if (fontFamily !== '') term.options.fontFamily = fontFamily
    try {
      fitRef.current?.fit()
    } catch {
      // Same as above: a pane with no size yet.
    }
  }, [fontSize, fontFamily])

  return <div className="machines-terminal" ref={hostRef} />
}
