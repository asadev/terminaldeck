/**
 * Routines, assembled.
 *
 * One function, for the same reason `host-core.ts` is one function: the pieces
 * reference each other and the order matters, and handing a shell five
 * constructors and a page of assembly notes would be handing it five chances to
 * assemble them differently.
 *
 * ## What the shell has to do, and it is four lines
 *
 * ```ts
 * const routines = createRoutines({
 *   allowFolder: (folder) => …,          // a project this desktop has open
 *   globalMaxRunsPerHour: () => …,       // a setting the person owns
 * })
 * registerRoutinesIpc(ipcMain, routines.api)
 * routines.engine.start()
 * ```
 *
 * plus one more line **wherever `deck-control` is assembled**, which is after
 * this because that one is awaited:
 *
 * ```ts
 * const deckControl = await registerDeckControlIpc(ipcMain, { … })
 * routines.engine.setControl(deckControl.control.unattended())
 * ```
 *
 * `unattended()` is not a detail of that line, it is the line. A routine fires
 * with nobody at the machine, so every alter-tier tool call from a run has to be
 * refused at the boundary instead of waiting on a confirmation dialog that can
 * only time out — see `RoutineRunRequest.attended` and the
 * `not-permitted-unattended` refusal. `setControl` takes a `ToolCaller`, so
 * handing it the `DeckControl` itself does not typecheck; that is deliberate,
 * and it is the reason this is safe to write down as a recipe.
 *
 * plus the five places the existing emitters have to call in — listed on
 * {@link RoutinesHandle}, because a feature wired to a settings pane and not to
 * boot is the failure this repository has paid for most, and the way that
 * failure happens is a wiring note nobody read.
 */

import { defaultRoutineLogger, type RoutineLogger } from './log'
import {
  RoutineEngine,
  type RoutineEngineOptions,
  type RoutineRunner,
} from './engine'
import type { RoutineRefusal } from './runtime-state'
import { RoutineApi } from './ipc'
import { RoutineFileWatchers, watchGitFolder } from './sources'
import { RoutineStore } from './store'
import { RuntimeState } from './runtime-state'

export interface CreateRoutinesOptions {
  /** Defaults to `<userData>/routines`. */
  dir?: string
  runner?: RoutineRunner | null
  /**
   * The app's tool surface for runs to act through — **already unattended**.
   *
   * The shell passes `deckControl.control.unattended()`. Passing the
   * `DeckControl` itself will not typecheck, and that is the enforcement rather
   * than an inconvenience: a routine run has nobody who can answer a
   * confirmation, so the object it is given must be one that cannot ask for one.
   */
  control?: RoutineEngineOptions['control']
  allowFolder?: RoutineEngineOptions['allowFolder']
  globalMaxRunsPerHour?: RoutineEngineOptions['globalMaxRunsPerHour']
  now?: RoutineEngineOptions['now']
  /**
   * Which trigger sources this shell has actually hooked its callbacks up to.
   *
   * Nothing is assumed. A trigger this list does not name is reported as having
   * nothing subscribed to it, and every routine using it says so instead of
   * sitting there looking armed — because a routine that never fires because
   * nobody wired its emitter is precisely the failure that is impossible to
   * tell from a quiet week.
   *
   * It is a declaration rather than something detected, because there is
   * nothing to detect: a callback the shell forgot to pass is indistinguishable
   * from one that has simply not fired yet. Declaring it wrong is caught the
   * first time an event *does* arrive — the engine flips the source to live on
   * a real event and stops taking this list's word for it.
   */
  wired?: ReadonlyArray<Parameters<RoutineEngine['markSource']>[0]>
}

export interface RoutinesHandle {
  engine: RoutineEngine
  store: RoutineStore
  api: RoutineApi
  log: RoutineLogger
  /** Everything the engine holds open. Call on quit. */
  stop(): Promise<void>
}

export function createRoutines(options: CreateRoutinesOptions = {}): RoutinesHandle {
  const store = new RoutineStore(options.dir === undefined ? {} : { dir: options.dir })
  const runtime = new RuntimeState()
  const log = defaultRoutineLogger()
  const files = new RoutineFileWatchers()

  const engine = new RoutineEngine({
    store,
    runtime,
    log,
    runner: options.runner ?? null,
    control: options.control ?? null,
    ...(options.allowFolder ? { allowFolder: options.allowFolder } : {}),
    ...(options.globalMaxRunsPerHour ? { globalMaxRunsPerHour: options.globalMaxRunsPerHour } : {}),
    ...(options.now ? { now: options.now } : {}),
    watchFiles: (folder, onChange) => files.watch(folder, onChange),
    watchGit: (folder, onChange) => watchGitFolder(folder, onChange),
  })

  // These two are wired right here, so they are live by construction. The rest
  // depend on callbacks only the shell holds, and are live only if it says so.
  engine.markSource('file-change', true)
  engine.markSource('git-change', true)
  for (const kind of options.wired ?? []) engine.markSource(kind, true)

  return {
    engine,
    store,
    api: new RoutineApi(engine, store),
    log,
    stop: async () => {
      await engine.stop()
      await files.stop()
    },
  }
}

export { RoutineApi, registerRoutinesIpc } from './ipc'
export { RoutineEngine } from './engine'
export type {
  RoutineCause,
  RoutineRunner,
  RoutineRunRequest,
  RoutineRunOutcome,
  RoutineView,
  RunRequestResult,
  TriggerSourceView,
} from './engine'
export type { RoutineRefusal }
export { RoutineStore, copilotDir, routinesDir, routinesDirFor } from './store'
export { runtimeStateFileFor } from './runtime-state'
export type { Routine, RoutineDraft, Trigger } from './format'
export { routineLogger, defaultRoutineLogger } from './log'
export type { RoutineLogEntry, RoutineLogger } from './log'
