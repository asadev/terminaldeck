/**
 * The routine engine: what turns a saved instruction into a thing that happens.
 *
 * ## It subscribes; it does not poll
 *
 * Asad's standing preference decides the architecture here and it is not
 * negotiable: *"events, not polling — webhooks, APIs and push over crons and
 * timers, they make the system heavier."* So this class has **no interval
 * anywhere**. Every trigger except `schedule` is a method somebody else calls
 * when something the app was already doing produced an event:
 *
 * | Trigger | Who calls in |
 * |---|---|
 * | `session-finished`, `session-failed` | {@link RoutineEngine.noteSessionExit}, from `PtyManager`'s exit callback |
 * | `session-idle` | {@link RoutineEngine.noteSessionStatus}, from `ActivityTracker`'s status callback |
 * | `alert` | {@link RoutineEngine.noteAlertReport}, from a scan the alerts panel already ran |
 * | `git-change` | the git watch that `watchGit` already runs for the git panel |
 * | `file-change` | a chokidar watcher on the routine's own folder — OS file events, not a scan |
 * | `schedule` | one timer, for the earliest due routine across all of them |
 * | `manual` | {@link RoutineEngine.runNow} |
 *
 * The timers that do exist are all *delays after an event*, which is a
 * different thing from a poll: a `session-idle 15m` timer is armed when a
 * session goes quiet and cancelled the instant it says anything, and the
 * schedule timer is armed for one instant and re-armed when it fires. Nothing
 * here ever wakes up to re-read state and ask whether something changed.
 *
 * ## The four hard problems, and where each is answered
 *
 * **A routine that triggers itself.** "When a session finishes, start a
 * session" is one line away from a machine that never stops. Three layers, in
 * order of how much they are relied on:
 *
 *  1. *Provenance.* Every session a routine starts carries `origin: 'copilot'`
 *     and the id of the run that started it, so an event arriving from that
 *     session can be traced back to the routine that caused it. A routine is
 *     never fired by its own descendants — see {@link chainFor}. This is the
 *     real fix, and it is exact rather than statistical.
 *  2. *Chain depth.* A triggers B triggers A is a loop no single routine can
 *     see. Each run carries the chain of routines that led to it and refuses
 *     past {@link MAX_CHAIN_DEPTH}.
 *  3. *The budget.* Events that cannot be attributed — a file changing, a git
 *     status moving — have no provenance to follow, so for those the guard is
 *     that a routine's own run suppresses them while it is in flight, plus the
 *     per-routine and app-wide ceilings below. A loop that escapes the first
 *     two layers runs a handful of times and stops with a reason attached,
 *     rather than forever.
 *
 * **Overlap.** The default is `queue`, and the queue is **one deep**. A trigger
 * that fires while a run is going records that it fired; further fires collapse
 * into that same pending run. Unbounded queueing is the cost problem wearing a
 * different hat, and dropping the event outright loses work that a person asked
 * for. `skip` and `cancel` are available per routine. `cancel` is never the
 * default: stopping an agent turn half way leaves half-applied edits, and this
 * app is not able to undo them.
 *
 * **Cost.** Two ceilings, and they belong to different people. A routine sets
 * its own `max-runs-per-hour` and `max-runs-per-day` within hard limits that
 * `format.ts` clamps to, because a routine file is user-editable and the copilot
 * can write one. The **app-wide** ceiling across all routines is not in any
 * routine file and the copilot has no tool that changes it — it is a setting
 * the person owns. Hitting either pauses the routine with a reason and a time
 * it recovers, rather than throttling it silently. Counts are persisted, because
 * a budget a restart clears is not a budget.
 *
 * **Nobody is watching.** Every run this class starts is unattended, and that is
 * a flat rule rather than a property of the trigger. A routine firing at 03:00
 * plainly has no one to answer a confirmation, so an alter-tier tool call from
 * it is refused at the boundary with `not-permitted-unattended` instead of
 * waiting two minutes for a dialog nobody will see — the failure OpenClaw
 * recorded, where a heartbeat spent turn after turn apologising for an approval
 * it structurally could not obtain.
 *
 * The flat part is worth defending, because a *manual* run — somebody pressing
 * Run now with their hand on the mouse — is obviously attended, and it is still
 * marked unattended here. Two reasons. The first is that pressing Run now is how
 * a person tests a routine, and a test that takes a different path from the
 * 03:00 run is a test that proves nothing about it: the whole point of trying it
 * by hand is to find out what it will do when nobody is there. The second is
 * that `routines.run` is an Act-tier tool the copilot itself can call, so
 * "manual" does not reliably mean a human at all. One rule, no branch, and the
 * branch is where the permissive value would eventually leak.
 *
 * **Failure.** A routine whose trigger stopped firing looks exactly like a quiet
 * one, so the engine refuses to let the two look alike. Every routine reports
 * whether it is *armed* — and when it is not, the sentence saying why, which is
 * a real fact rather than a guess: the folder is gone, the copilot is not
 * running, this build has no emitter for that trigger. Every trigger *source*
 * separately reports whether anything has been heard from it at all, so "no
 * alerts fired" and "nothing has scanned for alerts since 09:12" are
 * distinguishable — and the second is the one that is actually wrong. All of it
 * is derived when somebody asks, so there is no watchdog timer either.
 */

import { randomUUID } from 'node:crypto'
import { isAbsolute, relative, resolve, sep } from 'node:path'
import picomatch from 'picomatch'
import type { AlertReport, AlertSeverity } from '../alerts'
import type { SessionMeta, SessionStatus } from '../../shared/types'
import { defaultRoutineLogger, type RoutineLogger } from './log'
import {
  serializeTrigger,
  type OverlapPolicy,
  type Routine,
  type Trigger,
  type TriggerKind,
} from './format'
import { missedRuns, nextDue } from './schedule'
import type { RoutineStore, StoredRoutine } from './store'
import { noteRefusal, RuntimeState, type RoutineRefusal } from './runtime-state'
import type { ToolCaller } from '../deck-control/control'

/* ------------------------------------------------------------------ limits */

/**
 * How many routines may appear in one causal chain before the engine calls it a
 * loop.
 *
 * Three, because two is a legitimate arrangement somebody will build on purpose
 * — a routine that notices a failure and starts a session, and a second routine
 * that reacts when that session finishes — and four has never been anything but
 * a mistake.
 */
export const MAX_CHAIN_DEPTH = 3

/**
 * Consecutive failures before a routine is stopped and told to a person.
 *
 * A routine that fails immediately is the cheapest possible infinite loop: it
 * costs almost nothing per attempt, so the rate limits take hours to bite while
 * it fills the action log. Five is enough to ride out a transient.
 */
export const MAX_CONSECUTIVE_FAILURES = 5

/** How long a cancelled run is given to actually stop before its replacement is dropped. */
export const CANCEL_GRACE_MS = 10_000

/** The app-wide ceiling when nobody has set one. Runs per hour, across every routine. */
export const DEFAULT_GLOBAL_MAX_RUNS_PER_HOUR = 60

/** `setTimeout` silently fires immediately past this, so long waits are chunked. */
const MAX_TIMEOUT_MS = 2_147_483_647

const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * HOUR_MS

/**
 * Session records kept for provenance. Bounded because this map is fed by an
 * event and emptied by another, and a missed exit would otherwise leak forever.
 */
const MAX_TRACKED_SESSIONS = 500
/** Completed runs kept for chain lookups. A chain is only ever a few deep. */
const MAX_TRACKED_RUNS = 200

