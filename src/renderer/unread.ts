/**
 * Which background sessions have produced output the user has not seen.
 *
 * The badge this drives answers one question: "is there anything new on a tab
 * I am not looking at?". So the interesting decisions are what counts as
 * output worth flagging, and what counts as having seen it.
 *
 * Pure except for the subscriber list — no DOM, no timers, no globals — so the
 * rules can be exercised directly.
 *
 * ## The rules
 *
 * 1. A session is *watched* when it is the active tab AND the window has
 *    focus. Anything else — a background tab, or any tab while the app is
 *    behind another window — is unwatched, because the user is not reading it.
 * 2. Output on an unwatched session marks it unread. Output on a watched one
 *    does not: they are watching it happen.
 * 3. Watching a session clears it. That is both the tab click and the window
 *    regaining focus, since either one puts the session in front of the user.
 * 4. Repaint noise does not count as output. See `isMeaningfulOutput`.
 */

import { stripAnsi } from './session-title'

/**
 * Chunks made only of whitespace, control bytes and braille spinner frames.
 *
 * Agent CLIs redraw their spinner several times a second, and every frame
 * arrives as a PTY chunk. Counting those as "new output" would leave a badge
 * on every running session permanently, which is the same as having no badge:
 * the signal only means something if a working tab can be quiet.
 *
 * U+2800–U+28FF is the whole braille block, which is where every CLI in this
 * app draws its spinner from — verified against the fixtures in
 * `session-activity.test.ts`.
 *
 * C0 and DEL are in here because a control byte is by definition not something
 * a human reads: a bare BEL (tab completion failing, an error beep) and a run
 * of backspaces (a TUI moving its cursor) are not news, and both used to badge
 * the tab on their own.
 */
const NOISE_ONLY = /^[\s\u0000-\u001f\u007f\u2800-\u28ff]*$/

/**
 * An escape sequence the chunk boundary cut in half.
 *
 * A PTY read ends wherever the kernel buffer did, so `\x1b[2K\r⠸ ` — one
 * spinner repaint — arrives perfectly often as `\x1b[2` followed by `K\r⠸ `.
 * The first half survives `stripAnsi`, which only removes *complete*
 * sequences, and `[` and `2` are ordinary printable characters, so the chunk
 * reads as text and lights the badge. Dropping a dangling escape at the very
 * end of a chunk closes that half of the split.
 *
 * The other half cannot be closed here: `K\r⠸ ` is indistinguishable from
 * someone's output that genuinely starts with a capital K, and guessing would
 * silence real text. Judging a chunk in isolation is the price of keeping this
 * pure; the cost of the residue is one spurious badge, not a wrong badge.
 */
const INCOMPLETE_ESCAPE_TAIL = /\x1b(?:\[[0-9;?]*[ -/]*|\][^\x07\x1b]*|[()#][0-9A-Za-z]?|[@-Z\\-_]?)?$/

/**
 * Does this chunk contain anything the user would want to look at?
 *
 * The dangling tail goes first, *before* `stripAnsi`: an unterminated OSC like
 * `\x1b]0;claude` — a window-title update split across the boundary — is
 * otherwise matched by that stripper's catch-all two-byte-escape rule, which
 * removes only the `\x1b]` and leaves `0;claude` behind looking like text.
 * Complete sequences are unaffected by the reordering, since none of them ends
 * where this pattern requires.
 */
export function isMeaningfulOutput(chunk: string): boolean {
  return !NOISE_ONLY.test(stripAnsi(chunk.replace(INCOMPLETE_ESCAPE_TAIL, '')))
}

export interface UnreadSnapshot {
  /** Unread session ids, in the order they were first marked. */
  ids: readonly string[]
  count: number
}

export interface ViewingState {
  activeSessionId: string | null
  windowFocused: boolean
}

export type UnreadListener = (snapshot: UnreadSnapshot) => void

export interface UnreadOptions {
  now?(): number
  viewing?: ViewingState
}

/**
 * Tracks unread output per session.
 *
 * A `Set` rather than a flag per session so the common queries — "does this
 * project have anything unread?", "how many tabs are lit?" — are one pass over
 * the marked ids rather than over every session that ever existed. Insertion
 * order is preserved, which is why `ids()` can promise it.
 */
export class UnreadTracker {
  private readonly unread = new Set<string>()
  private readonly markedAtMs = new Map<string, number>()
  private readonly listeners = new Set<UnreadListener>()
  private readonly now: () => number
  private viewing: ViewingState

  constructor(options: UnreadOptions = {}) {
    this.now = options.now ?? (() => Date.now())
    this.viewing = options.viewing ?? { activeSessionId: null, windowFocused: true }
  }

  /**
   * Record output from a session. Returns true if this marked it unread.
   *
   * The chunk is optional: callers that already know output arrived but do not
   * have the bytes to hand — a status change, a transcript write — can pass
   * nothing and skip the noise filter.
   */
  recordOutput(sessionId: string, chunk?: string): boolean {
    if (chunk !== undefined && !isMeaningfulOutput(chunk)) return false
    if (this.isWatched(sessionId)) return false
    if (this.unread.has(sessionId)) return false

    this.unread.add(sessionId)
    this.markedAtMs.set(sessionId, this.now())
    this.emit()
    return true
  }

  /**
   * Update what the user is looking at, clearing whatever that now reveals.
   *
   * Both halves matter: switching tabs clears the newly active session, and
   * alt-tabbing back to the app clears the one already in front. A window that
   * loses focus clears nothing — the user walked away, they did not read it.
   */
  setViewing(viewing: ViewingState): void {
    this.viewing = viewing
    const watched = this.watchedId()
    if (watched) this.markRead(watched)
  }

  /** Clear one session explicitly. Returns true if it had been unread. */
  markRead(sessionId: string): boolean {
    if (!this.unread.delete(sessionId)) return false
    this.markedAtMs.delete(sessionId)
    this.emit()
    return true
  }

  /** Forget a session entirely — it closed. */
  forget(sessionId: string): void {
    this.markRead(sessionId)
  }

  isUnread(sessionId: string): boolean {
    return this.unread.has(sessionId)
  }

  /** When a session was marked, or null if it is not unread. */
  markedAt(sessionId: string): number | null {
    return this.markedAtMs.get(sessionId) ?? null
  }

  ids(): string[] {
    return [...this.unread]
  }

  count(): number {
    return this.unread.size
  }

  /** Rollup for a project: does any of its sessions have unread output? */
  hasAnyOf(sessionIds: Iterable<string>): boolean {
    for (const id of sessionIds) if (this.unread.has(id)) return true
    return false
  }

  snapshot(): UnreadSnapshot {
    return { ids: this.ids(), count: this.unread.size }
  }

  /** Returns an unsubscribe function, matching the `window.pawl.on*` convention. */
  subscribe(listener: UnreadListener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  private isWatched(sessionId: string): boolean {
    return this.watchedId() === sessionId
  }

  private watchedId(): string | null {
    return this.viewing.windowFocused ? this.viewing.activeSessionId : null
  }

  /**
   * Only called from the mutating paths, and only after a real change — a
   * subscriber that re-renders the tab bar must not be woken by every chunk of
   * output on an already-unread session.
   */
  private emit(): void {
    const snapshot = this.snapshot()
    // Copy first: a listener is free to unsubscribe itself while being called.
    for (const listener of [...this.listeners]) listener(snapshot)
  }
}
