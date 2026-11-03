/**
 * What the engine has to remember across a restart.
 *
 * Deliberately **not** in the routine files. A routine file is a saved
 * instruction that a person wrote and may edit in a text editor; the timestamps
 * below are bookkeeping the machine wrote, they change several times an hour,
 * and mixing them in would mean every run rewrote a file the user has open.
 * They live in one small JSON file beside the routines folder instead.
 *
 * ## Two things depend on this surviving a restart, and one of them is security
 *
 * 1. **"The app was closed all weekend."** A schedule that came due while
 *    nothing was running is invisible without a record of when the routine last
 *    ran. With it, the engine can say "this should have run twice since Friday"
 *    — which is half the answer to how a person tells a broken routine from a
 *    quiet one.
 *
 * 2. **The cost ceiling cannot be reset by restarting.** Run counts held only in
 *    memory make "at most six runs an hour" mean "at most six runs per launch",
 *    and an app that crashes and relaunches — or a routine whose own work
 *    restarts the app — would spend without limit while every counter read zero.
 *    A budget that a restart clears is not a budget. So run timestamps are
 *    persisted, and the window is measured against the wall clock rather than
 *    against uptime. See {@link runtimeStateFileFor} for why that makes *where*
 *    this file sits a security question rather than a filing one.
 *
 * ## Why the writes are debounced but the reads are not
 *
 * A run start writes; that is a handful of times an hour and it is written
 * through, because the case this exists for is the one where the process does
 * not get to shut down cleanly. Everything else — outcomes, last-fired times —
 * is coalesced behind a short timer, because a chatty trigger updates
 * `lastFiredAt` far more often than it runs anything and none of those updates
 * is worth a file write on its own.
 */

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { userDataDir } from '../platform/paths'

export const RUNTIME_STATE_VERSION = 1

/** Run timestamps older than this are of no interest to any window we keep. */
const RETAIN_MS = 25 * 60 * 60 * 1000
/** A routine cannot accumulate more run stamps than its hard daily ceiling. */
const MAX_STAMPS = 600

/**
 * How many refused calls are kept per routine.
 *
 * Ten. This is a record for a person to read in the morning — "your overnight
 * routine did nothing; here is the call it was not allowed to make" — and the
 * first two are almost always the whole story. Keeping the *most recent* ten
 * rather than the first ten is deliberate: a routine whose prompt changed last
 * week should show what it is being refused now, not what it was refused then.
 */
const MAX_REFUSALS = 10

/**
 * One call a run was not allowed to make.
 *
 * Recorded by the engine rather than reported by the runner, and that is the
 * whole reason the shape lives here instead of on `RoutineRunOutcome`. The
 * runner is a language model's turn; asking it to hand back an honest list of
 * everything it was refused is asking the thing that was refused to file the
 * report. The engine owns the tool caller a run is given, so it sees every
 * refusal first-hand and the model cannot omit one.
 */
export interface RoutineRefusal {
  /** Epoch ms. */
  at: number
  /** Canonical dotted tool id, as the action log records it — `settings.write`. */
  tool: string
  /** The `RefusalReason` from `deck-control`, carried as a string to avoid a cycle. */
  reason: string
  /** The run this happened in, so it can be lined up with the action log. */
  runId: string
}

export interface RoutineRuntime {
  /** Epoch ms of every run *start* in the last day. The budget windows read this. */
  runs: number[]
  /** The last time any trigger fired for this routine, matched or suppressed. */
  lastFiredAt: number | null
  /** The last time a run finished, and how. */
  lastFinishedAt: number | null
  lastOutcome: 'ok' | 'failed' | null
  lastError: string | null
  consecutiveFailures: number
  /**
   * Set when a person (or the engine, after repeated failures) stopped this
   * routine without editing its file. Survives a restart on purpose: a routine
   * paused because it failed five times in a row must not come back armed
   * simply because somebody quit the app.
   */
  pausedReason: string | null
  /**
   * Calls this routine's runs were refused, newest last, capped.
   *
   * Persisted with everything else here for the same reason the run counts are:
   * the person who needs it is the one opening the app the next morning, and a
   * record that a restart clears is a record that is never read. It is the
   * answer to "the routine ran and nothing happened" — the one question an
   * unattended automation is otherwise unable to answer about itself.
   */
  refusals: RoutineRefusal[]
}