/* ------------------------------------------------------------------- types */

/** Why a routine ran. Carried into the run, the action log and the UI. */
export type RoutineCause =
  | { kind: 'manual'; by: 'user' | 'copilot' }
  | { kind: 'session-finished'; sessionId: string; exitCode: number }
  | { kind: 'session-failed'; sessionId: string; exitCode: number }
  | { kind: 'session-idle'; sessionId: string; afterMs: number }
  | { kind: 'alert'; alertId: string; severity: AlertSeverity; title: string; sessionId?: string }
  | { kind: 'git-change'; folder: string }
  | { kind: 'file-change'; folder: string; path: string }
  | { kind: 'schedule'; dueAt: number; missed: number }

export interface RoutineRunRequest {
  routine: Routine
  /**
   * This run's id — and a contract, not a label.
   *
   * A runner that starts sessions **must** pass this as `originRunId` on the
   * `CreateSessionInput`, alongside `origin: 'copilot'` and the routine's id.
   * That is what lets an exit event arriving half an hour later be traced back
   * here, and it is the exact mechanism that stops "when a session finishes,
   * start a session" running away.
   *
   * {@link RoutineRunOutcome.sessionIds} is the backstop for a runner that
   * could not, and it is genuinely weaker: it is only applied when the run
   * *resolves*, so a session that starts and exits inside one run — and was not
   * labelled at spawn — arrives with no provenance and is caught by the ceilings
   * rather than by the chain. Label at spawn.
   */
  runId: string
  cause: RoutineCause
  /** The routines that led here, oldest first. Empty for a cause nobody caused. */
  chain: readonly string[]
  /**
   * Aborted when the run is cancelled — by `overlap: cancel`, or by the engine
   * stopping. A runner that ignores it turns `cancel` into `queue`; see
   * {@link RoutineRunner.cancellable}.
   */
  signal: AbortSignal
  /**
   * Always `false`, and typed as the literal so nothing can set it otherwise.
   *
   * A routine fires on a schedule or on an event, which means it can fire at
   * 03:00 with the machine locked and its owner asleep. The copilot's alter tier
   * is defined as *a real question put to a real person*; there is no person, so
   * there is no question to put. Every run carries this, and it is the fact the
   * refusal in `deck-control/control.ts` is built on.
   *
   * It is on the request rather than only inside {@link control} because the
   * runner has its own decisions to make with it: it is what tells the prompt
   * assembly to say "you are running unattended; report, do not ask" instead of
   * offering the model an interactive framing it cannot use.
   */
  readonly attended: false
  /**
   * The app's tool surface for this run, already unattended and already
   * recording.
   *
   * Null until a shell passes `control` to {@link createRoutines}; a runner that
   * finds it null has no way to reach the app and should say so rather than
   * pretending.
   *
   * A runner is handed *this* rather than the `DeckControl` itself, and that is
   * the enforcement. Every call through it is marked `attended: false` by
   * construction, so an alter-tier tool is refused at the boundary in
   * microseconds instead of blocking on a dialog for two minutes. And the engine
   * wraps it, so every refusal lands in this routine's own record on the way
   * past — which is what makes "my routine did nothing and I do not know why"
   * answerable without the runner having to volunteer anything.
   */
  control: ToolCaller | null
}

export interface RoutineRunOutcome {
  ok: boolean
  /**
   * Sessions this run started. The engine records them so an event arriving
   * from one of them can be traced back to this run — which is what stops
   * "when a session finishes, start a session" running away.
   */
  sessionIds?: string[]
  /** One sentence, for the action log and the routine's own health. */
  error?: string
}

/**
 * Whatever actually performs a routine's prompt.
 *
 * There is deliberately no default implementation here, and no fallback that
 * does something approximate. `COPILOT-DESIGN.md` is explicit that routines run
 * *through the copilot* — "a routine is a saved instruction to the same agent,
 * so there is one system to understand and one action log to read" — and the
 * copilot is phase 1 and 2 of that document. Until one is registered, every
 * routine reports itself unarmed with that sentence attached, which is the
 * honest state: the triggers are wired, and there is nothing on the other end
 * of them yet.
 */
export interface RoutineRunner {
  /**
   * Whether {@link RoutineRunRequest.signal} actually stops the work.
   *
   * Declared rather than assumed, because `overlap: cancel` is a promise to the
   * user that this app can only keep if the runner keeps it first. When false,
   * a `cancel` routine still never runs twice at once — the engine waits — but
   * its health says so instead of the app quietly behaving differently from
   * what the routine file asks for.
   */
  readonly cancellable?: boolean
  run(request: RoutineRunRequest): Promise<RoutineRunOutcome>
}

export type RoutineStateName =
  | 'armed'
  | 'running'
  | 'disabled'
  | 'broken'
  | 'unarmed'
  | 'paused'
  | 'stale'

export interface TriggerSourceView {
  kind: TriggerKind
  /** Is anything wired to this trigger in this build, right now? */
  subscribed: boolean
  /** The last time this source produced *any* event, for any routine. */
  lastEventAt: number | null
  events: number
  /** Set when `subscribed` is false, or when the source needs something to work. */
  note: string | null
}

export interface RoutineView {
  id: string
  name: string
  file: string
  folder: string | null
  /** Serialised back to the `when:` lines, so the UI shows what the file says. */
  triggers: string[]
  prompt: string
  enabled: boolean
  overlap: OverlapPolicy | null
  state: RoutineStateName
  /** One sentence saying why the state is what it is. Null when simply armed. */
  reason: string | null
  problems: string[]
  warnings: string[]
  lastFiredAt: number | null
  lastRunAt: number | null
  lastFinishedAt: number | null
  lastOutcome: 'ok' | 'failed' | null
  lastError: string | null
  consecutiveFailures: number
  /**
   * Calls this routine's runs were not allowed to make, newest last.
   *
   * The answer to the only question an unattended automation cannot answer about
   * itself: *it ran, and nothing happened, and why?* Almost always this holds
   * one row saying an alter-tier tool was refused because nobody was at the
   * machine — which is not a fault, it is the boundary working, and the person
   * reading it is being told there is a decision waiting for them rather than
   * that their routine is broken.
   */
  refusedCalls: RoutineRefusal[]
  running: boolean
  pending: boolean
  runsLastHour: number
  runsLastDay: number
  firesLastHour: number
  maxRunsPerHour: number | null
  maxRunsPerDay: number | null
  /** When a paused routine recovers on its own. Null when a person has to act. */
  pausedUntil: number | null
  nextDueAt: number | null
  /** Times a schedule came due while the app was not running. */
  missedWhileClosed: number
  sources: TriggerSourceView[]
}

export type RunRequestResult =
  | { started: true; runId: string }
  | { started: false; reason: string }

/* ------------------------------------------------------------------ options */

