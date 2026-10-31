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

import { sep } from 'node:path'
import { unattendedMcpConfigPath } from '../deck-control'
import { currentEndpoint } from '../deck-control/server'
import { userDataDir } from '../platform/paths'
import { store as appStore } from '../store'
import { chooseSeedFolder, seedDefaultRoutines } from './defaults'
import { defaultRoutineLogger, type RoutineLogger } from './log'
import {
  RoutineEngine,
  type RoutineEngineOptions,
  type RoutineRunner,
} from './engine'
import type { RoutineRefusal } from './runtime-state'
import { RoutineApi } from './ipc'
import { createCopilotRunner } from './runner'
import { RoutineFileWatchers, watchGitFolder } from './sources'
import { RoutineStore } from './store'
import { RuntimeState } from './runtime-state'

export interface CreateRoutinesOptions {
  /** Defaults to `<userData>/routines`. */
  dir?: string
  /**
   * What performs a routine's prompt. Defaults to a real copilot run.
   *
   * It used to default to `null`, and `src/main/index.ts` explained why: there
   * was nothing on the other end of the triggers, and every routine reported
   * itself unarmed with that sentence attached. `runner.ts` is that other end,
   * so the default is now the real thing — and it defaults rather than being
   * required, because a shell that had to remember to pass it is a shell that
   * would ship with the whole feature silently inert. That is precisely the
   * failure this repository keeps a paragraph about.
   *
   * Pass `null` explicitly to run with no runner: the engine then reports every
   * routine as unarmed, which is what the tests want and what a headless shell
   * with no Claude CLI should have.
   */
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
  /**
   * The folder the shipped default routines should watch, or null to skip them.
   *
   * Defaults to the project this app opened most recently, read from the store
   * — the same store `deck-control/live-surface.ts` reaches for directly and
   * for the same stated reason: a second copy of the project list handed in
   * from somewhere else is a place for two answers to the same question to
   * appear.
   *
   * Null on a fresh install with no projects yet, and then nothing is seeded
   * and nothing is marked as seeded, so the next launch tries again. See
   * `defaults.ts`.
   */
  seedFolder?(): string | null
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

  /*
   * The defaults go in before the engine reads the folder.
   *
   * `engine.start()` lists the directory and arms what is in it, so seeding
   * after that would mean the shipped routines are inert until the next launch
   * — which on a machine that is restarted once a week is a feature that
   * appears to be broken for a week. Seeding here, at assembly, means the first
   * `start()` finds them.
   *
   * Swallowed rather than thrown: a routines folder that could not be written
   * is a reason for the app to have no default routines, not a reason for the
   * app not to open.
   */
  try {
    seedDefaultRoutines(store.dir, seedFolderOf(options), {
      write: (id, contents) => store.saveText(id, contents),
      existing: () => store.list().map((entry) => entry.id),
    })
  } catch (error) {
    console.error('[routines] could not write the default routines:', error)
  }

  const engine = new RoutineEngine({
    store,
    runtime,
    log,
    /*
     * `undefined` means "give me the real one"; an explicit `null` means "run
     * with none". The distinction matters because most of the engine's own
     * tests want no runner at all, and `?? defaultRunner()` would have silently
     * given them a real one that spawns a CLI.
     */
    runner: options.runner === undefined ? defaultRunner() : options.runner,
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

/**
 * The runner a shell gets when it does not name one.
 *
 * `mcpConfig` is a function rather than a value on purpose. `deck-control`'s
 * server is started asynchronously during `whenReady`, and this assembly runs
 * at module scope before it — so a path captured here would be captured while
 * `currentEndpoint()` was still null, and every routine on the machine would
 * report "the deck-control server is not running" for the life of the process.
 * Asked per run, it is right by the time anything fires.
 *
 * The *unattended* config, always. See `runner.ts`: which token a run holds is
 * what makes its alter-tier calls refuse immediately instead of blocking on a
 * confirmation dialog nobody is awake to answer.
 */
function defaultRunner(): RoutineRunner {
  return createCopilotRunner({
    mcpConfig: () => (currentEndpoint() === null ? null : unattendedMcpConfigPath()),
  })
}

function seedFolderOf(options: CreateRoutinesOptions): string | null {
  if (options.seedFolder) return options.seedFolder()
  try {
    // `getProjects` already answers newest first, which is the folder somebody
    // is most likely to want watched. `chooseSeedFolder` owns the one thing
    // that has to be excluded from that answer, and says why.
    return chooseSeedFolder(appStore().getProjects(), userDataDir(), sep)
  } catch {
    // No platform paths installed yet, which happens in a test that builds a
    // store of its own. Nothing to seed against, and nothing worth failing for.
    return null
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
