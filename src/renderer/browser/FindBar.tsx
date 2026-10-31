import type { RefObject } from 'react'
import { formatChord } from '../keymap'
import { matchLabel, type FindCount } from './find-bridge'

/**
 * The find bar for a browser page — the terminal's find bar, moved into the
 * flow.
 *
 * Same controls in the same order as `useTerminalFind`'s bar in
 * `TerminalView.tsx` — field, count, ↑ ↓ ✕ — because a person who has learned
 * one find bar in this app has learned both. What cannot be the same is where
 * it sits: the terminal's floats over its own scrollback, but a browser page is
 * a native view composited above this entire renderer, so anything floated here
 * would be painted *behind* the website — `overlay-watch.ts` is the standing
 * essay. So this is a block between the toolbar and the stage, like every band
 * this panel draws: it shrinks the page's rectangle once when it opens rather
 * than covering it.
 *
 * The count is Chromium's own, pushed per view id and routed through
 * `chordTarget` before it can reach these props — this component never counts
 * anything and never chooses a tab, so it cannot be wrong about either on its
 * own. Dumb on purpose: every decision lives in a pure function something
 * DOM-less can test.
 */

interface Props {
  query: string
  /** Chromium's count for this page, or null before the first answer. */
  count: FindCount | null
  inputRef: RefObject<HTMLInputElement | null>
  onQuery(value: string): void
  onStep(back: boolean): void
  onClose(): void
}

export function FindBar({ query, count, inputRef, onQuery, onStep, onClose }: Props) {
  const label = matchLabel(query, count)
  return (
    <div className="bw-find" role="search">
      <input
        ref={inputRef}
        className="bw-find-input"
        type="search"
        value={query}
        placeholder="Find in page"
        aria-label="Find in page"
        onChange={(event) => onQuery(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            event.preventDefault()
            // Not the workspace's Escape — that one leaves draw mode or the
            // inspector, and closing the bar must not take those with it.
            event.stopPropagation()
            onClose()
          } else if (event.key === 'Enter') {
            event.preventDefault()
            onStep(event.shiftKey)
          }
        }}
      />
      {label !== '' && (
        <span className="bw-find-count" role="status" data-none={count?.matches === 0 || undefined}>
          {label}
        </span>
      )}
      <button
        type="button"
        className="bw-find-btn"
        aria-label="Previous match"
        title={`Previous match (${formatChord('shift+enter')})`}
        onClick={() => onStep(true)}
      >
        ↑
      </button>
      <button
        type="button"
        className="bw-find-btn"
        aria-label="Next match"
        title={`Next match (${formatChord('enter')})`}
        onClick={() => onStep(false)}
      >
        ↓
      </button>
      <button
        type="button"
        className="bw-find-btn"
        aria-label="Close find"
        title={`Close (Esc) · reopen with ${formatChord('mod+f')}`}
        onClick={onClose}
      >
        ✕
      </button>
    </div>
  )
}