export interface RoutineEngineOptions {
  store: RoutineStore
  runtime?: RuntimeState
  log?: RoutineLogger
  /** Absent until the copilot exists. See {@link RoutineRunner}. */
  runner?: RoutineRunner | null
  /**
   * The app's own tool surface, for runs to act through.
   *
   * The shell passes `deckControl.control.unattended()` and nothing else. Taking
   * the narrowed {@link ToolCaller} rather than the `DeckControl` is what makes
   * "a routine cannot make an attended call" true by typing instead of by
   * discipline — this class could not mark a call attended if it wanted to,
   * because it is not holding anything that has the option.
   */
  control?: ToolCaller | null
  /**
   * Is this folder one this app may watch and run in?
   *
   * A routine file is hand-editable and the copilot can write one, so `in:` is
   * an untrusted absolute path. Without this a routine could name `/` and the
   * engine would attach a recursive file watch to the whole disk on its behalf.
   * The shell passes "one of this desktop's own projects"; a routine naming
   * anything else is listed, unarmed, with the reason on it.
   */
  allowFolder?(folder: string): { ok: true } | { ok: false; reason: string }
  /**
   * The app-wide ceiling, in runs per hour across every routine.
   *
   * A function rather than a number so the person can change it without a
   * relaunch — and deliberately *not* readable from a routine file, because the
   * whole point of an app-wide ceiling is that no single routine can raise it.
   */
  globalMaxRunsPerHour?(): number
  now?(): number
  /** Injected so tests need no real clock. */
  setTimer?(fn: () => void, ms: number): unknown
  clearTimer?(handle: unknown): void
  /**
   * Attach a file watcher to a folder. Returns the way to detach it.
   *
   * Supplied by `sources.ts` so this class holds no chokidar of its own and can
   * be tested without a filesystem.
   */
  watchFiles?(folder: string, onChange: (relativePath: string) => void): () => void
  /** Hold a git watch on a folder with no window attached. Returns the release. */
  watchGit?(folder: string, onChange: () => void): () => void
}

/* -------------------------------------------------------------- internals */

interface RunHandle {
  runId: string
  startedAt: number
  cause: RoutineCause
  chain: readonly string[]
  controller: AbortController
  cancelling: boolean
}

interface PendingRun {
  cause: RoutineCause
  chain: readonly string[]
}

interface Entry {
  id: string
  file: string
  routine: Routine | null
  problems: string[]
  warnings: string[]
  armed: boolean
  armProblem: string | null
  disposers: Array<() => void>
  running: RunHandle | null
  pending: PendingRun | null
  quietTimer: unknown
  cancelTimer: unknown
  /** Fires in the trailing hour, matched or suppressed. The chattiness number. */
  fires: number[]
  nextDueAt: number | null
  scheduleAnchor: number | null
  missedWhileClosed: number
}

interface TrackedSession {
  cwd: string
  routineId: string | null
  runId: string | null
}

interface TrackedRun {
  routineId: string
  chain: readonly string[]
}

interface SourceState {
  subscribed: boolean
  note: string | null
  lastEventAt: number | null
  events: number
}

const ALL_TRIGGER_KINDS: readonly TriggerKind[] = [
  'session-finished',
  'session-failed',
  'session-idle',
  'alert',
  'git-change',
  'file-change',
  'schedule',
  'manual',
]

/** Is `child` the folder itself, or inside it? Host path semantics, so Windows works. */
export function within(folder: string, child: string): boolean {
  const rel = relative(resolve(folder), resolve(child))
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel))
}

/* -------------------------------------------------------------- the engine */

/**
 * The separator inside an idle-timer key, spelled as an escape.
 *
 * NUL is right for the job: it cannot appear in a routine id or a session
 * id, so no two pairs can be made to collide by the joining itself. Typing
 * the raw byte is what is wrong, and it is wrong in a way that hides: one
 * NUL makes `file`(1) call this source `data` and makes `grep`(1) treat it
 * as binary and match it silently, so a search for anything declared here
 * comes back empty and reads as "it lives somewhere else".
 *
 * `src/encoding.test.ts` fails the build on a NUL in any tracked source.
 * It caught this one at the release gate — but only after `git add` made
 * the file tracked, which is the gap worth knowing about.
 */
const KEY_SEP = '\u0000'

export class RoutineEngine {
  private readonly store: RoutineStore
  private readonly runtime: RuntimeState
  private readonly log: RoutineLogger
  private runner: RoutineRunner | null
  private control: ToolCaller | null
  private readonly options: RoutineEngineOptions
  private readonly now: () => number
  private readonly setTimer: (fn: () => void, ms: number) => unknown
  private readonly clearTimer: (handle: unknown) => void

  private readonly entries = new Map<string, Entry>()
  private readonly sessions = new Map<string, TrackedSession>()
  private readonly runs = new Map<string, TrackedRun>()
  private readonly sources = new Map<TriggerKind, SourceState>()
  /** Alert ids already seen per project, so only a *new* alert fires anything. */
  private readonly alertsSeen = new Map<string, Set<string>>()
  /** Live idle countdowns, keyed by routine and session. */
  private readonly idleTimers = new Map<string, unknown>()
  private scheduleTimer: unknown = null
  private started = false
  private stopped = false

  constructor(options: RoutineEngineOptions) {
    this.options = options
    this.store = options.store
    this.runtime = options.runtime ?? new RuntimeState()
    this.log = options.log ?? defaultRoutineLogger()
    this.runner = options.runner ?? null
    this.control = options.control ?? null
    this.now = options.now ?? Date.now
    this.setTimer = options.setTimer ?? ((fn, ms) => setTimeout(fn, ms))
    this.clearTimer = options.clearTimer ?? ((handle) => clearTimeout(handle as NodeJS.Timeout))

    for (const kind of ALL_TRIGGER_KINDS) {
      // Everything starts unsubscribed and says so. A source that is silently
      // assumed to be wired is the failure this whole health surface exists to
      // make impossible, so the default has to be the pessimistic one.
      this.sources.set(kind, {
        subscribed: kind === 'manual' || kind === 'schedule',
        note:
          kind === 'manual' || kind === 'schedule'
            ? null
            : 'Nothing in this process has subscribed to this yet.',
        lastEventAt: null,
        events: 0,
      })
    }
  }

  /* ------------------------------------------------------------ lifecycle */

  /**
   * Read the folder, arm everything that can be armed, and watch for hand edits.
   *
   * Called at boot rather than when a settings pane opens, which is the failure
   * this repository has paid for most — a feature built and never wired to
   * launch. A routine folder that is only read when somebody looks at it is a
   * set of automations that run only while the settings window is open.
   */
  start(): void {
    if (this.started || this.stopped) return
    this.started = true
    this.reload()
    this.store.startWatching(() => this.reload())
  }

  /** Register the thing routines run through. Re-arms everything. */
  setRunner(runner: RoutineRunner | null): void {
    this.runner = runner
    if (this.started) this.reload()
  }

  /**
   * Register the app's tool surface — the **unattended** one — after the fact.
   *
   * A setter and not only a constructor option because of the order the shell is
   * assembled in: `createRoutines` runs at module scope while
   * `registerDeckControlIpc` is awaited later, so at the moment the engine is
   * built there is nothing to hand it. Without this the wiring would have to
   * move one of the two, and a feature that is hard to wire is a feature that
   * ends up wired to a settings pane instead of to boot — the failure this
   * repository has paid for most.
   *
   * It takes a {@link ToolCaller} rather than a `DeckControl` for the reason
   * given on {@link RoutineEngineOptions.control}: the type is the enforcement.
   * The shell passes `deckControl.control.unattended()`.
   *
   * Runs already in flight keep the caller they were given. Swapping the surface
   * under a turn that is mid-call would be a change nobody asked for at a moment
   * nobody chose.
   */
  setControl(control: ToolCaller | null): void {
    this.control = control
  }

