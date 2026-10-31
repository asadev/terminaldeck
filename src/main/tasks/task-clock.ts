/**
 * The task clock: one timer, set for the next moment something on your tasks
 * comes due — a routine "On a schedule", a reminder, a scheduled comment — and
 * nothing at all when nothing will.
 *
 * Not a poll. The timer is aimed at the soonest due moment the tasks
 * themselves name ({@link TaskClockDeps.nextDueAt}), and aimed again after
 * every run and every change ({@link TaskClock.poke}). Two things it cannot
 * see are handed to it by the app: a Mac waking from sleep (`setTimeout` does
 * not count the time a Mac is suspended, so a reminder due during the night
 * would come hours late) — the app's `powerMonitor` resume calls
 * {@link TaskClock.wake}; and a moment more than {@link MAX_WAIT_MS} away, which
 * is waited for in steps, because a timer that long is past what Node keeps
 * and the wall clock may be changed meanwhile.
 */

import { REAL_CLOCK, type HubClock } from '../deck-control/notify-hub'

/** The longest one wait; a moment further away is reached in steps of this. */
export const MAX_WAIT_MS = 60 * 60_000

export interface TaskClockDeps {
  /** The next due moment (ms since the epoch); null when nothing will come due. */
  nextDueAt(): number | null
  /** Do what has come due. */
  runDue(): Promise<void>
  clock?: HubClock
}

export class TaskClock {
  private readonly clock: HubClock
  private handle: unknown = null
  /** A run on its way: a poke waits for it, which aims again when it ends. */
  private running = false
  private stopped = true

  constructor(private readonly deps: TaskClockDeps) {
    this.clock = deps.clock ?? REAL_CLOCK
  }

  start(): void {
    this.stopped = false
    void this.fire()
  }

  stop(): void {
    this.stopped = true
    this.clear()
  }

  /** Something changed — a reminder set, a routine saved: aim again. */
  poke(): void {
    if (this.stopped) return
    if (!this.running) this.aim()
  }

  /** The Mac woke: what came due while it slept is done now. */
  wake(): void {
    if (this.stopped) return
    void this.fire()
  }

  private clear(): void {
    if (this.handle !== null) this.clock.clearTimeout(this.handle)
    this.handle = null
  }

  private aim(): void {
    this.clear()
    if (this.stopped) return
    let next: number | null
    try {
      next = this.deps.nextDueAt()
    } catch (error) {
      console.error('[tasks] the task clock could not read what is due:', error)
      return
    }
    if (next === null) return
    const wait = Math.min(Math.max(0, next - this.clock.now()), MAX_WAIT_MS)
    this.handle = this.clock.setTimeout(() => {
      this.handle = null
      void this.fire()
    }, wait)
  }

  private async fire(): Promise<void> {
    if (this.stopped || this.running) return
    this.running = true
    this.clear()
    try {
      const next = this.deps.nextDueAt()
      if (next !== null && next <= this.clock.now()) await this.deps.runDue()
    } catch (error) {
      console.error('[tasks] the task clock run failed:', error)
    } finally {
      this.running = false
      this.aim()
    }
  }
}
