import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { BRAND } from '../../shared/brand'
import { STAYS_FIXED } from '../../shared/stays-fixed'
import { agentLaunch, type AgentLaunch } from './agents'
import {
  CHECK_SCRIPT,
  DESCRIBE_SCRIPT,
  EngineRunner,
  ensureNodeShim,
  lastJson,
  type EngineHome,
  type NoEngine,
  type RunResult,
  type Spawner,
} from './engine'
import { agentsOn, openPrefs, type StaysFixedPrefs } from './prefs'
import {
  lastRunFromFile,
  picturesFor,
  readinessFromDoctor,
  readinessFromPlan,
  toDescription,
  toMarkOutcome,
  toResults,
  toSetupOutcome,
  type FixedDescription,
  type FixedMarkOutcome,
  type FixedReadiness,
  type FixedResults,
  type FixedSetupOutcome,
} from './read'
import { configFileIn, setUpRootFor } from './where'

/**
 * Stays Fixed for one machine: set up, check, results, mark good, and the
 * agents' switch — the one object the page, the tools and the session launcher
 * all go through.
 *
 * ## One of everything
 *
 * One check per project at a time. A second request while one runs — the page's
 * button pressed again, Hoot asked, an outside AI calling `fixed.check` — joins
 * the run already going and gets its answer, rather than starting a second
 * engine over the same folder: two checks of one project would fight over the
 * same scratch copies, ports and store, which is exactly what Stays Fixed's
 * "sequential, never simultaneous" rule exists to prevent.
 *
 * One answer for "how did the last check go": the engine's own record,
 * `.staysfixed/v2/last-check.json`, which it writes for **every** check — this
 * page's, an agent's over MCP, a person's at a terminal. Reading that rather
 * than remembering our own run is what makes the page tell the truth about a
 * check an agent ran five minutes ago. The only thing this app adds is the
 * pictures, which only its own runs keep (see `engine.ts`), and a run the
 * person stopped, which the engine never records.
 */

/** Longest a check may run before it is stopped. A paired website check with a slow build is minutes. */
export const CHECK_TIMEOUT_MS = 20 * 60_000
/** Longest the machine survey (`doctor`, `init`) may take. It probes simulators and emulators. */
export const SURVEY_TIMEOUT_MS = 2 * 60_000
/** Longest marking a build as good may take. It reads the store and writes one record. */
export const MARK_TIMEOUT_MS = 60_000
/** Longest reading the guards may take. They are the person's own JavaScript. */
export const DESCRIBE_TIMEOUT_MS = 30_000
/** How long a machine survey is trusted. Installing a browser is the thing that changes it. */
export const READINESS_TTL_MS = 10 * 60_000
/** How long a project's guards and known-good build are trusted before they are read again. */
export const DESCRIBE_TTL_MS = 30_000
/** Runs whose pictures are kept, per project. Older pictures are deleted. */
export const KEEP_RUNS = 3
/** Largest picture handed to the window. A full-page screenshot of a long page can be huge. */
export const MAX_PICTURE_BYTES = 3 * 1024 * 1024

/* ----------------------------------------------------------------- types -- */

export interface FixedPicture {
  journey: string
  /** `data:image/png;base64,…`, or null when that side was not kept. */
  before: string | null
  after: string | null
}

export interface FixedShownResults extends FixedResults {
  /** Pictures by difference id. Only this app's own runs have any. */
  pictures: Record<string, FixedPicture[]>
}

export interface FixedProgress {
  startedAt: number
  /** What the engine said it is doing, in its words. */
  step: string
  /** How many steps it has reported so far. */
  steps: number
  /** Who asked: `you`, the assistant's name, or an AI app's. */
  by: string
}

export interface StaysFixedStatus {
  projectPath: string
  /** The engine is in this build. */
  available: boolean
  /** Why not, in a sentence, when it is not. */
  unavailable: string | null
  /** Empty unless the engine in this build is not the version the app was made for. */
  versionNote: string
  setUp: boolean
  /** Project-relative. */
  configFile: string | null
  git: boolean
  /** "Give agents Stays Fixed", as it stands. */
  agents: boolean
  guards: FixedDescription['guards']
  guardProblem: string | null
  /** The build marked as good, or null. */
  reference: FixedDescription['reference']
  /** The last check anybody ran here, or null. */
  last: FixedShownResults | null
  running: FixedProgress | null
}

