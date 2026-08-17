/**
 * The one place that knows a tour is running.
 *
 * Three jobs, and they are together because they are the same fact seen from
 * three sides:
 *
 *  1. **Hand a validated plan to the window and wait to hear that it took it.**
 *  2. **Answer "is the copilot driving right now"**, which `control.ts` asks
 *     before every tool call that would change something.
 *  3. **Keep the record**, in `<userData>/copilot-log/tours/`, updated after
 *     every stop.
 *
 * ## Why the tool waits for the window
 *
 * The obvious shape is fire-and-forget: broadcast the plan, return "playing".
 * It is wrong in a way that only shows up when something is already broken. If
 * no window is listening — the app is starting, the renderer crashed, somebody
 * is on a different build — a fire-and-forget `tour.play` reports success for a
 * tour nobody saw, and, worse, the driving gate in `control.ts` would latch on
 * with nothing to unlatch it. Every later `sessions.send` would be refused for
 * being "while driving" with no tour anywhere.
 *
 * So the plan is *offered*, and driving begins when the window says it began.
 * The shape is `consent.ts`'s, deliberately: a request out, an answer back, a
 * timeout, and a refusal that names which of those happened. This is the second
 * thing in this folder that needs a window to answer, and it should not invent a
 * second way to need one.
 *
 * ## A tour never survives a renderer reload
 *
 * `DRIVING-MODE.md` §8 states it and gives the reason: *"a tour that resumed
 * itself after a crash is a screen that starts moving on its own, which is the
 * single behaviour that would make somebody uninstall this."* The renderer half
 * gets that for free — its playhead is component state and a reload destroys it.
 * This side does not, so it watches the window: a navigation or a destroyed
 * `WebContents` ends the tour here, writes what there is, and lifts the gate.
 * Without that, a reload mid-tour would leave the main process believing a tour
 * is playing forever, and the copilot permanently unable to act.
 */

import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { TourRecord, ValidatedTour } from './tour'
import { openRecord } from './tour'

/* -------------------------------------------------------------- constants -- */

/**
 * How long the window has to acknowledge a plan before the tool gives up.
 *
 * Generous by the standards of a round trip inside one process, and it is not
 * measuring the round trip. It is measuring the window *becoming able to play*:
 * the driving panel mounts, the sidebar's own contents come off, and the first
 * stop's anchor is resolved before anything is drawn. Four seconds is longer
 * than any of that and short enough that a copilot waiting on it has not
 * obviously hung.
 */
export const ACK_TIMEOUT_MS = 4_000

/**
 * How many tours are kept.
 *
 * Fifty, rolled oldest-first, the same policy `actions.jsonl` uses. A tour
 * record is small — a dozen quotes — and fifty of them is a month of mornings.
 */
export const MAX_TOURS_KEPT = 50

/* ------------------------------------------------------------------ types -- */

/** The window, as much of it as this needs. Narrow so a test can be four lines. */
export interface TourWindow {
  /** Push the plan. False when there is nobody to push to. */
  send(record: TourRecord, plan: ValidatedTour): boolean
  /**
   * Tell this stage when the window goes away or reloads.
   *
   * Returns the teardown. A watch that outlives its tour would end the *next*
   * tour when the previous window finally closed.
   */
  watch(onGone: () => void): () => void
}

export interface TourStageOptions {
  /** `<userData>/copilot-log` — beside `actions.jsonl`, outside the copilot's folder. */
  dir: string
  window: TourWindow
  now?(): number
  ackTimeoutMs?: number
}

export type PlayOutcome =
  | { ok: true; record: TourRecord }
  /** There is no window to play it in. */
  | { ok: false; why: 'no-window' }
  /** A window was told and never answered. */
  | { ok: false; why: 'no-answer' }
  /** A tour is already playing. Two tours on one screen is not a state. */
  | { ok: false; why: 'already-driving' }

/* ------------------------------------------------------------------ stage -- */

export class TourStage {
  private readonly dir: string
  private readonly now: () => number
  private readonly ackTimeout: number
  private live: {
    record: TourRecord
    /** Resolved by the window's acknowledgement, or by the timeout. */
    settle: ((ok: boolean) => void) | null
    unwatch: () => void
    timer: ReturnType<typeof setTimeout> | null
  } | null = null