  /**
   * Say whether a trigger source is live in this process, and why not if it is
   * not. Called by `sources.ts` as it wires each one.
   */
  markSource(kind: TriggerKind, subscribed: boolean, note: string | null = null): void {
    const state = this.sources.get(kind)
    if (!state) return
    state.subscribed = subscribed
    state.note = note
  }

  async stop(): Promise<void> {
    this.stopped = true
    for (const entry of this.entries.values()) this.disarm(entry)
    for (const handle of this.idleTimers.values()) this.clearTimer(handle)
    this.idleTimers.clear()
    if (this.scheduleTimer !== null) this.clearTimer(this.scheduleTimer)
    this.scheduleTimer = null
    this.runtime.stop()
    await this.store.stop()
  }

  /* --------------------------------------------------------------- loading */

  /**
   * Re-read every routine file and rebuild the subscriptions.
   *
   * A running routine is deliberately left running: its file changing under it
   * does not make the work it is doing wrong, and killing an agent turn because
   * somebody fixed a typo in the prompt would be a surprising thing for an
   * editor save to do. The *next* run uses the new file.
   */
  reload(): void {
    if (this.stopped) return
    const stored = this.store.list()
    const present = new Set(stored.map((item) => item.id))

    for (const [id, entry] of this.entries) {
      if (present.has(id)) continue
      this.disarm(entry)
      this.entries.delete(id)
    }

    for (const item of stored) this.apply(item)
    this.runtime.forgetMissing(present)
    this.rearmSchedule()
  }

  private apply(item: StoredRoutine): void {
    const existing = this.entries.get(item.id)
    const running = existing?.running ?? null
    /*
     * A pending run survives a reload only while something is still running.
     *
     * Anything else pending is waiting on a quiet-period timer, and `disarm`
     * below is about to cancel that timer — so carrying the pending run across
     * would leave a run that nothing is going to start, which is worse than
     * dropping it because it would sit in the UI marked "queued" forever. It is
     * also the right answer on the merits: the file just changed, and the run
     * that was queued was queued for the old one.
     */
    const pending = existing?.running ? existing.pending : null
    const fires = existing?.fires ?? []
    const anchor = existing?.scheduleAnchor ?? null
    if (existing) this.disarm(existing, { keepRun: true })

    const entry: Entry = {
      id: item.id,
      file: item.file,
      routine: item.ok ? item.routine : null,
      problems: item.ok ? [] : item.problems,
      warnings: item.ok ? item.warnings : [],
      armed: false,
      armProblem: null,
      disposers: [],
      running,
      pending,
      quietTimer: null,
      cancelTimer: null,
      fires,
      nextDueAt: null,
      scheduleAnchor: anchor,
      missedWhileClosed: 0,
    }
    this.entries.set(item.id, entry)
    this.arm(entry)
  }

  /**
   * Decide whether this routine can actually run, and wire it up if it can.
   *
   * Every refusal below is a *fact about this machine right now*, phrased as a
   * sentence, and it is stored rather than logged and forgotten — that stored
   * sentence is what a person reads instead of wondering why nothing happened.
   */
  private arm(entry: Entry): void {
    const routine = entry.routine
    if (routine === null) {
      entry.armProblem = 'This routine could not be read.'
      return
    }
    if (!routine.enabled) {
      entry.armProblem = 'Turned off in its file (`enabled: no`).'
      return
    }
    const paused = this.runtime.get(entry.id).pausedReason
    if (paused !== null) {
      entry.armProblem = paused
      return
    }
    if (this.runner === null) {
      entry.armProblem =
        'The copilot is not running in this build yet, so there is nothing for a routine to run through.'
      return
    }
    if (!isAbsolute(routine.folder)) {
      entry.armProblem = `\`in: ${routine.folder}\` is not an absolute path.`
      return
    }
    const allowed = this.options.allowFolder?.(routine.folder) ?? { ok: true as const }
    if (!allowed.ok) {
      entry.armProblem = allowed.reason
      return
    }

    entry.armProblem = null
    entry.armed = true

    for (const trigger of routine.triggers) {
      if (trigger.kind === 'file-change') this.armFileWatch(entry, routine)
      else if (trigger.kind === 'git-change') this.armGitWatch(entry, routine)
      else if (trigger.kind === 'schedule') this.armSchedule(entry, trigger)
    }
  }

  private armFileWatch(entry: Entry, routine: Routine): void {
    const watch = this.options.watchFiles
    if (!watch) {
      this.markSource('file-change', false, 'No file watcher is wired in this process.')
      return
    }
    entry.disposers.push(
      watch(routine.folder, (relativePath) => {
        this.touchSource('file-change')
        for (const trigger of routine.triggers) {
          if (trigger.kind !== 'file-change') continue
          if (!matchesGlob(trigger.glob, relativePath)) continue
          this.fire(entry, { kind: 'file-change', folder: routine.folder, path: relativePath }, [])
          return
        }
      }),
    )
  }

  private armGitWatch(entry: Entry, routine: Routine): void {
    const watch = this.options.watchGit
    if (!watch) {
      this.markSource('git-change', false, 'No git watch is wired in this process.')
      return
    }
    entry.disposers.push(
      watch(routine.folder, () => {
        this.touchSource('git-change')
        this.fire(entry, { kind: 'git-change', folder: routine.folder }, [])
      }),
    )
  }

  /**
   * Work out when this routine is next due, and how many times it came due
   * while the app was not running.
   *
   * The missed count is reported and then *not acted on* beyond a single run —
   * a laptop closed over a long weekend should not wake up and fire eleven
   * catch-up sweeps, and it should not pretend nothing was missed either.
   */
  private armSchedule(entry: Entry, trigger: Extract<Trigger, { kind: 'schedule' }>): void {
    const now = this.now()
    const runtime = this.runtime.get(entry.id)
    const since = runtime.runs.length > 0 ? runtime.runs[runtime.runs.length - 1] : null
    if (since !== null) {
      entry.missedWhileClosed = missedRuns(trigger.schedule, since, now)
      entry.scheduleAnchor = since
    }
    const due = nextDue(trigger.schedule, now, entry.scheduleAnchor)
    entry.nextDueAt = entry.nextDueAt === null ? due : Math.min(entry.nextDueAt, due)
  }

  private disarm(entry: Entry, options: { keepRun?: boolean } = {}): void {
    for (const dispose of entry.disposers) {
      try {
        dispose()
      } catch {
        /* a watcher that has already gone is not a failure to detach it */
      }
    }
    entry.disposers = []
    entry.armed = false
    entry.nextDueAt = null
    if (entry.quietTimer !== null) this.clearTimer(entry.quietTimer)
    entry.quietTimer = null
    for (const [key, handle] of this.idleTimers) {
      if (!key.startsWith(`${entry.id}${KEY_SEP}`)) continue
      this.clearTimer(handle)
      this.idleTimers.delete(key)
    }
    if (!options.keepRun && entry.running) entry.running.controller.abort()
  }

  /* ------------------------------------------------------------ event input */

  /**
   * A session started, whoever started it.
   *
   * The provenance half of the loop guard lives on this call: `originRunId` on
   * the metadata is what lets an exit event thirty minutes from now be traced
   * back to the routine that caused it.
   */
  noteSessionStarted(meta: SessionMeta): void {
    if (this.sessions.size >= MAX_TRACKED_SESSIONS) {
      // Oldest first. Losing the provenance of a very old session degrades the
      // loop guard to the budget for that one session, which is the same place
      // an unattributable event already sits.
      const oldest = this.sessions.keys().next()
      if (!oldest.done) this.sessions.delete(oldest.value)
    }
    this.sessions.set(meta.id, {
      cwd: meta.cwd,
      routineId: meta.originRoutineId ?? null,
      runId: meta.originRunId ?? null,
    })
  }