export interface StaysFixedDeps {
  userData: string
  locate(): EngineHome | NoEngine
  /** This app's executable. */
  executable: string
  loginPath(): Promise<string>
  /** Something about this project changed — a step of a check, a result, a switch. */
  changed(projectPath: string): void
  spawn?: Spawner
  now?(): number
  home?: string
  platform?: NodeJS.Platform
}

interface Running {
  promise: Promise<FixedShownResults>
  controller: AbortController
  progress: FixedProgress
}

/* --------------------------------------------------------------- helpers -- */

function slug(path: string): string {
  return createHash('sha256').update(resolve(path)).digest('hex').slice(0, 16)
}

function gitIn(folder: string): boolean {
  let at = resolve(folder)
  for (let depth = 0; depth < 32; depth++) {
    if (existsSync(join(at, '.git'))) return true
    const up = dirname(at)
    if (up === at) return false
    at = up
  }
  return false
}

/** The last few lines a failed run wrote, for the sentence that says why. */
function tail(text: string, lines = 4): string {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .slice(-lines)
    .join(' ')
}

function failure(result: RunResult, what: string): string {
  if (result.cancelled) return `You stopped ${what}.`
  if (result.timedOut) return `${what[0]?.toUpperCase()}${what.slice(1)} took too long and was stopped.`
  const said = tail(result.stderr)
  return said === '' ? `${what[0]?.toUpperCase()}${what.slice(1)} did not finish.` : said
}

/* --------------------------------------------------------------- service -- */

export class StaysFixedService {
  private readonly prefs: StaysFixedPrefs
  private readonly running = new Map<string, Running>()
  /** This app's own results that the engine never writes down: a stopped or failed run. */
  private readonly ownLast = new Map<string, FixedShownResults>()
  private readonly readinessCache = new Map<string, { at: number; value: FixedReadiness }>()
  private readonly describeCache = new Map<string, { at: number; value: FixedDescription }>()
  private readonly resultsCache = new Map<string, { stamp: string; value: FixedShownResults | null }>()
  private runner: EngineRunner | null = null
  private loginPathCache: string | null = null

  constructor(private readonly deps: StaysFixedDeps) {
    this.prefs = openPrefs(deps.userData)
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now()
  }

  private base(): string {
    return join(this.deps.userData, 'staysfixed')
  }

  /** The engine, found once and kept. Null with the sentence when there is none. */
  private engine(): { runner: EngineRunner } | { reason: string } {
    if (this.runner) return { runner: this.runner }
    const home = this.deps.locate()
    if (!home.ok) return { reason: home.reason }
    const shim = ensureNodeShim(join(this.base(), 'bin'), this.deps.executable, this.deps.platform)
    this.runner = new EngineRunner({
      home,
      executable: this.deps.executable,
      shim,
      path: async () => {
        this.loginPathCache ??= await this.deps.loginPath()
        return this.loginPathCache
      },
      spawn: this.deps.spawn,
    })
    return { runner: this.runner }
  }

  private requireRunner(): EngineRunner {
    const found = this.engine()
    if ('reason' in found) throw new Error(found.reason)
    return found.runner
  }

  /* ------------------------------------------------------------- status -- */

  async status(projectPath: string): Promise<StaysFixedStatus> {
    const root = resolve(projectPath)
    const found = this.engine()
    const config = configFileIn(root)
    const setUp = config !== null
    const description =
      setUp && 'runner' in found ? await this.describe(root, found.runner).catch(() => null) : null
    return {
      projectPath: root,
      available: 'runner' in found,
      unavailable: 'reason' in found ? found.reason : null,
      versionNote: 'runner' in found ? found.runner.home.versionNote : '',
      setUp,
      configFile: config === null ? null : config.slice(root.length + 1),
      git: gitIn(root),
      agents: agentsOn(this.prefs, root, setUp),
      guards: description?.guards ?? [],
      guardProblem: description?.guardProblem ?? null,
      reference: description?.reference ?? null,
      last: setUp ? this.results(root) : null,
      running: this.running.get(root)?.progress ?? null,
    }
  }

  private async describe(root: string, runner: EngineRunner): Promise<FixedDescription> {
    const cached = this.describeCache.get(root)
    if (cached && this.now() - cached.at < DESCRIBE_TTL_MS) return cached.value
    const result = await runner.script(DESCRIBE_SCRIPT, [root], { cwd: root, timeoutMs: DESCRIBE_TIMEOUT_MS })
    const value = toDescription(lastJson(result.stdout))
    this.describeCache.set(root, { at: this.now(), value })
    return value
  }

