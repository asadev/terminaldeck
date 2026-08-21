import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * The one line a terminal pane may draw over itself, and the timer that takes it
 * away again.
 *
 * ## Why any line at all
 *
 * Because a silent failure is the worst outcome. A paste that is refused, a
 * clipboard this window cannot reach, a file that did not send — every one of
 * those used to be nothing happening, which is indistinguishable from the
 * feature not existing.
 *
 * It is **one line and never a paragraph**. His standing rule this round is that
 * there is no explanatory prose on screen, and in particular nothing here ever
 * explains *why* a path differs from the one somebody was looking at: a file
 * that had to cross to another machine to reach a session is meant to be
 * invisible, and a sentence about it would be the app narrating its own
 * plumbing. A percentage while a large file crosses is not prose — it is the one
 * fact a person cannot see for themselves — and it is what `transferLine` in
 * `terminal-drop.ts` produces.
 *
 * Nothing is ever *typed*. The note is drawn over the pane, so a session's
 * transcript still contains only what the person and the agent put in it.
 *
 * ## Why it lives here rather than in one of the two panes
 *
 * It was written inside `RemoteTerminal`, because remote was where a transfer
 * could fail. Then a paste of an image into a **local** session grew a way to
 * fail too — the bytes have to become a file on this disk first — and a pane
 * that could refuse silently while the pane beside it said so would be the app
 * changing shape between local and remote, which is the rule this whole area has
 * already been rewritten for once: *"the shape of the application should not be
 * changing for local and remote devices. It should act like that same."*
 */

/** How long a line that is not progress stays up. */
const NOTE_MS = 4000

export interface TransferNoteState {
  /** What to draw, or '' for nothing. */
  line: string
  /**
   * Say one line.
   *
   * `sticky` holds it until something replaces it, which is what progress wants:
   * a percentage that expired mid-transfer would be a bar that vanishes while
   * the file is still crossing. A refusal is read once and expires, because it
   * should not sit on somebody's terminal for the rest of the session.
   */
  say(line: string, sticky?: boolean): void
}

export function useTransferNote(): TransferNoteState {
  const [line, setLine] = useState('')
  const timer = useRef<number | null>(null)
  const say = useCallback((next: string, sticky = false) => {
    setLine(next)
    if (timer.current !== null) window.clearTimeout(timer.current)
    timer.current =
      next === '' || sticky ? null : window.setTimeout(() => setLine(''), NOTE_MS)
  }, [])
  useEffect(
    () => () => {
      if (timer.current !== null) window.clearTimeout(timer.current)
    },
    [],
  )
  return { line, say }
}

/**
 * One line over the bottom of the terminal, or nothing.
 *
 * Inline styles rather than a class in a stylesheet, because the sheets belong
 * to another lane this pass. It reads its colours from the app's own tokens, so
 * it follows the theme like everything else, and it is `pointer-events: none` so
 * a line that is still fading cannot swallow a click meant for the session
 * underneath it.
 *
 * `aria-live` because this is the only announcement of a refusal: somebody using
 * a screen reader pressed ⌘V and has even less to go on than somebody watching
 * the pane.
 */
export function TransferNote({ line }: { line: string }) {
  if (line === '') return null
  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        position: 'absolute',
        left: 8,
        right: 8,
        bottom: 8,
        padding: '4px 8px',
        borderRadius: 6,
        /*
         * Two of these named tokens that do not exist — `--chrome-solid` and
         * `--text` — so both fell to their fallbacks every time, and the
         * fallbacks are a dark chip with light ink. The note therefore drew
         * itself inverted in the light theme, permanently, and nobody read it
         * as a bug because an inverted toast is a thing toasts do. The names it
         * wanted are `--bg-tertiary` (a solid chrome surface, which is what
         * "chrome-solid" was reaching for) and `--text-primary`. The fallbacks
         * are gone with them: a fallback behind a real token is dead, and a
         * fallback behind a phantom is the whole design in disguise.
         */
        background: 'var(--bg-tertiary)',
        color: 'var(--text-primary)',
        border: '1px solid var(--border, rgba(255,255,255,0.12))',
        font: '12px/1.4 var(--font-ui, system-ui, sans-serif)',
        whiteSpace: 'nowrap',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        pointerEvents: 'none',
      }}
    >
      {line}
    </div>
  )
}