export function emptyRuntime(): RoutineRuntime {
  return {
    runs: [],
    lastFiredAt: null,
    lastFinishedAt: null,
    lastOutcome: null,
    lastError: null,
    consecutiveFailures: 0,
    pausedReason: null,
    refusals: [],
  }
}

/**
 * Add a refusal to a routine's record, keeping only the newest few.
 *
 * A free function rather than a method so the engine's `update` callback — which
 * is handed a plain {@link RoutineRuntime} and nothing else — can call it, and
 * so the cap is applied in one place rather than at each site that appends.
 */
export function noteRefusal(runtime: RoutineRuntime, refusal: RoutineRefusal): void {
  runtime.refusals.push(refusal)
  if (runtime.refusals.length > MAX_REFUSALS) {
    runtime.refusals = runtime.refusals.slice(-MAX_REFUSALS)
  }
}

interface Persisted {
  version: number
  routines: Record<string, RoutineRuntime>
}

/**
 * Where the engine's bookkeeping lives, given this install's user-data
 * directory.
 *
 * `<userData>/routine-state.json`, beside `<userData>/routines/` and **outside**
 * `<userData>/copilot/`. It sat inside the copilot's folder until the routines
 * folder moved out from under it, and it had to move for a sharper reason than
 * tidiness: this file is the only place the two ceilings in point 2 above are
 * recorded, and `pausedReason` — the field that holds a routine stopped after
 * five consecutive failures — is in it too. A file the copilot can write is a
 * budget the copilot can zero and a pause the copilot can lift, without a tool
 * call, without a confirmation and without a row in the action log. Everything
 * privileged that reads this file now reads it from outside the boundary.
 */
export function runtimeStateFileFor(userData: string): string {
  return join(userData, 'routine-state.json')
}

export interface RuntimeStateOptions {
  /** Defaults to `<userData>/routine-state.json`. */
  file?: string
  now?: () => number
  /** How long to coalesce non-critical writes. Zero writes through, for tests. */
  debounceMs?: number
}

export class RuntimeState {
  readonly file: string
  private readonly now: () => number
  private readonly debounceMs: number
  private data: Persisted
  private timer: NodeJS.Timeout | null = null

  constructor(options: RuntimeStateOptions = {}) {
    this.file = options.file ?? runtimeStateFileFor(userDataDir())
    this.now = options.now ?? Date.now
    this.debounceMs = options.debounceMs ?? 400
    this.data = this.load()
  }