  /** What this machine can check here. Slow — it probes for simulators and browsers — so it is cached. */
  async readiness(projectPath: string, refresh = false): Promise<FixedReadiness> {
    const root = resolve(projectPath)
    const cached = this.readinessCache.get(root)
    if (!refresh && cached && this.now() - cached.at < READINESS_TTL_MS) return cached.value
    const runner = this.requireRunner()
    const setUp = configFileIn(root) !== null
    // A set-up project is asked about its own products (`init --dry-run`, which
    // writes nothing); a bare folder about the machine (`doctor`).
    const result = setUp
      ? await runner.cli(['init', '--dry-run', '--json'], { cwd: root, timeoutMs: SURVEY_TIMEOUT_MS })
      : await runner.cli(['doctor', '--json'], { cwd: root, timeoutMs: SURVEY_TIMEOUT_MS })
    const raw = lastJson(result.stdout)
    if (raw === null) throw new Error(failure(result, `looking at what ${STAYS_FIXED} can check here`))
    const value = setUp ? readinessFromPlan(raw) : readinessFromDoctor(raw)
    if (setUp) value.git = gitIn(root)
    this.readinessCache.set(root, { at: this.now(), value })
    return value
  }

  /* -------------------------------------------------------------- setup -- */

  async setup(projectPath: string): Promise<FixedSetupOutcome> {
    const root = resolve(projectPath)
    const runner = this.requireRunner()
    const result = await runner.cli(['init', '--json'], { cwd: root, timeoutMs: SURVEY_TIMEOUT_MS })
    const raw = lastJson(result.stdout)
    const outcome = toSetupOutcome(raw ?? {}, [root, realPath(root)], raw === null ? failure(result, 'setting up') : null)
    this.readinessCache.delete(root)
    this.describeCache.delete(root)
    if (outcome.readiness) this.readinessCache.set(root, { at: this.now(), value: { ...outcome.readiness, git: gitIn(root) } })
    this.deps.changed(root)
    return outcome
  }

  /* -------------------------------------------------------------- check -- */

  /** What a check of this project is doing right now, or null. */
  progress(projectPath: string): FixedProgress | null {
    return this.running.get(resolve(projectPath))?.progress ?? null
  }

  /**
   * Check the project, or join the check already running and get its answer.
   *
   * `by` is who asked, said on the page while it runs — "Hoot started this
   * check" is the difference between a person wondering why a spinner appeared
   * and knowing.
   */
  check(projectPath: string, by: string): Promise<FixedShownResults> {
    const root = resolve(projectPath)
    const going = this.running.get(root)
    if (going) return going.promise
    if (configFileIn(root) === null) {
      return Promise.reject(new Error(`This project is not set up for ${STAYS_FIXED} yet. Set it up first.`))
    }
    const runner = this.requireRunner()
    const controller = new AbortController()
    const progress: FixedProgress = { startedAt: this.now(), step: 'Starting the check.', steps: 0, by }
    const promise = this.runCheck(root, runner, controller, progress).finally(() => {
      this.running.delete(root)
      this.describeCache.delete(root)
      this.deps.changed(root)
    })
    this.running.set(root, { promise, controller, progress })
    this.deps.changed(root)
    return promise
  }

