/**
 * A deadline on anything the renderer waits for.
 *
 * ## Why this exists
 *
 * Every page in this window that reads something asks the main process for it
 * and paints a sentence — "Reading repository…", "Reading your MCP
 * configuration…", "Reading the changes…" — until the answer lands. Each of
 * those sentences was written on the assumption that an answer always lands,
 * and that assumption is not true of an `ipcRenderer.invoke`. A handler that
 * awaits a child process which never exits, a scan that is cancelled by another
 * request and answers with a shape the caller does not handle, a channel that
 * was never registered in this build — in all three the promise simply never
 * settles, and the page sits on its sentence for the rest of the session with
 * no error, no retry and nothing in the console.
 *
 * Asad recorded four of them stuck for minutes at a time. So the rule this
 * module exists to enforce is: **a spinner that can hang forever is a bug**.
 * Every read gets a deadline, and when the deadline passes the page says what
 * happened and offers the read again. "It timed out" is a worse answer than
 * the data and a far better one than a sentence that never changes.
 *
 * ## Why not `schedule.ts`
 *
 * That module deliberately disarms its single timer while the window is hidden,
 * because everything registered there is a label a person reads and there is
 * nobody reading it. A deadline is the opposite kind of thing: it is the last
 * line of defence against a read that will never come back, and one that only
 * fires while somebody is watching would leave a page that was backgrounded
 * mid-load stuck exactly the way this module exists to prevent. So this is a
 * plain `setTimeout`, one per read, cleared the moment the read settles.
 */

/**
 * The default a read is given before it is declared lost.
 *
 * Fifteen seconds rather than five. The slowest honest read in this app is the
 * artifact scan, which walks every transcript in a project under its own eight
 * second budget in the main process (`DEFAULT_TIME_BUDGET_MS`), and a deadline
 * that fired before that budget did would turn a working scan into a timeout
 * on any large project. Fifteen leaves room for the budget plus the file
 * system it is reading, and is still short enough that nobody sits looking at
 * a dead page wondering.
 */
export const DEFAULT_DEADLINE_MS = 15_000

/**
 * A read that never answered.
 *
 * A named class rather than a plain `Error` so a caller can tell "the main
 * process said no" from "the main process said nothing", and word the two
 * differently — the first has a reason worth printing and the second has only
 * the fact.
 */
export class Overdue extends Error {
  /** The deadline that passed, in milliseconds. */
  readonly afterMs: number

  constructor(what: string, afterMs: number) {
    super(`${what} did not answer within ${describeMs(afterMs)}.`)
    this.name = 'Overdue'
    this.afterMs = afterMs
  }
}

export function isOverdue(error: unknown): error is Overdue {
  return error instanceof Overdue
}

/** "15 seconds", "1.5 seconds", "800 ms" — whichever reads as a duration. */
export function describeMs(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`
  const seconds = ms / 1000
  const rounded = Number.isInteger(seconds) ? String(seconds) : seconds.toFixed(1)
  return `${rounded} second${rounded === '1' ? '' : 's'}`
}

/**
 * The same promise, except that it is guaranteed to settle.
 *
 * `what` is a noun phrase naming the read from the reader's point of view —
 * "Reading this project’s history", "The MCP configuration" — because it is
 * printed on screen verbatim when the deadline passes. It is not a channel
 * name: the person looking at the page did not ask for `artifacts:list`.
 *
 * The original promise is not cancelled, because a promise cannot be. What
 * happens to a late answer is the caller's business and every caller here
 * already has a generation guard for exactly that reason — a slow reply for the
 * previous project must not paint over the current one whether or not a
 * deadline was involved.
 */
export function withDeadline<T>(
  work: Promise<T>,
  what: string,
  ms: number = DEFAULT_DEADLINE_MS,
): Promise<T> {
  // A non-positive deadline means "no deadline". Tests and callers that
  // genuinely want to wait forever say so by passing 0 rather than by reaching
  // around this function, so there is one place the decision is visible.
  if (!(ms > 0)) return work

  return new Promise<T>((resolve, reject) => {
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      reject(new Overdue(what, ms))
    }, ms)

    work.then(
      (value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(value)
      },
      (error: unknown) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        reject(error)
      },
    )
  })
}

/**
 * The sentence to print for a failed read.
 *
 * Electron wraps every IPC rejection with `Error invoking remote method 'x':`,
 * which names a channel at a person who asked for a page. Four components had
 * their own copy of this replace; it is one function now because the prefix is
 * one fact about one framework.
 */
export function readFailure(error: unknown): string {
  if (isOverdue(error)) return error.message
  const raw = error instanceof Error ? error.message : String(error)
  return raw.replace(/^Error invoking remote method '[^']*':\s*/, '')
}