  constructor(private readonly options: TourStageOptions) {
    this.dir = join(options.dir, 'tours')
    this.now = options.now ?? Date.now
    this.ackTimeout = options.ackTimeoutMs ?? ACK_TIMEOUT_MS
  }

  /**
   * Is the copilot driving the screen right now?
   *
   * The whole of what `control.ts` needs. True from the moment the window
   * acknowledges to the moment it says the tour ended — never from the moment
   * the plan was sent, because a plan nobody took must not be able to lock the
   * copilot out of acting.
   */
  driving(): boolean {
    return this.live !== null && this.live.settle === null
  }

  /** The tour on screen, for a status channel. Null when nothing is playing. */
  current(): TourRecord | null {
    return this.driving() ? (this.live?.record ?? null) : null
  }

  /**
   * Offer a validated plan to the window and wait to hear that it took it.
   *
   * The record is written **before** the offer rather than after the answer, and
   * the ordering is the same one `settings.write`'s snapshot makes: the account
   * of what was about to be shown has to exist before it is shown, or the one
   * case with no record is the one where something went wrong halfway.
   */
  async play(validated: ValidatedTour): Promise<PlayOutcome> {
    if (this.live !== null) return { ok: false, why: 'already-driving' }

    const record = openRecord(validated, this.now())
    this.write(record)

    if (!this.options.window.send(record, validated)) {
      // Nothing to play it in. The record stays on disk with `endedAt` set and
      // no stops shown, which is an honest artefact: the tour was written, was
      // checked, and had nowhere to go.
      this.write({ ...record, endedAt: this.now(), stoppedAfter: null })
      return { ok: false, why: 'no-window' }
    }

    return await new Promise<PlayOutcome>((resolve) => {
      const unwatch = this.options.window.watch(() => this.windowGone())
      const timer = setTimeout(() => {
        // Told, and silent. Distinguished from `no-window` because the fix is
        // different: this one is a window that is there and did not play, which
        // is worth saying rather than collapsing into "no window".
        this.finish(null)
        resolve({ ok: false, why: 'no-answer' })
      }, this.ackTimeout)
      // `unref` where the host supports it, so a pending acknowledgement cannot
      // hold the process open at quit. Node has it; a test's fake clock may not.
      timer.unref?.()

      this.live = {
        record,
        settle: (ok: boolean) => {
          clearTimeout(timer)
          if (this.live !== null) this.live.settle = null
          resolve(ok ? { ok: true, record } : { ok: false, why: 'no-answer' })
        },
        unwatch,
        timer,
      }
    })
  }

  /**
   * The window has the plan and the first stop is on screen.
   *
   * This is the moment driving becomes true, and therefore the moment the gate
   * in `control.ts` closes. Anything before it is a plan in flight.
   */
  acknowledge(tourId: string): boolean {
    const live = this.live
    if (live === null || live.record.id !== tourId || live.settle === null) return false
    live.settle(true)
    return true
  }

  /**
   * The record as the window has it now — after every stop, per
   * `DRIVING-MODE.md` §8, so an interrupted tour still leaves a readable recap.
   *
   * The window is trusted for the *progress* fields and for nothing else. The
   * quotes, the notes, the reasons and the drops all come from this side's own
   * validated plan and are written over whatever arrived, because the window has
   * no business changing what was checked — and a renderer bug that shuffled
   * them would put unchecked text in the audit record.
   */
  progress(tourId: string, update: Partial<TourRecord>): TourRecord | null {
    const live = this.live
    if (live === null || live.record.id !== tourId) return null
    const merged = mergeProgress(live.record, update)
    live.record = merged
    this.write(merged)
    return merged
  }

  /** The tour is over, however it ended. Lifts the gate and closes the record. */
  end(tourId: string, update: Partial<TourRecord> = {}): TourRecord | null {
    const live = this.live
    if (live === null || live.record.id !== tourId) return null
    const merged = mergeProgress(live.record, update)
    return this.finish(merged)
  }