  private async runCheck(
    root: string,
    runner: EngineRunner,
    controller: AbortController,
    progress: FixedProgress,
  ): Promise<FixedShownResults> {
    const projectPictures = join(this.base(), 'pictures', slug(root))
    const pending = join(projectPictures, `pending-${this.now()}`)
    const options = {
      cwd: root,
      signal: controller.signal,
      timeoutMs: CHECK_TIMEOUT_MS,
      keepPictures: pending,
      onEvent: (event: { message: string }) => {
        if (event.message !== '') progress.step = event.message
        progress.steps += 1
        this.deps.changed(root)
      },
    }
    let result = await runner.script(CHECK_SCRIPT, [root, 'stored'], options)
    let raw = lastJson(result.stdout)
    if (raw !== null && typeof raw.unsupported === 'string' && !result.cancelled) {
      // This copy of the engine keeps its modules somewhere else; the published
      // command gives the same answer without the steps.
      progress.step = 'Checking.'
      result = await runner.cli(['check', '--json'], options)
      raw = lastJson(result.stdout)
    }

    if (raw === null || result.cancelled || result.timedOut) {
      rmSync(pending, { recursive: true, force: true })
      const shown: FixedShownResults = {
        ...toResults({ error: { message: failure(result, 'the check') } }, new Date(progress.startedAt).toISOString()),
        pictures: {},
      }
      this.ownLast.set(root, shown)
      return shown
    }

    const results = toResults(raw)
    const runFolder = results.runId === '' ? null : join(projectPictures, results.runId)
    if (runFolder !== null && existsSync(pending)) {
      try {
        rmSync(runFolder, { recursive: true, force: true })
        renameSync(pending, runFolder)
      } catch {
        /* the pictures are a courtesy */
      }
    } else {
      rmSync(pending, { recursive: true, force: true })
    }
    this.prune(projectPictures)
    this.resultsCache.delete(root)
    const shown = this.withPictures(root, results, raw)
    if (shown.verdict === 'could-not-run') this.ownLast.set(root, shown)
    else this.ownLast.delete(root)
    return shown
  }

  /** Stop the running check. Stays Fixed's own tidy-up runs first (`SIGTERM`). */
  stop(projectPath: string): boolean {
    const going = this.running.get(resolve(projectPath))
    if (!going) return false
    going.progress.step = 'Stopping.'
    going.controller.abort()
    this.deps.changed(resolve(projectPath))
    return true
  }

  /** Wait up to `ms` for a running check; the last results either way. */
  async waitFor(projectPath: string, ms: number): Promise<FixedShownResults | null> {
    const going = this.running.get(resolve(projectPath))
    if (going && ms > 0) {
      let timer: ReturnType<typeof setTimeout> | null = null
      await Promise.race([
        going.promise.catch(() => null),
        new Promise((done) => {
          timer = setTimeout(done, ms)
        }),
      ])
      if (timer) clearTimeout(timer)
    }
    return this.results(projectPath)
  }

  /* ------------------------------------------------------------ results -- */

  /**
   * The last check anybody ran here, with this app's pictures where it has them.
   *
   * `full` keeps every change of every difference rather than the first few,
   * for the full report.
   */
  results(projectPath: string, full = false): FixedShownResults | null {
    const root = resolve(projectPath)
    const own = this.ownLast.get(root) ?? null
    let fromDisk: FixedShownResults | null = null
    const file = join(root, '.staysfixed', 'v2', 'last-check.json')
    try {
      // Kept until the engine rewrites the file. The page asks for the status on
      // every step of a running check, and each answer carries the last run's
      // pictures; reading and encoding them twenty times for one check would be
      // megabytes of work to say the same thing.
      const stamp = `${statSync(file).mtimeMs}:${full ? 'full' : 'short'}`
      const cached = this.resultsCache.get(root)
      if (cached && cached.stamp === stamp) {
        fromDisk = cached.value
      } else {
        const text = readFileSync(file, 'utf8')
        const record = JSON.parse(text) as { result?: unknown }
        const raw: unknown = typeof record.result === 'string' ? JSON.parse(record.result) : record.result
        const results = lastRunFromFile(text)
        if (results) fromDisk = this.withPictures(root, full ? toResults(raw, results.at, { full: true }) : results, raw)
        this.resultsCache.set(root, { stamp, value: fromDisk })
      }
    } catch {
      fromDisk = null
    }
    if (own && (!fromDisk || Date.parse(own.at) >= Date.parse(fromDisk.at))) return own
    return fromDisk
  }

  private withPictures(root: string, results: FixedResults, raw: unknown): FixedShownResults {
    const pictures: Record<string, FixedPicture[]> = {}
    const folder = results.runId === '' ? null : join(this.base(), 'pictures', slug(root), results.runId)
    if (folder !== null && existsSync(folder)) {
      let files: string[] = []
      try {
        files = readdirSync(folder)
      } catch {
        files = []
      }
      const verdict = (typeof raw === 'object' && raw !== null ? raw : {}) as {
        candidate?: { id?: unknown }
        reference?: { id?: unknown }
      }
      const candidateId = typeof verdict.candidate?.id === 'string' ? verdict.candidate.id : ''
      const referenceId = typeof verdict.reference?.id === 'string' && verdict.reference.id !== '' ? verdict.reference.id : null
      for (const difference of results.differences) {
        const found = picturesFor(difference, files, candidateId, referenceId).map((entry) => ({
          journey: entry.journey,
          before: entry.before === null ? null : dataUrl(join(folder, entry.before)),
          after: entry.after === null ? null : dataUrl(join(folder, entry.after)),
        }))
        const usable = found.filter((entry) => entry.before !== null || entry.after !== null)
        if (usable.length > 0) pictures[difference.id] = usable
      }
    }
    return { ...results, pictures }
  }

