/**
 * What a page already read, kept for the next time it is opened.
 *
 * ## Why a page needs this at all
 *
 * The shell shows one view at a time: `PanelView` is mounted when a view has
 * the window and unmounted when a session does. That is the right shape — two
 * pages fighting over one pane is the defect this whole pass is about — but it
 * means every trip through a session throws away everything the page had read.
 * Artifacts felt it worst: leaving the page and coming back re-walked every
 * transcript in the project from scratch, which on a real project is seconds of
 * work to arrive at bytes that had not changed. Asad watched it do that
 * repeatedly and described the app as thrashing, which is exactly what it was.
 *
 * ## What it is not
 *
 * It is not a data layer and it is not a subscription. Nothing here invalidates
 * itself, nothing polls, and nothing is pushed into it from the main process.
 * It answers one question — *did we already read this, and how long ago* — and
 * the page decides what to do with the answer. The two useful answers are:
 *
 *   - **fresh**: paint it and do not ask again. This is what stops the page
 *     re-scanning on a switch away and back.
 *   - **stale**: paint it anyway, and ask again *without* a spinner. The reader
 *     sees the page they left instead of a loading sentence, and it updates
 *     under them when the answer lands.
 *
 * Both are better than what was there, and neither can show something that was
 * never read: an entry only exists because a real reply produced it.
 *
 * Keys are the caller's business and are namespaced by hand — `artifacts:list:`,
 * `files:tree:` — so a page can drop everything it owns with one prefix.
 */

interface Entry {
  value: unknown
  /** `Date.now()` when the value was written. */
  at: number
}

/**
 * How many reads are remembered at once.
 *
 * A cap rather than a byte budget, because the values here are lists a page
 * already had in memory a moment ago and the expensive thing about them was
 * producing them, not holding them. Sixty-four is more folders and files than
 * anyone visits in a sitting; past it the oldest write is dropped, which is the
 * one least likely to be wanted next.
 */
export const MAX_ENTRIES = 64

const store = new Map<string, Entry>()

/** A clock, so the freshness window can be driven deterministically in tests. */
let clock: () => number = Date.now

/** Test seam. Pass nothing to go back to the real clock. */
export function setCacheClock(next?: () => number): void {
  clock = next ?? Date.now
}

export function remember<T>(key: string, value: T): void {
  // Delete first so a re-write moves the key to the back of the insertion
  // order — otherwise the eviction below would throw away the entry that is
  // being used most rather than the one that is being used least.
  store.delete(key)
  store.set(key, { value, at: clock() })
  while (store.size > MAX_ENTRIES) {
    const oldest = store.keys().next()
    if (oldest.done) break
    store.delete(oldest.value)
  }
}

export interface Recalled<T> {
  value: T
  /** Written within the caller's freshness window, so no re-read is needed. */
  fresh: boolean
  /** How long ago it was written, in milliseconds. */
  ageMs: number
}

/**
 * What was read for this key, if anything.
 *
 * `freshForMs` is the caller's judgement about its own data and is deliberately
 * not defaulted to something generous: a file tree goes out of date the moment
 * an agent writes a file, while a scan of finished transcripts does not. A
 * caller that passes nothing gets `fresh: false` — the value to paint, and an
 * instruction to check.
 */
export function recall<T>(key: string, freshForMs = 0): Recalled<T> | null {
  const entry = store.get(key)
  if (!entry) return null
  const ageMs = Math.max(0, clock() - entry.at)
  // `freshForMs > 0` matters on its own: an entry written this millisecond has
  // an age of zero, so a bare `ageMs <= freshForMs` would call it fresh for a
  // caller that asked for no window at all and skip the re-read it wanted.
  return { value: entry.value as T, fresh: freshForMs > 0 && ageMs <= freshForMs, ageMs }
}

/** Drop one key, or every key under a prefix. */
export function forget(prefix: string): void {
  if (store.delete(prefix)) return
  for (const key of [...store.keys()]) {
    if (key.startsWith(prefix)) store.delete(key)
  }
}

/** Everything. For tests, and for a project being closed out from under us. */
export function forgetAll(): void {
  store.clear()
}

/** How many entries are held. Tests read this; nothing on screen does. */
export function cacheSize(): number {
  return store.size
}
