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
import { Terminal, type ITheme } from '@xterm/xterm'
import { MAX_COLS, MAX_ROWS, MIN_COLS, MIN_ROWS } from '../../src/main/remote/protocol'
import { controlByteForCode } from './keybar'
import { clampTextSize, STANDARD_TEXT_SIZE } from './text-size'
import type { Appearance } from './theme'

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
  /**
   * Repaint in the other appearance, without losing the session.
   *
   * The whole scrollback stays: xterm re-renders what it already has when its
   * theme changes, so somebody switching to light mid-session keeps every line
   * of output. Rebuilding the emulator instead would lose the buffer, the
   * focus and the negotiated size, which is a high price for a colour.
   */
  setAppearance(appearance: Appearance): void
  /**
   * Redraw at another character size, without losing the session.
   *
   * The same trade `setAppearance` makes and for the same reason — xterm re-lays
   * out what it already has when its font changes, so somebody who makes the text
   * bigger mid-session keeps every line of scrollback. What they do *not* keep is
   * the column count: a bigger font in the same box is fewer columns, so the
   * caller has to `fit()` afterwards and let the resize reach the machine. That
   * is deliberately not done here, because `fit` measures the element and this
   * handle is created before it is on screen.
   */
  setFontSize(size: number): void
  dispose(): void
}

/**
 * Colours, taken from the desktop's own tokens so the two look like one app.
 *
 * They are restated rather than imported: `styles.css` holds custom properties
 * on a `[data-theme]` element, and xterm wants a colour *object* — which is the
 * whole reason `theme.ts` resolves the appearance in JavaScript rather than
 * leaving it to a media query. Reading the values back out of the cascade would
 * mean this could not build a terminal before the stylesheet had loaded.
 *
 * `background` and `foreground` are the same two values as `--terminal-bg` and
 * `--terminal-fg` in that sheet, written twice because there is no import
 * between a stylesheet and a colour object. `pwa/tests/theme-tokens.test.ts`
 * holds the copies against each other; two colours that must agree and are
 * written twice are two colours that will one day not agree.
 *
 * Dark is declared first, and that order is load bearing:
 * `src/renderer/styles/tokens.test.ts` reads the *first* `selectionBackground`
 * in this file and holds it against the desktop's dark accent.
 */
const DARK_TERMINAL: ITheme = {
  background: '#191919',
  foreground: '#d4d4d4',
  cursor: '#d4d4d4',
  cursorAccent: '#191919',
  /* The accent, at a heavier alpha than the desktop's --accent-soft: a
     selection made by dragging a finger has to be visible while the finger is
     still on top of it. The rgb is the desktop's --accent (the app icon's
     blue); only the alpha differs. The sixteen ANSI slots below are not the
     accent and must not follow it — `blue` is whatever a program means by
     blue, and a shell that prints a blue prompt should not come out brand
     coloured. */
  selectionBackground: 'rgba(59, 143, 238, 0.35)',
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
}

/**
 * The same terminal on paper.
 *
 * This is the half of light mode that gets skipped, and skipping it is the
 * failure the whole feature is judged on: a dark emulator sitting in a white
 * window is worse than no light theme at all, because it looks like a bug rather
 * than like a choice. So the sixteen slots are a real light ramp, not the dark
 * one on a pale ground.
 *
 * Two rules produced these values and both are the inverse of the dark theme's:
 *
 *   1. **Ink is dark.** Every slot a program prints *text* with clears 4.5:1 on
 *      `#e8e8e8`, which on paper means a luminance ceiling rather than a floor.
 *      The dark theme's pastels measure about 1.4:1 there — invisible, which is
 *      exactly what "the same palette, on a light page" gets you.
 *   2. **Bright means more ink, not less.** On charcoal a bright variant is
 *      lighter because that is further from the paper; on paper it is *darker*,
 *      for the same reason. `brightBlack` is the one exception and keeps its job
 *      as the dim grey a TUI draws its borders and comments in — still legible,
 *      deliberately quiet.
 *
 * `white` is a mid grey rather than the near-white convention some light themes
 * keep. Those themes accept that a program printing white text prints nothing at
 * all; this one would rather be readable than traditional.
 */
const LIGHT_TERMINAL: ITheme = {
  background: '#e8e8e8',
  foreground: '#141414',
  cursor: '#141414',
  cursorAccent: '#e8e8e8',
  /* The light theme's accent — the icon's blue walked down its own hue line —
     at an alpha that stays visible under a finger on paper. */
  selectionBackground: 'rgba(26, 102, 196, 0.28)',
  black: '#1c1c1c',
  red: '#a32b1f',
  green: '#14654a',
  yellow: '#7a5300',
  blue: '#1a4f9c',
  magenta: '#7b3aa0',
  cyan: '#0f6165',
  white: '#4d4d4d',
  brightBlack: '#666666',
  brightRed: '#8c2116',
  brightGreen: '#0f4f3a',
  brightYellow: '#614100',
  brightBlue: '#143f7d',
  brightMagenta: '#622d80',
  brightCyan: '#0c4d50',
  brightWhite: '#2b2b2b',
}

/** The emulator's palette for each appearance. */
export const TERMINAL_THEMES: Record<Appearance, ITheme> = {
  dark: DARK_TERMINAL,
  light: LIGHT_TERMINAL,
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, Math.round(value)))
}

export function createTerminal(
  handlers: TerminalHandlers,
  appearance: Appearance = 'dark',
  fontSize: number = STANDARD_TEXT_SIZE,
): TerminalHandle {
  const element = document.createElement('div')
  element.className = 'terminal'

  const term = new Terminal({
    // 13px is the smallest that stays readable on a phone at arm's length, and
    // it fits 80 columns on a 6.1" screen in landscape — the width most CLI
    // output is still written for. It is the default rather than the value now:
    // the same page is opened on a monitor and on a phone, and `text-size.ts`
    // holds what the person answered. Built at the answered size rather than
    // built at 13 and corrected, for the reason the appearance is — a terminal
    // that reflows every line one frame after it appears reads as a fault.
    fontSize: clampTextSize(fontSize),
    lineHeight: 1.2,
    fontFamily: "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
    theme: TERMINAL_THEMES[appearance],
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
    setAppearance(next: Appearance): void {
      term.options.theme = TERMINAL_THEMES[next]
    },
    setFontSize(size: number): void {
      // Clamped here as well as in the store, because this is the other door into
      // the same option and `text-size.ts` says there is to be one place that can
      // be wrong. An unclamped value reaches `fit`, which computes a column count
      // the protocol refuses — and a rejected `resize` closes the socket over a
      // font-size setting, which is the trap this file's header already names.
      term.options.fontSize = clampTextSize(size)
    },
    dispose(): void {
      term.dispose()
      element.remove()
    },
  }
}