  private prune(projectPictures: string): void {
    try {
      const runs = readdirSync(projectPictures)
        .filter((name) => !name.startsWith('pending-'))
        .map((name) => ({ name, at: statSync(join(projectPictures, name)).mtimeMs }))
        .sort((a, b) => b.at - a.at)
      for (const old of runs.slice(KEEP_RUNS)) rmSync(join(projectPictures, old.name), { recursive: true, force: true })
    } catch {
      /* nothing kept yet */
    }
  }

  /* ---------------------------------------------------------- mark good -- */

  /**
   * Make the build that was last checked the one every later check compares
   * against — Stays Fixed's `ship`, said the way a person says it.
   *
   * `anyway` is the person accepting differences the last check found. It is
   * honoured **only** for that refusal: a build that was never checked, or
   * whose check could not run, is never forced, because that would make a
   * build nobody looked at the definition of working — the one outcome the
   * engine exists to refuse. So the first ask is always unforced, and the force
   * is added only when the refusal it would override is the differences one.
   */
  async markGood(projectPath: string, anyway: boolean): Promise<FixedMarkOutcome> {
    const root = resolve(projectPath)
    const runner = this.requireRunner()
    if (this.running.has(root)) {
      return { ok: false, marked: false, already: false, refused: null, refusedFor: null, summary: 'A check is running. Mark the build as good once it has finished.' }
    }
    const why = `Marked as good in ${BRAND.name}`
    const ask = async (force: boolean): Promise<FixedMarkOutcome> => {
      const result = await runner.cli(['ship', '--why', why, '--json', ...(force ? ['--force'] : [])], {
        cwd: root,
        timeoutMs: MARK_TIMEOUT_MS,
      })
      const raw = lastJson(result.stdout)
      return toMarkOutcome(raw ?? {}, raw === null ? failure(result, 'marking the build as good') : null)
    }
    let outcome = await ask(false)
    if (anyway && outcome.refusedFor === 'differences') outcome = await ask(true)
    this.describeCache.delete(root)
    this.deps.changed(root)
    return outcome
  }

  /* ------------------------------------------------------------- agents -- */

  async setAgents(projectPath: string, on: boolean): Promise<StaysFixedStatus> {
    const root = resolve(projectPath)
    this.prefs.setAgents(root, on)
    this.deps.changed(root)
    return this.status(root)
  }

  /**
   * What an agent session started in `cwd` is launched with, or null.
   *
   * The project is the nearest set-up folder at or above `cwd`; the switch is
   * that project's. Null whenever anything is missing, which launches the
   * session exactly as it would have been launched without this feature.
   */
  async agentLaunch(provider: string, cwd: string): Promise<AgentLaunch | null> {
    const root = setUpRootFor(cwd, { home: this.deps.home })
    if (root === null || !agentsOn(this.prefs, root, true)) return null
    const found = this.engine()
    if ('reason' in found) return null
    this.loginPathCache ??= await this.deps.loginPath()
    return agentLaunch(provider, root, {
      home: found.runner.home,
      executable: this.deps.executable,
      shim: ensureNodeShim(join(this.base(), 'bin'), this.deps.executable, this.deps.platform),
      loginPath: this.loginPathCache,
      dir: join(this.base(), 'agents'),
      platform: this.deps.platform,
    })
  }

  /** Stop every running check. For the app quitting. */
  dispose(): void {
    for (const going of this.running.values()) going.controller.abort()
  }
}

function realPath(path: string): string {
  try {
    return realpathSync.native(path)
  } catch {
    return path
  }
}

function dataUrl(file: string): string | null {
  try {
    if (statSync(file).size > MAX_PICTURE_BYTES) return null
    return `data:image/png;base64,${readFileSync(file).toString('base64')}`
  } catch {
    return null
  }
}