  /**
   * A session's status changed.
   *
   * `idle` and `waiting` both count as idle: one is an agent that has stopped
   * producing output and the other is an agent sitting at an empty prompt, and
   * from a routine's point of view they are the same thing — nobody is doing
   * anything in that session. `input` deliberately does not count; a session
   * blocked on a question is the `alert` trigger's business, and treating it as
   * idle would fire a routine at a session that is waiting for a human.
   */
  noteSessionStatus(sessionId: string, status: SessionStatus): void {
    this.touchSource('session-idle')
    const session = this.sessions.get(sessionId)
    const quiet = status === 'idle' || status === 'waiting'

    for (const entry of this.entries.values()) {
      const routine = entry.routine
      if (!entry.armed || routine === null) continue
      for (const trigger of routine.triggers) {
        if (trigger.kind !== 'session-idle') continue
        const key = `${entry.id}${KEY_SEP}${sessionId}`
        const existing = this.idleTimers.get(key)
        if (existing !== undefined) {
          this.clearTimer(existing)
          this.idleTimers.delete(key)
        }
        if (!quiet) continue
        if (session && !within(routine.folder, session.cwd)) continue
        const afterMs = trigger.afterMs
        this.idleTimers.set(
          key,
          this.setTimer(() => {
            this.idleTimers.delete(key)
            this.fire(
              entry,
              { kind: 'session-idle', sessionId, afterMs },
              this.chainForSession(sessionId),
            )
          }, afterMs),
        )
      }
    }
  }

  /** A session's process ended. Code zero is "finished"; anything else is "failed". */
  noteSessionExit(sessionId: string, exitCode: number): void {
    const kind: TriggerKind = exitCode === 0 ? 'session-finished' : 'session-failed'
    this.touchSource(kind)
    const session = this.sessions.get(sessionId)
    const chain = this.chainForSession(sessionId)

    for (const [key, handle] of this.idleTimers) {
      if (!key.endsWith(`${KEY_SEP}${sessionId}`)) continue
      this.clearTimer(handle)
      this.idleTimers.delete(key)
    }

    for (const entry of this.entries.values()) {
      const routine = entry.routine
      if (!entry.armed || routine === null) continue
      if (session && !within(routine.folder, session.cwd)) continue
      if (!routine.triggers.some((trigger) => trigger.kind === kind)) continue
      this.fire(
        entry,
        kind === 'session-finished'
          ? { kind: 'session-finished', sessionId, exitCode }
          : { kind: 'session-failed', sessionId, exitCode },
        chain,
      )
    }

    // Kept until after the fires above, because the chain lookup needs it.
    this.sessions.delete(sessionId)
  }

  /**
   * An alerts scan produced a report.
   *
   * Only alerts that were *not* in the previous report for this project fire
   * anything. `deriveAlerts` is pure and its ids are stable across scans by
   * design, so a session that has been blocked for an hour appears in sixty
   * reports and is one event, which is what a person means by "an alert fired".
   */
  noteAlertReport(report: AlertReport): void {
    this.touchSource('alert')
    const previous = this.alertsSeen.get(report.projectPath) ?? new Set<string>()
    const current = new Set(report.alerts.map((alert) => alert.id))
    this.alertsSeen.set(report.projectPath, current)

    for (const alert of report.alerts) {
      if (previous.has(alert.id)) continue
      for (const entry of this.entries.values()) {
        const routine = entry.routine
        if (!entry.armed || routine === null) continue
        if (!within(routine.folder, report.projectPath)) continue
        for (const trigger of routine.triggers) {
          if (trigger.kind !== 'alert') continue
          if (trigger.severity !== null && trigger.severity !== alert.severity) continue
          if (trigger.alertKind !== null && trigger.alertKind !== alert.kind) continue
          this.fire(
            entry,
            {
              kind: 'alert',
              alertId: alert.id,
              severity: alert.severity,
              title: alert.title,
              ...(alert.sessionId ? { sessionId: alert.sessionId } : {}),
            },
            // An alert about a session the copilot started is the copilot's own
            // work coming back round, so it carries that session's chain.
            alert.sessionId ? this.chainForSession(alert.sessionId) : [],
          )
          break
        }
      }
    }
  }

  /**
   * Re-check the schedule after the machine was asleep.
   *
   * `setTimeout` does not run while a Mac is suspended and does not make up the
   * time when it wakes, so a routine due at 03:00 on a laptop that was shut
   * would fire whenever the timer eventually caught up — hours late, with no
   * indication. The shell calls this from the `powerMonitor` `resume` event it
   * already listens on for the relay, which is one more event rather than one
   * more timer.
   */
  wake(): void {
    if (!this.started || this.stopped) return
    this.fireDueSchedules()
    this.rearmSchedule()
  }

  /** Run a routine because somebody asked, by name. */
  async runNow(id: string, by: 'user' | 'copilot' = 'user'): Promise<RunRequestResult> {
    this.touchSource('manual')
    const entry = this.entries.get(id)
    if (!entry) return { started: false, reason: `There is no routine called \`${id}\`.` }
    if (entry.routine === null) {
      return { started: false, reason: entry.problems[0] ?? 'This routine could not be read.' }
    }
    if (this.runner === null) {
      return {
        started: false,
        reason:
          'The copilot is not running in this build yet, so there is nothing for a routine to run through.',
      }
    }
    return this.fire(entry, { kind: 'manual', by }, [], { ignoreQuiet: true })
  }

  /**
   * Stop a routine without editing its file, and start it again.
   *
   * Separate from `enabled:` on purpose. `enabled: no` is what a person wrote
   * down; a pause is what happened to it — a budget hit, five failures in a row
   * — and overwriting the file to record that would be the app editing a
   * document the user owns.
   */
  pause(id: string, reason: string): boolean {
    const entry = this.entries.get(id)
    if (!entry) return false
    this.runtime.update(id, (runtime) => {
      runtime.pausedReason = reason
    }, true)
    this.disarm(entry)
    this.arm(entry)
    return true
  }

  resume(id: string): boolean {
    const entry = this.entries.get(id)
    if (!entry) return false
    this.runtime.update(id, (runtime) => {
      runtime.pausedReason = null
      runtime.consecutiveFailures = 0
    }, true)
    this.disarm(entry)
    this.arm(entry)
    this.rearmSchedule()
    return true
  }

  /* ---------------------------------------------------------------- firing */

  private touchSource(kind: TriggerKind): void {
    const state = this.sources.get(kind)
    if (!state) return
    state.lastEventAt = this.now()
    state.events += 1
    // Hearing from a source is the only proof that it is live, and it outranks
    // whatever was declared at wiring time.
    state.subscribed = true
    state.note = null
  }

  /** The routines that led to whatever this session is doing. Empty when nobody did. */
  private chainForSession(sessionId: string): readonly string[] {
    const session = this.sessions.get(sessionId)
    if (!session) return []
    if (session.runId !== null) {
      const run = this.runs.get(session.runId)
      if (run) return run.chain
    }
    // A session tagged with a routine but whose run we no longer hold — after a
    // restart, say. The routine itself is still the right thing to refuse on.
    return session.routineId === null ? [] : [session.routineId]
  }