  private load(): Persisted {
    try {
      const raw = JSON.parse(readFileSync(this.file, 'utf8')) as Partial<Persisted>
      const routines: Record<string, RoutineRuntime> = {}
      for (const [id, value] of Object.entries(raw.routines ?? {})) {
        if (id === '__proto__') continue
        const runtime = emptyRuntime()
        // Field by field rather than a spread, because this file is on disk
        // where anything can edit it and a spread would let a string land where
        // the budget arithmetic expects numbers.
        if (Array.isArray(value?.runs)) {
          runtime.runs = value.runs.filter((at): at is number => typeof at === 'number').slice(-MAX_STAMPS)
        }
        if (typeof value?.lastFiredAt === 'number') runtime.lastFiredAt = value.lastFiredAt
        if (typeof value?.lastFinishedAt === 'number') runtime.lastFinishedAt = value.lastFinishedAt
        if (value?.lastOutcome === 'ok' || value?.lastOutcome === 'failed') {
          runtime.lastOutcome = value.lastOutcome
        }
        if (typeof value?.lastError === 'string') runtime.lastError = value.lastError.slice(0, 500)
        if (typeof value?.consecutiveFailures === 'number') {
          runtime.consecutiveFailures = Math.max(0, Math.floor(value.consecutiveFailures))
        }
        if (typeof value?.pausedReason === 'string') runtime.pausedReason = value.pausedReason.slice(0, 300)
        if (Array.isArray(value?.refusals)) {
          // Field by field again, and for a sharper reason than the others: this
          // list is shown to a person as the explanation for why their routine
          // did nothing, so a malformed row would be a *misleading* row rather
          // than merely a wrong number. Anything that is not the full shape is
          // dropped rather than patched up with defaults.
          runtime.refusals = value.refusals
            .filter(
              (entry): entry is RoutineRefusal =>
                typeof entry === 'object' &&
                entry !== null &&
                typeof (entry as RoutineRefusal).at === 'number' &&
                typeof (entry as RoutineRefusal).tool === 'string' &&
                typeof (entry as RoutineRefusal).reason === 'string' &&
                typeof (entry as RoutineRefusal).runId === 'string',
            )
            .map((entry) => ({
              at: entry.at,
              tool: entry.tool.slice(0, 100),
              reason: entry.reason.slice(0, 100),
              runId: entry.runId.slice(0, 100),
            }))
            .slice(-MAX_REFUSALS)
        }
        routines[id] = runtime
      }
      return { version: RUNTIME_STATE_VERSION, routines }
    } catch {
      // Missing is the normal first launch, and corrupt means the engine starts
      // with clean counters — which errs towards *fewer* runs, not more, because
      // every window is empty and every routine looks freshly quiet.
      return { version: RUNTIME_STATE_VERSION, routines: {} }
    }
  }

  get(id: string): RoutineRuntime {
    const existing = this.data.routines[id]
    if (existing) return existing
    const fresh = emptyRuntime()
    this.data.routines[id] = fresh
    return fresh
  }

  /** Apply a change and write it out soon. */
  update(id: string, change: (runtime: RoutineRuntime) => void, immediate = false): void {
    change(this.get(id))
    if (immediate) this.flush()
    else this.schedule()
  }

  /** Forget a routine whose file is gone, so the file does not grow forever. */
  forgetMissing(present: ReadonlySet<string>): void {
    let changed = false
    for (const id of Object.keys(this.data.routines)) {
      if (present.has(id)) continue
      delete this.data.routines[id]
      changed = true
    }
    if (changed) this.schedule()
  }

  /** Drop run stamps that have aged out of every window we keep. */
  prune(): void {
    const cutoff = this.now() - RETAIN_MS
    for (const runtime of Object.values(this.data.routines)) {
      const kept = runtime.runs.filter((at) => at >= cutoff)
      if (kept.length !== runtime.runs.length) runtime.runs = kept.slice(-MAX_STAMPS)
    }
  }

  private schedule(): void {
    if (this.debounceMs <= 0) {
      this.flush()
      return
    }
    if (this.timer) return
    this.timer = setTimeout(() => {
      this.timer = null
      this.flush()
    }, this.debounceMs)
    // A pending write must not be a reason for the process to stay alive. The
    // data it holds is bookkeeping; losing the last few hundred milliseconds of
    // it at quit costs a `lastFiredAt`, and a timer that kept a headless host
    // running would cost a great deal more.
    this.timer.unref?.()
  }

  flush(): void {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    this.prune()
    try {
      mkdirSync(dirname(this.file), { recursive: true })
      const temp = `${this.file}.tmp`
      writeFileSync(temp, JSON.stringify(this.data, null, 2), 'utf8')
      renameSync(temp, this.file)
    } catch {
      // Bookkeeping. A machine that cannot write it still runs routines; it
      // simply forgets its counters at the next launch, which errs towards
      // fewer runs rather than more.
    }
  }

  stop(): void {
    this.flush()
  }
}
