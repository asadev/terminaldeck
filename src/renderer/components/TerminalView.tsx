import { useEffect, useRef } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'

interface Props {
  sessionId: string
  visible: boolean
}

/** Reads a CSS custom property so the terminal follows the app theme. */
function token(name: string, fallback: string): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || fallback
}

/**
 * One xterm instance per session. The element stays mounted when the tab is
 * hidden (display:none) so scrollback and cursor position survive tab switches.
 */
export function TerminalView({ sessionId, visible }: Props) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    const term = new Terminal({
      fontFamily: token('--font-mono', 'JetBrains Mono, Menlo, monospace'),
      fontSize: 13,
      lineHeight: 1.35,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 10_000,
      theme: {
        background: token('--bg-primary', '#0e0f13'),
        foreground: token('--text-primary', '#e9eaf1'),
        cursor: token('--accent', '#8588f2'),
        selectionBackground: token('--accent-soft', 'rgba(133,136,242,0.15)'),
      },
    })

    const fit = new FitAddon()
    term.loadAddon(fit)
    term.loadAddon(new WebLinksAddon())
    term.open(host)

    termRef.current = term
    fitRef.current = fit

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

    // Restore anything printed before this component mounted.
    void window.deck.getScrollback(sessionId).then((buf) => {
      if (buf) term.write(buf)
    })

    return () => {
      offData()
      offExit()
      inputDisposable.dispose()
      ro.disconnect()
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
  }, [sessionId])

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

  return <div ref={hostRef} className="terminal-host" data-visible={visible} />
}