  /**
   * Everything between "a trigger fired" and "a run started".
   *
   * The order of the gates is the design. Provenance first, because a self-loop
   * must be refused before it is allowed to consume any budget at all;
   * then the ceilings, which are about money; then overlap, which is about
   * correctness; then the quiet period, which is about noise.
   */
  private fire(
    entry: Entry,
    cause: RoutineCause,
    chain: readonly string[],
    options: { ignoreQuiet?: boolean } = {},
  ): RunRequestResult {
    const routine = entry.routine
    if (routine === null || this.stopped) {
      return { started: false, reason: 'This routine cannot run.' }
    }
    /*
     * Manual is not a way round any of this, and that is deliberate.
     *
     * `routines.run` is an *Act*-tier tool the copilot holds, so if a hand run
     * skipped the gates below then the ceiling would be advisory: an agent in a
     * loop could call it as fast as it liked. A routine that is off, paused or
     * out of budget refuses a manual run and says which — the way back is to
     * turn it on or resume it, both of which are decisions somebody makes once
     * rather than a limit that quietly does not apply.
     */
    if (!entry.armed) {
      return { started: false, reason: entry.armProblem ?? 'This routine is not armed.' }
    }

    const now = this.now()
    entry.fires.push(now)
    entry.fires = entry.fires.filter((at) => at > now - HOUR_MS)
    this.runtime.update(entry.id, (runtime) => {
      runtime.lastFiredAt = now
    })

    // 1. Provenance. A routine is never started by its own work.
    if (chain.includes(routine.id)) {
      return this.refuse(entry, cause, 'This would have been started by its own work.')
    }
    if (chain.length >= MAX_CHAIN_DEPTH) {
      return this.refuse(
        entry,
        cause,
        `Refused after ${MAX_CHAIN_DEPTH} routines in a row started each other: ${[...chain, routine.id].join(' → ')}.`,
      )
    }

    // 2. The ceilings.
    const budget = this.budgetProblem(routine, now)
    if (budget !== null) {
      return this.refuse(entry, cause, budget)
    }

    // 3. Overlap.
    if (entry.running !== null) {
      return this.overlapping(entry, routine, cause, chain)
    }

    // 4. The quiet period. Trailing edge: the fire is remembered and runs when
    //    the period is up, so a burst of file events produces one run *after*
    //    the burst rather than one at the start of it holding a half-written
    //    tree.
    const runtime = this.runtime.get(entry.id)
    const lastRun = runtime.runs.length > 0 ? runtime.runs[runtime.runs.length - 1] : null
    if (!options.ignoreQuiet && lastRun !== null && now - lastRun < routine.quietForMs) {
      const wait = routine.quietForMs - (now - lastRun)
      if (routine.overlap === 'skip') {
        return this.refuse(entry, cause, 'Within its quiet period, and set to skip.')
      }
      entry.pending = { cause, chain }
      if (entry.quietTimer === null) {
        entry.quietTimer = this.setTimer(() => {
          entry.quietTimer = null
          const next = entry.pending
          entry.pending = null
          if (next && entry.running === null) void this.beginRun(entry, next.cause, next.chain)
        }, wait)
      }
      return { started: false, reason: 'Queued until its quiet period is over.' }
    }

    return this.startNow(entry, cause, chain)
  }

  private startNow(entry: Entry, cause: RoutineCause, chain: readonly string[]): RunRequestResult {
    const runId = randomUUID()
    void this.beginRun(entry, cause, chain, runId)
    return { started: true, runId }
  }

  private overlapping(
    entry: Entry,
    routine: Routine,
    cause: RoutineCause,
    chain: readonly string[],
  ): RunRequestResult {
    if (routine.overlap === 'skip') {
      return this.refuse(entry, cause, 'Skipped: the previous run is still going.')
    }
    // Coalesced, not queued in a list. See the module header for why the queue
    // is one deep.
    entry.pending = { cause, chain }
    if (routine.overlap === 'cancel' && entry.running && !entry.running.cancelling) {
      const running = entry.running
      running.cancelling = true
      running.controller.abort()
      this.log({
        action: 'routine.cancel',
        routine: entry.id,
        runId: running.runId,
        // `failed`, not a cancellation state of its own: from the point of view
        // of somebody reading the log a week later, a run that was stopped part
        // way did not do what it was asked, and giving it a gentler word would
        // hide a routine whose trigger fires faster than it can finish.
        outcome: 'failed',
        detail: 'Cancelled because the trigger fired again.',
      })
      // A runner that ignores the signal must not be allowed to produce two
      // concurrent runs of one routine, so the replacement waits — and if the
      // wait runs out, the replacement is dropped and said so.
      entry.cancelTimer = this.setTimer(() => {
        entry.cancelTimer = null
        if (entry.running?.runId !== running.runId) return
        entry.pending = null
        this.log({
          action: 'routine.cancel',
          routine: entry.id,
          runId: running.runId,
          outcome: 'refused',
          detail: 'The previous run did not stop when it was asked to, so the new one was dropped.',
        })
      }, CANCEL_GRACE_MS)
      return { started: false, reason: 'Cancelling the previous run.' }
    }
    return { started: false, reason: 'Queued behind the run that is going.' }
  }

  /** Null when there is room, or the sentence saying there is not. */
  private budgetProblem(routine: Routine, now: number): string | null {
    const runtime = this.runtime.get(routine.id)
    const lastHour = runtime.runs.filter((at) => at > now - HOUR_MS)
    const lastDay = runtime.runs.filter((at) => at > now - DAY_MS)

    if (lastHour.length >= routine.maxRunsPerHour) {
      const until = lastHour[0] + HOUR_MS
      return `Its hourly ceiling of ${routine.maxRunsPerHour} runs is used up. It can run again at ${clock(until)}.`
    }
    if (lastDay.length >= routine.maxRunsPerDay) {
      const until = lastDay[0] + DAY_MS
      return `Its daily ceiling of ${routine.maxRunsPerDay} runs is used up. It can run again at ${clock(until)}.`
    }

    const ceiling = this.options.globalMaxRunsPerHour?.() ?? DEFAULT_GLOBAL_MAX_RUNS_PER_HOUR
    let across = 0
    for (const id of this.entries.keys()) {
      across += this.runtime.get(id).runs.filter((at) => at > now - HOUR_MS).length
    }
    if (across >= ceiling) {
      return `Every routine together has already run ${across} times this hour, which is this app's ceiling.`
    }
    return null
  }

  private refuse(entry: Entry, cause: RoutineCause, reason: string): RunRequestResult {
    this.log({
      action: 'routine.skip',
      routine: entry.id,
      outcome: 'refused',
      detail: reason,
      data: { cause: cause.kind },
    })
    return { started: false, reason }
  }

  /**
   * The tool caller one run is given: the app's unattended surface, wrapped so
   * that a refusal lands in the routine's record on its way back to the model.
   *
   * The wrap is the point. `DeckControl.unattended()` already refuses alter-tier
   * calls with `not-permitted-unattended` and already writes a row into
   * `log/actions.jsonl`, so the model is answered correctly and the audit trail
   * is complete without any of this. What is missing without it is the thing the
   * *person* needs: the action log is a flat chronological file of every tool
   * call the copilot has ever made, and finding the two lines in it that explain
   * why last night's routine produced nothing means knowing to look. Attaching
   * the refusal to the routine puts the explanation where the question is asked.
   *
   * Only refusals are recorded, not every call. A routine that reads forty
   * things and writes none is working exactly as intended, and a per-routine
   * copy of the whole action log would be the second store this feature has
   * spent two modules avoiding.
   */
  private callerFor(routineId: string, runId: string): ToolCaller | null {
    const control = this.control
    if (control === null) return null
    return {
      call: async (name, args, signal) => {
        const result = await control.call(name, args, signal)
        if (result.refusal !== null) this.rememberRefusal(routineId, runId, result.row.tool, result.refusal)
        return result
      },
    }
  }

