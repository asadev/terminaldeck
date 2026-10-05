/**
 * When the engine tells the pages about the sessions: once, for the first page.
 *
 * A window's `did-finish-load` restores the last run's sessions and then
 * re-announces every live one on `session:created`. The native shell has many
 * pages — the main window, its screens and windows, the island — and each opens
 * its own event stream. Re-announcing on every stream sent every session to
 * every page again, and a page counts `session:created` as new output, so each
 * new stream put an unread dot on every session (found by lane R, 2026-10-05).
 *
 * So the restore runs for the first stream only, and nothing is re-announced:
 * every page asks for the live list itself when it mounts (`session:list` in
 * `App.tsx`), which is the path that marks nothing unread. A session that is
 * genuinely new still arrives on `session:created`, from the code that starts
 * it, exactly as before.
 */
export function hydrateOnce(hydrate: () => void): () => void {
  let done = false
  return () => {
    if (done) return
    done = true
    hydrate()
  }
}
