/**
 * The terminal surface: xterm.js, sized to a phone, wired to the socket.
 *
 * Two things here are not obvious.
 *
 * **The Ctrl workaround.** See `controlByteForCode` in `keybar.ts` for the full
 * story — through xterm.js 6.0.0, Safari on iOS with a hardware keyboard
 * reports Ctrl+C as `keyCode: 13`, xterm reads `keyCode`, and the session gets
 * a carriage return instead of an interrupt. This file intercepts Ctrl chords
 * before xterm's key handler sees them and decodes them from
 * `KeyboardEvent.code`, which names the physical key and is not affected.
 *
 * **The size is negotiated, not chosen.** `FitAddon` computes cols and rows
 * from the element, and the result is clamped to the range the protocol
 * accepts. A phone in portrait with a large accessibility font can compute
 * fewer than twenty columns, and an unclamped `resize` frame is one the server
 * rejects — closing the socket over a font-size setting.
 */

import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import { MAX_COLS, MAX_ROWS, MIN_COLS, MIN_ROWS } from '../../src/main/remote/protocol'
import { controlByteForCode } from './keybar'

export interface TerminalSize {
  cols: number
  rows: number
}

export interface TerminalHandlers {
  /** Bytes the user produced. Already folded through any armed modifier. */
  onData(data: string): void
  /** The size changed and the far end needs telling. */
  onResize(size: TerminalSize): void
}

export interface TerminalHandle {
  readonly element: HTMLElement
  write(data: string): void
  /** Drop everything on screen and in the scrollback. */
  reset(): void
  size(): TerminalSize
  /** Recompute the size from the element. Safe to call often. */
  fit(): void
  focus(): void
  /** Dim the surface while the connection is not live. */
  setLive(live: boolean): void
  dispose(): void
}

/**
 * Colours, taken from the desktop's own tokens so the two look like one app.
 *
 * They are restated rather than imported: `styles/tokens.css` is CSS custom
 * properties on a `[data-theme]` element, and xterm wants a colour object at
 * construction time. Reading them back out of the cascade would mean this could
 * not build a terminal before the stylesheet had loaded.
 */
const THEME = {
  background: '#191919',
  foreground: '#d4d4d4',
  cursor: '#d4d4d4',
  cursorAccent: '#191919',
  selectionBackground: 'rgba(82, 156, 202, 0.35)',
  black: '#2b2b2b',
  red: '#ff7369',
  green: '#4dab9a',
  yellow: '#c9a227',
  blue: '#529cca',
  magenta: '#9a6dd7',
  cyan: '#4dab9a',
  white: '#d4d4d4',
  brightBlack: '#6f6f6f',
  brightRed: '#ff8b82',
  brightGreen: '#5fc2b0',
  brightYellow: '#e0b93a',
  brightBlue: '#6cb3de',
  brightMagenta: '#b085e5',
  brightCyan: '#5fc2b0',
  brightWhite: '#f0f0f0',
} as const

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, Math.round(value)))
}

export function createTerminal(handlers: TerminalHandlers): TerminalHandle {
  const element = document.createElement('div')
  element.className = 'terminal'

  const term = new Terminal({
    // 13px is the smallest that stays readable on a phone at arm's length, and
    // it fits 80 columns on a 6.1" screen in landscape — the width most CLI
    // output is still written for.
    fontSize: 13,
    lineHeight: 1.2,
    fontFamily: "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
    theme: THEME,
    cursorBlink: true,
    // Enough to scroll back through a build, small enough that a phone with
    // 2 GB of RAM does not start swapping while a session logs at speed.
    scrollback: 5000,
    // For the hardware keyboards this client is actually used with — an iPad
    // Magic Keyboard, a Mac in a browser tab — Option is the Meta a shell
    // expects, and without this Option+B walks a word on neither.
    macOptionIsMeta: true,
  })

  const fitAddon = new FitAddon()
  term.loadAddon(fitAddon)
  term.open(element)

  /**
   * Ctrl chords, decoded here rather than by xterm.
   *
   * Returning false tells xterm not to process the event. On a browser without
   * the iOS bug this produces exactly the byte xterm would have produced, so
   * the workaround costs nothing where it is not needed — which matters,
   * because it cannot be conditioned on a reliable test for the bug.
   */
  term.attachCustomKeyEventHandler((event) => {
    if (event.type !== 'keydown') return true
    if (!event.ctrlKey || event.altKey || event.metaKey) return true
    const byte = controlByteForCode(event.code)
    if (byte === null) return true
    handlers.onData(byte)
    return false
  })

  term.onData((data) => handlers.onData(data))

  const size = (): TerminalSize => ({
    cols: clamp(term.cols, MIN_COLS, MAX_COLS),
    rows: clamp(term.rows, MIN_ROWS, MAX_ROWS),
  })

  let last: TerminalSize = size()
  term.onResize(() => {
    const next = size()
    if (next.cols === last.cols && next.rows === last.rows) return
    last = next
    handlers.onResize(next)
  })

  return {
    element,
    write: (data) => term.write(data),
    reset: () => term.reset(),
    size,
    fit(): void {
      try {
        fitAddon.fit()
      } catch {
        // `fit` reads the element's box; a call while the terminal screen is
        // hidden measures zero and throws. Nothing to do but skip this one —
        // the next call, after the screen is shown, gets a real measurement.
      }
    },
    focus: () => term.focus(),
    setLive(live: boolean): void {
      element.classList.toggle('terminal--stale', !live)
      // Not just a class: a blinking cursor over frozen output is the single
      // most convincing part of a fake-connected terminal.
      term.options.cursorBlink = live
    },
    dispose(): void {
      term.dispose()
      element.remove()
    },
  }
}