  private rememberRefusal(routineId: string, runId: string, tool: string, reason: string): void {
    const refusal: RoutineRefusal = { at: this.now(), tool, reason, runId }
    // Written through rather than debounced. The case this record exists for is
    // the overnight one, and an overnight run is exactly the kind of process
    // that is still going when the laptop lid closes on it.
    this.runtime.update(routineId, (runtime) => noteRefusal(runtime, refusal), true)
    this.log({
      action: 'routine.refused',
      routine: routineId,
      runId,
      outcome: 'refused',
      detail:
        reason === 'not-permitted-unattended'
          ? `${tool} needs a person to confirm it, and nothing was watching this run.`
          : `${tool} was refused: ${reason}.`,
      data: { tool, reason },
    })
  }

  /**
   * Actually run it. Everything that could have stopped it already has.
   *
   * Named apart from {@link RoutineEngine.start} deliberately — that one starts
   * the *engine* and this one starts a *run*, and a class where the same verb
   * means two things at two scales is a class somebody calls the wrong one of.
   */
  private async beginRun(
    entry: Entry,
    cause: RoutineCause,
    chain: readonly string[],
    runId = randomUUID(),
  ): Promise<void> {
    const routine = entry.routine
    const runner = this.runner
    if (routine === null || runner === null) return

    const startedAt = this.now()
    const controller = new AbortController()
    const handle: RunHandle = { runId, startedAt, cause, chain, controller, cancelling: false }
    entry.running = handle

    const nextChain = [...chain, routine.id]
    if (this.runs.size >= MAX_TRACKED_RUNS) {
      const oldest = this.runs.keys().next()
      if (!oldest.done) this.runs.delete(oldest.value)
    }
    this.runs.set(runId, { routineId: routine.id, chain: nextChain })

    // Written through rather than debounced: this is the number the budget is
    // computed from, and the case it exists for is the one where the process
    // does not get to shut down cleanly.
    this.runtime.update(entry.id, (runtime) => {
      runtime.runs.push(startedAt)
    }, true)

    this.log({
      action: 'routine.run',
      routine: entry.id,
      runId,
      outcome: 'started',
      detail: describeCause(cause),
      data: { chain: nextChain, folder: routine.folder },
    })

    let outcome: RoutineRunOutcome
    try {
      outcome = await runner.run({
        routine,
        runId,
        cause,
        chain: nextChain,
        signal: controller.signal,
        attended: false,
        control: this.callerFor(routine.id, runId),
      })
    } catch (error) {
      outcome = { ok: false, error: error instanceof Error ? error.message : String(error) }
    }

    for (const sessionId of outcome.sessionIds ?? []) {
      const session = this.sessions.get(sessionId)
      if (session) {
        session.routineId = routine.id
        session.runId = runId
      } else {
        this.sessions.set(sessionId, { cwd: routine.folder, routineId: routine.id, runId })
      }
    }

    const finishedAt = this.now()
    this.runtime.update(
      entry.id,
      (runtime) => {
        runtime.lastFinishedAt = finishedAt
        runtime.lastOutcome = outcome.ok ? 'ok' : 'failed'
        runtime.lastError = outcome.ok ? null : (outcome.error ?? 'The run failed.').slice(0, 500)
        runtime.consecutiveFailures = outcome.ok ? 0 : runtime.consecutiveFailures + 1
      },
      true,
    )

    this.log({
      action: 'routine.run',
      routine: entry.id,
      runId,
      outcome: outcome.ok ? 'ok' : 'failed',
      detail: outcome.ok ? undefined : outcome.error,
      data: { ms: finishedAt - startedAt, sessions: outcome.sessionIds ?? [] },
    })

    if (entry.running?.runId === runId) entry.running = null
    if (entry.cancelTimer !== null) {
      this.clearTimer(entry.cancelTimer)
      entry.cancelTimer = null
    }

    const failures = this.runtime.get(entry.id).consecutiveFailures
    if (failures >= MAX_CONSECUTIVE_FAILURES) {
      // The cheapest infinite loop there is. Stopped, and stopped visibly.
      entry.pending = null
      this.pause(
        entry.id,
        `Stopped after ${failures} failures in a row. The last one said: ${
          this.runtime.get(entry.id).lastError ?? 'nothing'
        }`,
      )
      return
    }

    const pending = entry.pending
    entry.pending = null
    if (pending && !this.stopped && entry.armed) {
      // Straight into the gates again rather than into `start`: a pending run
      // still has to pass the ceilings, which the run that just finished may
      // have used up.
      this.fire(entry, pending.cause, pending.chain)
    }
  }

  /* -------------------------------------------------------------- schedule */

  /**
   * One timer, for the earliest due routine.
   *
   * Not one per routine, and emphatically not an interval. Re-armed on every
   * reload, every fire and every wake, so it always points at the next thing
   * that is actually due.
   */
  private rearmSchedule(): void {
    if (this.scheduleTimer !== null) {
      this.clearTimer(this.scheduleTimer)
      this.scheduleTimer = null
    }
    if (this.stopped) return

    let earliest: number | null = null
    for (const entry of this.entries.values()) {
      if (!entry.armed || entry.nextDueAt === null) continue
      if (earliest === null || entry.nextDueAt < earliest) earliest = entry.nextDueAt
    }
    if (earliest === null) return

    const delay = Math.max(0, earliest - this.now())
    this.scheduleTimer = this.setTimer(
      () => {
        this.scheduleTimer = null
        this.fireDueSchedules()
        this.rearmSchedule()
      },
      // Chunked, because `setTimeout` past 2^31-1 ms fires immediately — which
      // for a weekly routine would be a run every tick of the event loop.
      Math.min(delay, MAX_TIMEOUT_MS),
    )
  }

  private fireDueSchedules(): void {
    const now = this.now()
    for (const entry of this.entries.values()) {
      const routine = entry.routine
      if (!entry.armed || routine === null) continue
      if (entry.nextDueAt === null || entry.nextDueAt > now) continue

      const dueAt = entry.nextDueAt
      const missed = entry.missedWhileClosed
      entry.missedWhileClosed = 0
      entry.scheduleAnchor = dueAt
      entry.nextDueAt = null
      for (const trigger of routine.triggers) {
        if (trigger.kind !== 'schedule') continue
        const next = nextDue(trigger.schedule, now, entry.scheduleAnchor)
        entry.nextDueAt = entry.nextDueAt === null ? next : Math.min(entry.nextDueAt, next)
      }
      this.touchSource('schedule')
      this.fire(entry, { kind: 'schedule', dueAt, missed }, [], { ignoreQuiet: true })
    }
  }

  /* ----------------------------------------------------------- what it says */

  /** Every routine, with enough state that nobody has to guess. */
  list(): RoutineView[] {
    const now = this.now()
    const sources = this.sourceViews()
    return [...this.entries.values()]
      .sort((a, b) => a.id.localeCompare(b.id))
      .map((entry) => this.view(entry, now, sources))
  }

