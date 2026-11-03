/**
 * One timer for the whole renderer.
 *
 * Almost nothing in this app needs a clock. The main process pushes on
 * `session:data`, `session:exit`, `cost:update`, `git:status-changed`,
 * `remote:connections` and `update:state`, and a panel that subscribes to one of
 * those is both cheaper and fresher than one that asks every few seconds. What
 * is left over after all of that is small, and it is the reason this module
 * exists:
 *
 *   - values that change because *time passed* and for no other reason — a
 *     countdown, an uptime column, "blocked for ten minutes";
 *   - a bounded window where the main process genuinely does not announce
 *     something (see `RemoteSection`'s pairing tick).
 *
 * The rule those obey here is that **N jobs cost one wake-up, not N**. Every
 * `setInterval` in a renderer wakes the event loop on its own schedule and
 * independently keeps the process out of an idle state; four panels each with
 * their own 60-second interval wake the machine four times a minute at four
 * unrelated moments. So jobs register here instead, a single `setTimeout` is
 * armed for the earliest one, and everything due within {@link COALESCE_MS} of
 * that moment runs on the same wake-up.
 *
 * Two further properties fall out of having one owner:
 *
 *   - **Nothing ticks behind a hidden window.** There is no one to see a label
 *     move, so the timer is disarmed entirely on `visibilitychange` and
 *     everything overdue runs at once when the window comes back. A panel does
 *     not have to remember to check `document.visibilityState`.
 *   - **An empty registry has no timer at all.** Not a paused one — none.
 *
 * Everything is guarded for the absence of a DOM: these components are rendered
 * with `renderToStaticMarkup` in their tests, where there is no `document`, no
 * `window`, and no effect ever runs.
 */

import { useEffect, useRef } from 'react'

/**
 * How close two jobs have to be to share a wake-up.
 *
 * The whole point is coalescing, and a job is not made wrong by running a fifth
 * of a second early — everything registered here is a display that a person
 * reads, not a deadline anything depends on.
 */
export const COALESCE_MS = 200

interface Job {
  /** Milliseconds between runs, or 0 for a one-shot. */
  everyMs: number
  dueAt: number
  run: () => void
}

const jobs = new Set<Job>()
let armed: ReturnType<typeof setTimeout> | null = null
let watchingVisibility = false

function hidden(): boolean {
  return typeof document !== 'undefined' && document.visibilityState === 'hidden'
}

function disarm(): void {
  if (armed !== null) {
    clearTimeout(armed)
    armed = null
  }
}

function arm(): void {
  disarm()
  if (jobs.size === 0 || hidden()) return
  let earliest = Number.POSITIVE_INFINITY
  for (const job of jobs) if (job.dueAt < earliest) earliest = job.dueAt
  if (!Number.isFinite(earliest)) return
  armed = setTimeout(fire, Math.max(0, earliest - Date.now()))
}

function fire(): void {
  armed = null
  const at = Date.now()
  // A copy, because a job is allowed to cancel itself or register another one.
  for (const job of [...jobs]) {
    if (!jobs.has(job) || job.dueAt > at + COALESCE_MS) continue
    if (job.everyMs <= 0) jobs.delete(job)
    // From now, not from `dueAt`: a run that was late (a hidden window, a busy
    // main thread) must not leave a job permanently behind, firing repeatedly
    // to catch up on ticks nobody was there to see.
    else job.dueAt = at + job.everyMs
    try {
      job.run()
    } catch (error) {
      console.error('[schedule] a job threw:', error)
    }
  }
  arm()
}

function watchVisibility(): void {
  if (watchingVisibility) return
  if (typeof document === 'undefined' || typeof document.addEventListener !== 'function') return
  watchingVisibility = true
  document.addEventListener('visibilitychange', () => {
    if (hidden()) {
      disarm()
      return
    }
    // Everything that came due behind the user's back runs now, in one pass,
    // rather than each panel waiting out the remainder of its own interval.
    fire()
  })
}

function add(job: Job): () => void {
  watchVisibility()
  jobs.add(job)
  arm()
  return () => {
    if (!jobs.delete(job)) return
    arm()
  }
}

/**
 * Run `run` every `everyMs`, on the shared tick. Returns the cancel function.
 *
 * The first run is one period from now — a caller that wants an immediate read
 * does it itself, because "now" is not something a scheduler should guess.
 */
export function every(everyMs: number, run: () => void): () => void {
  if (!Number.isFinite(everyMs) || everyMs <= 0) return () => {}
  return add({ everyMs, dueAt: Date.now() + everyMs, run })
}

/**
 * Run `run` once, at an absolute moment. Returns the cancel function.
 *
 * This is the shape most of the surviving timers actually want: not "check
 * every second whether the label changed" but "the label changes at 14:32:07,
 * wake up then". A moment already past runs on the next tick rather than being
 * dropped, so a caller does not have to special-case it.
 */
export function at(when: number, run: () => void): () => void {
  if (!Number.isFinite(when)) return () => {}
  return add({ everyMs: 0, dueAt: when, run })
}

/** Jobs currently registered. Exported for the tests, and for nothing else. */
export function pending(): number {
  return jobs.size
}

/* ------------------------------------------------------------------ hooks -- */

/**
 * `every`, bound to a component's lifetime.
 *
 * `everyMs` of `null` registers nothing, which is how a panel says "there is
 * nothing time-dependent on screen right now" without unmounting anything. The
 * callback is read through a ref so that a fresh closure every render does not
 * re-register the job — the classic way a "every 60 seconds" turns into "on
 * every render".
 */
export function useEvery(everyMs: number | null, run: () => void): void {
  const latest = useRef(run)
  latest.current = run
  useEffect(() => {
    if (everyMs === null) return
    return every(everyMs, () => latest.current())
  }, [everyMs])
}

/** `at`, bound to a component's lifetime. `null` registers nothing. */
export function useAt(when: number | null, run: () => void): void {
  const latest = useRef(run)
  latest.current = run
  useEffect(() => {
    if (when === null) return
    return at(when, () => latest.current())
  }, [when])
}

/* ----------------------------------------------------------------- events -- */

/**
 * Run `run` when the user comes back to this window.
 *
 * The event a great many "refresh every N minutes" timers are really reaching
 * for. Data that changes on someone else's machine — a pull request, a CI run,
 * a tailnet that went away while the laptop was in a bag — has no local signal
 * to subscribe to, but it only *matters* at the moment the user looks at it
 * again, and that moment is an event this platform already reports.
 *
 * Both `focus` and `visibilitychange` are listened for because they are
 * different returns: focus is switching back from another app, visibility is
 * the window being restored or its tab being shown. Either alone leaves a real
 * path in which the panel stays stale.
 */
export function useWhenActive(run: () => void): void {
  const latest = useRef(run)
  latest.current = run
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.addEventListener !== 'function') return
    const wake = (): void => {
      if (hidden()) return
      latest.current()
    }
    window.addEventListener('focus', wake)
    document.addEventListener('visibilitychange', wake)
    return () => {
      window.removeEventListener('focus', wake)
      document.removeEventListener('visibilitychange', wake)
    }
  }, [])
}