  /** Every tour on disk, newest first. What the recap card and Settings read. */
  list(limit = MAX_TOURS_KEPT): TourRecord[] {
    let names: string[]
    try {
      names = readdirSync(this.dir).filter((name) => name.endsWith('.json'))
    } catch {
      return []
    }
    const found: TourRecord[] = []
    for (const name of names) {
      try {
        const parsed = JSON.parse(readFileSync(join(this.dir, name), 'utf8')) as TourRecord
        if (parsed && parsed.v === 1 && typeof parsed.id === 'string') found.push(parsed)
      } catch {
        // A half-written or hand-edited file is skipped rather than thrown over.
        // One unreadable record must not make the other forty-nine unreachable.
      }
    }
    return found.sort((a, b) => b.startedAt - a.startedAt).slice(0, Math.max(1, limit))
  }

  /** Forget one tour. The Settings pane's delete. */
  forget(tourId: string): boolean {
    if (!/^tour_[0-9]+_[0-9a-f]+$/.test(tourId)) return false
    try {
      rmSync(join(this.dir, `${tourId}.json`), { force: true })
      return true
    } catch {
      return false
    }
  }

  /** Stop whatever is playing. Called at shutdown, and when the window goes. */
  stop(): void {
    if (this.live === null) return
    this.finish(this.live.record)
  }

  /* ------------------------------------------------------------- internals -- */

  private windowGone(): void {
    /*
     * A reload, a crash, a closed window. The record is closed where it stands
     * and the gate lifts. Deliberately no attempt to resume: see the header.
     */
    if (this.live === null) return
    this.finish(this.live.record)
  }

  private finish(record: TourRecord | null): TourRecord | null {
    const live = this.live
    this.live = null
    if (live === null) return null
    if (live.timer !== null) clearTimeout(live.timer)
    live.unwatch()
    // A promise still waiting is settled as a failure rather than left hanging:
    // a tool call that never returns is a copilot turn that never ends.
    live.settle?.(false)
    const closed: TourRecord = { ...(record ?? live.record), endedAt: this.now() }
    this.write(closed)
    return closed
  }

  private write(record: TourRecord): void {
    try {
      mkdirSync(this.dir, { recursive: true, mode: 0o700 })
      writeFileSync(join(this.dir, `${record.id}.json`), `${JSON.stringify(record, null, 2)}\n`, {
        mode: 0o600,
      })
      this.roll()
    } catch (error) {
      // A record that cannot be written must not take the tour down with it.
      // The tour is the thing the person asked for; the record is the account of
      // it, and an account that fails to save is worth a line in the console and
      // nothing more dramatic.
      console.error('[deck-control] could not write the tour record:', error)
    }
  }

  private roll(): void {
    const names = readdirSync(this.dir)
      .filter((name) => name.endsWith('.json'))
      .sort()
    // Sorted by name, which for `tour_<epoch>_<random>` is chronological until
    // the epoch gains a digit — in 2286. Cheaper than reading fifty files to
    // sort by a field inside them, on a path that runs after every stop.
    for (const name of names.slice(0, Math.max(0, names.length - MAX_TOURS_KEPT))) {
      rmSync(join(this.dir, name), { force: true })
    }
  }
}

/**
 * Fold the window's progress into the record, keeping everything the window is
 * not allowed to change.
 *
 * Exported so the merge rule is testable on its own. The rule in one sentence:
 * **the window may say what happened, never what was said.**
 */
export function mergeProgress(record: TourRecord, update: Partial<TourRecord>): TourRecord {
  const stops = record.stops.map((stop) => {
    const from = update.stops?.find((entry) => entry.index === stop.index)
    if (from === undefined) return stop
    return {
      // Everything the window is not allowed to change is taken from `stop`,
      // which is this side's own validated copy, and only the four progress
      // fields below come from the update. A renderer bug that shuffled the
      // quotes would otherwise put unchecked text into the audit record.
      ...stop,
      shownAt: numberOrNull(from.shownAt),
      dwellMs: numberOrNull(from.dwellMs),
      degraded: from.degraded === true,
      degradedWhy: typeof from.degradedWhy === 'string' ? from.degradedWhy : null,
    }
  })
  return {
    ...record,
    stops,
    stoppedAfter: numberOrNull(update.stoppedAfter),
    ...(update.endedAt === undefined ? {} : { endedAt: numberOrNull(update.endedAt) }),
  }
}

function numberOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}