  get(id: string): RoutineView | null {
    const entry = this.entries.get(id)
    return entry ? this.view(entry, this.now(), this.sourceViews()) : null
  }

  private sourceViews(): TriggerSourceView[] {
    return ALL_TRIGGER_KINDS.map((kind) => {
      const state = this.sources.get(kind)
      return {
        kind,
        subscribed: state?.subscribed ?? false,
        lastEventAt: state?.lastEventAt ?? null,
        events: state?.events ?? 0,
        note: state?.note ?? null,
      }
    })
  }

  private view(entry: Entry, now: number, sources: TriggerSourceView[]): RoutineView {
    const routine = entry.routine
    const runtime = this.runtime.get(entry.id)
    const runsLastHour = runtime.runs.filter((at) => at > now - HOUR_MS).length
    const runsLastDay = runtime.runs.filter((at) => at > now - DAY_MS).length
    const lastRunAt = runtime.runs.length > 0 ? runtime.runs[runtime.runs.length - 1] : null
    const kinds = new Set((routine?.triggers ?? []).map((trigger) => trigger.kind))
    const mine = sources.filter((source) => kinds.has(source.kind))

    const { state, reason, pausedUntil } = this.health(entry, routine, now, runtime.pausedReason, mine)

    return {
      id: entry.id,
      name: routine?.name ?? entry.id,
      file: entry.file,
      folder: routine?.folder ?? null,
      triggers: (routine?.triggers ?? []).map(serializeTrigger),
      prompt: routine?.prompt ?? '',
      enabled: routine?.enabled ?? false,
      overlap: routine?.overlap ?? null,
      state,
      reason,
      problems: entry.problems,
      warnings: entry.warnings,
      lastFiredAt: runtime.lastFiredAt,
      lastRunAt,
      lastFinishedAt: runtime.lastFinishedAt,
      lastOutcome: runtime.lastOutcome,
      lastError: runtime.lastError,
      consecutiveFailures: runtime.consecutiveFailures,
      // Copied rather than handed out by reference: a view is a snapshot a
      // window holds on to, and the live array keeps being appended to.
      refusedCalls: [...runtime.refusals],
      running: entry.running !== null,
      pending: entry.pending !== null,
      runsLastHour,
      runsLastDay,
      firesLastHour: entry.fires.filter((at) => at > now - HOUR_MS).length,
      maxRunsPerHour: routine?.maxRunsPerHour ?? null,
      maxRunsPerDay: routine?.maxRunsPerDay ?? null,
      pausedUntil,
      nextDueAt: entry.nextDueAt,
      missedWhileClosed: entry.missedWhileClosed,
      sources: mine,
    }
  }

  /**
   * The one question a person actually has: is this thing working?
   *
   * Every branch below is a fact, and the order is by how much it matters. The
   * `stale` branch at the bottom is the only derived one, and it exists because
   * a routine that has quietly stopped firing is indistinguishable from one
   * whose trigger genuinely has not happened — unless the routine said in
   * advance how long its silences are allowed to be.
   */
  private health(
    entry: Entry,
    routine: Routine | null,
    now: number,
    pausedReason: string | null,
    sources: TriggerSourceView[],
  ): { state: RoutineStateName; reason: string | null; pausedUntil: number | null } {
    if (routine === null) {
      return { state: 'broken', reason: entry.problems[0] ?? 'This routine could not be read.', pausedUntil: null }
    }
    if (entry.running !== null) return { state: 'running', reason: null, pausedUntil: null }
    if (!routine.enabled) {
      return { state: 'disabled', reason: 'Turned off in its file (`enabled: no`).', pausedUntil: null }
    }
    if (pausedReason !== null) return { state: 'paused', reason: pausedReason, pausedUntil: null }

    const budget = this.budgetProblem(routine, now)
    if (budget !== null) {
      const runtime = this.runtime.get(entry.id)
      const lastHour = runtime.runs.filter((at) => at > now - HOUR_MS)
      return {
        state: 'paused',
        reason: budget,
        pausedUntil: lastHour.length > 0 ? lastHour[0] + HOUR_MS : null,
      }
    }
    if (!entry.armed) {
      return { state: 'unarmed', reason: entry.armProblem ?? 'Not armed.', pausedUntil: null }
    }

    // Armed, and something it depends on has never said a word. This is the
    // half that stops "quiet" and "broken" looking the same.
    const dead = sources.find((source) => !source.subscribed)
    if (dead) {
      return {
        state: 'unarmed',
        reason: dead.note ?? `Nothing is subscribed to \`${dead.kind}\` in this build.`,
        pausedUntil: null,
      }
    }

    if (routine.expectEveryMs !== null) {
      const runtime = this.runtime.get(entry.id)
      const since = runtime.lastFiredAt
      if (since === null || now - since > routine.expectEveryMs) {
        return {
          state: 'stale',
          reason:
            since === null
              ? 'This routine has never fired, and it said it expected to by now.'
              : `Nothing has fired this routine since ${clock(since)}, and it said it expected to by now.`,
          pausedUntil: null,
        }
      }
    }

    return { state: 'armed', reason: null, pausedUntil: null }
  }
}

/* --------------------------------------------------------------- helpers */

/**
 * Glob matching for `file-change`.
 *
 * `picomatch` is already a dependency, and a bespoke matcher would be a second
 * set of edge cases to get wrong — `deckignore.ts` makes the same argument in
 * the other direction, where picomatch is the wrong tool because gitignore
 * semantics are not glob semantics. Here they are exactly glob semantics: a
 * routine says `src/**` and means what every other tool means by it.
 *
 * Compiled matchers are cached because a file watcher on a busy tree calls this
 * once per event, and compiling a pattern per event is the sort of cost that
 * only shows up on somebody else's large repository.
 */
const matchers = new Map<string, (input: string) => boolean>()

function matchesGlob(glob: string, path: string): boolean {
  let matcher = matchers.get(glob)
  if (!matcher) {
    matcher = picomatch(glob, { dot: true })
    // Bounded for the same reason everything else here is: the pattern comes
    // from a file anybody can edit, and a cache keyed on it is a cache keyed on
    // untrusted input.
    if (matchers.size > 200) matchers.clear()
    matchers.set(glob, matcher)
  }
  return matcher(path.split(sep).join('/'))
}

function clock(at: number): string {
  const date = new Date(at)
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

/** One sentence for the action log, from the cause. */
export function describeCause(cause: RoutineCause): string {
  switch (cause.kind) {
    case 'manual':
      return cause.by === 'copilot' ? 'The copilot asked for it.' : 'You asked for it.'
    case 'session-finished':
      return `Session ${cause.sessionId.slice(0, 8)} finished.`
    case 'session-failed':
      return `Session ${cause.sessionId.slice(0, 8)} exited with code ${cause.exitCode}.`
    case 'session-idle':
      return `Session ${cause.sessionId.slice(0, 8)} went quiet.`
    case 'alert':
      return `A ${cause.severity} alert appeared: ${cause.title}`
    case 'git-change':
      return 'The git status of the folder changed.'
    case 'file-change':
      return `${cause.path} changed.`
    case 'schedule':
      return cause.missed > 0
        ? `It came due, and it came due ${cause.missed} more time${cause.missed === 1 ? '' : 's'} while the app was closed.`
        : 'It came due.'
  }
}
