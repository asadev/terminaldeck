/**
 * Naming a session from what its agent is actually doing.
 *
 * `session-title.ts` has been able to read a title out of terminal output since
 * it was written — `titleFromOutput`, `deriveSessionTitle` — and nothing ever
 * called it with any. Sessions were named once, at creation, from the folder
 * and the first prompt, so three sessions on one repo read `terminaldeck`,
 * `terminaldeck 2`, `terminaldeck 3` for their whole lives while Settings
 * offered "Auto-name sessions from conversation title" and changed nothing.
 *
 * This is the missing half: the output every session is already broadcasting,
 * kept in a small window per session, handed to the existing deriver.
 *
 * Two things keep it cheap. The buffer is the *tail* only — a title is drawn in
 * the last frame the TUI painted, and the echoed first prompt is found by
 * `titleFromOutput` scanning the head of what it is given, so a window of a few
 * kilobytes holds both without holding a session's whole scrollback. And a
 * rescan is rate-limited: agent output arrives in hundreds of chunks a second
 * and the answer cannot change that fast.
 */

import { deriveSessionTitle } from './session-title'

/** How much of each session's output is kept. Two screens of a wide terminal. */
export const TITLE_WINDOW_BYTES = 8192

/** Shortest gap between two scans of one session. */
export const TITLE_RESCAN_MS = 250

interface Record_ {
  text: string
  scannedAt: number
}

export class AutoTitler {
  private readonly sessions = new Map<string, Record_>()

  constructor(private readonly now: () => number = Date.now) {}

  /** Feed a chunk of PTY output. */
  record(sessionId: string, chunk: string): void {
    const entry = this.sessions.get(sessionId) ?? { text: '', scannedAt: 0 }
    const text = entry.text + chunk
    entry.text = text.length > TITLE_WINDOW_BYTES ? text.slice(-TITLE_WINDOW_BYTES) : text
    this.sessions.set(sessionId, entry)
  }

  /**
   * The best title this session's output supports, or null.
   *
   * Null covers all three ways there is nothing to do: no output yet, nothing
   * in it that reads as a title, and "asked again too soon". The caller renames
   * on a non-null answer and does nothing otherwise, so a rate-limited scan and
   * a scan that found nothing are the same thing to it.
   */
  titleFor(sessionId: string, cwd: string): string | null {
    const entry = this.sessions.get(sessionId)
    if (!entry || entry.text === '') return null

    const at = this.now()
    if (at - entry.scannedAt < TITLE_RESCAN_MS) return null
    entry.scannedAt = at

    const derived = deriveSessionTitle({ cwd, output: entry.text })
    // 'folder' means the deriver fell through to the folder name, which is
    // what the session is already called — renaming to it is a no-op that
    // would still cost a render.
    return derived.source === 'folder' ? null : derived.title
  }

  forget(sessionId: string): void {
    this.sessions.delete(sessionId)
  }
}
