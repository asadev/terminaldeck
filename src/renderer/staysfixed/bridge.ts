/**
 * What the Stays Fixed page reads from the main process, and the shapes it reads.
 *
 * The shapes mirror `src/main/staysfixed/read.ts` and `service.ts` field for
 * field. They are written again here rather than imported because the house
 * rule is that a feature's types cross the bridge as `unknown` and each side
 * keeps its own — and because the page has to survive a main process that is
 * older or newer than it, so everything that arrives goes through
 * {@link asStatus} and friends, which fill a missing field with the empty value
 * rather than letting `undefined.length` blank the page.
 */

/* ----------------------------------------------------------------- shapes -- */

export type FixedVerdict = 'clean' | 'differences' | 'not-compared' | 'could-not-run'

export interface FixedChange {
  what: string
  before: string | null
  after: string | null
  kind: 'changed' | 'appeared' | 'vanished'
}

export interface FixedDifference {
  id: string
  title: string
  needsPerson: boolean
  needsPersonWhy: string
  count: number
  changes: FixedChange[]
  more: number
}

export interface FixedPicture {
  journey: string
  before: string | null
  after: string | null
}

export interface FixedResults {
  runId: string
  at: string
  durationMs: number
  verdict: FixedVerdict
  headline: string
  against: string | null
  checked: string
  differences: FixedDifference[]
  unchanged: string
  notChecked: string | null
  unsteady: number
  detail: string
  gaps: Array<{ what: string; why: string; unlockedBy: string }>
  pictures: Record<string, FixedPicture[]>
}

export interface FixedProgress {
  startedAt: number
  step: string
  steps: number
  by: string
}

export interface FixedGuard {
  name: string
  because: string
}

export interface FixedReference {
  name: string
  setAt: string
  forced: boolean
}

export interface StaysFixedStatus {
  projectPath: string
  available: boolean
  unavailable: string | null
  versionNote: string
  setUp: boolean
  configFile: string | null
  git: boolean
  agents: boolean
  guards: FixedGuard[]
  guardProblem: string | null
  reference: FixedReference | null
  last: FixedResults | null
  running: FixedProgress | null
}

export interface FixedGap {
  name: string
  what: string
  why: string
  fix: string
  byPerson: boolean
  unlocks: string
}

export interface FixedReadiness {
  ready: string[]
  gaps: FixedGap[]
  notHere: string[]
  summary: string
  git: boolean | null
}

export interface FixedSetupOutcome {
  ok: boolean
  wrote: string[]
  problem: string | null
}

export interface FixedMarkOutcome {
  ok: boolean
  marked: boolean
  already: boolean
  refused: string | null
  refusedFor: 'differences' | 'unchecked' | null
  summary: string
}

/* ----------------------------------------------------------------- bridge -- */

/**
 * What this page needs from `window.deck`. The names are the preload's: the
 * contract test matches every `*Bridge` interface against what it exposes.
 */
export interface StaysFixedBridge {
  staysFixedStatus(projectPath: string): Promise<unknown>
  staysFixedReadiness(projectPath: string, refresh: boolean): Promise<unknown>
  staysFixedSetup(projectPath: string): Promise<unknown>
  staysFixedCheck(projectPath: string): Promise<unknown>
  staysFixedStop(projectPath: string): Promise<unknown>
  staysFixedResults(projectPath: string, full: boolean): Promise<unknown>
  staysFixedMarkGood(projectPath: string, anyway: boolean): Promise<unknown>
  staysFixedAgents(projectPath: string, on: boolean): Promise<unknown>
  onStaysFixedChanged(callback: (projectPath: string) => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof StaysFixedBridge> = [
  'staysFixedStatus',
  'staysFixedReadiness',
  'staysFixedSetup',
  'staysFixedCheck',
  'staysFixedStop',
  'staysFixedResults',
  'staysFixedMarkGood',
  'staysFixedAgents',
  'onStaysFixedChanged',
]

/**
 * The bridge as it exists, each method called through its host — for the
 * reason `PowerSection` gives: a preload whose functions sit on a prototype
 * throws on `this` the first time a button is pressed, and only in a packaged
 * build. `globalThis` so the page renders to a string in tests.
 */
export function resolveStaysFixedBridge(host?: unknown): Partial<StaysFixedBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const all = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof all[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown => (all[name] as (...a: unknown[]) => unknown).apply(all, args)
  }
  return bridge as Partial<StaysFixedBridge>
}

/* ------------------------------------------------------------- readers -- */

type Raw = Record<string, unknown>

function obj(value: unknown): Raw {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Raw) : {}
}
function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}
function str(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}
function strOrNull(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}
function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

const VERDICTS: readonly FixedVerdict[] = ['clean', 'differences', 'not-compared', 'could-not-run']

export function asResults(value: unknown): FixedResults | null {
  const v = obj(value)
  if (Object.keys(v).length === 0) return null
  const verdict = VERDICTS.find((one) => one === v.verdict) ?? 'could-not-run'
  const pictures: Record<string, FixedPicture[]> = {}
  for (const [id, list] of Object.entries(obj(v.pictures))) {
    pictures[id] = arr(list)
      .map(obj)
      .map((p) => ({ journey: str(p.journey), before: strOrNull(p.before), after: strOrNull(p.after) }))
  }
  return {
    runId: str(v.runId),
    at: str(v.at),
    durationMs: num(v.durationMs),
    verdict,
    headline: str(v.headline),
    against: strOrNull(v.against),
    checked: str(v.checked),
    differences: arr(v.differences)
      .map(obj)
      .map((d) => ({
        id: str(d.id),
        title: str(d.title),
        needsPerson: d.needsPerson === true,
        needsPersonWhy: str(d.needsPersonWhy),
        count: Math.max(1, num(d.count)),
        more: num(d.more),
        changes: arr(d.changes)
          .map(obj)
          .map((c) => ({
            what: str(c.what),
            before: strOrNull(c.before),
            after: strOrNull(c.after),
            kind: c.kind === 'appeared' || c.kind === 'vanished' ? c.kind : 'changed',
          })),
      })),
    unchanged: str(v.unchanged),
    notChecked: strOrNull(v.notChecked),
    unsteady: num(v.unsteady),
    detail: str(v.detail),
    gaps: arr(v.gaps)
      .map(obj)
      .map((g) => ({ what: str(g.what), why: str(g.why), unlockedBy: str(g.unlockedBy) })),
    pictures,
  }
}

export function asProgress(value: unknown): FixedProgress | null {
  const v = obj(value)
  if (Object.keys(v).length === 0) return null
  return { startedAt: num(v.startedAt), step: str(v.step), steps: num(v.steps), by: str(v.by, 'you') }
}

export function asStatus(value: unknown, projectPath: string): StaysFixedStatus {
  const v = obj(value)
  const reference = obj(v.reference)
  return {
    projectPath: str(v.projectPath, projectPath),
    available: v.available === true,
    unavailable: strOrNull(v.unavailable),
    versionNote: str(v.versionNote),
    setUp: v.setUp === true,
    configFile: strOrNull(v.configFile),
    git: v.git !== false,
    agents: v.agents === true,
    guards: arr(v.guards)
      .map(obj)
      .map((g) => ({ name: str(g.name), because: str(g.because) }))
      .filter((g) => g.name !== ''),
    guardProblem: strOrNull(v.guardProblem),
    reference:
      Object.keys(reference).length === 0
        ? null
        : { name: str(reference.name, 'a build'), setAt: str(reference.setAt), forced: reference.forced === true },
    last: asResults(v.last),
    running: asProgress(v.running),
  }
}

export function asReadiness(value: unknown): { readiness: FixedReadiness | null; message: string | null } {
  const v = obj(value)
  if (v.ok !== true) return { readiness: null, message: str(v.message, 'This could not be worked out.') }
  const r = obj(v.readiness)
  return {
    readiness: {
      ready: arr(r.ready).map((x) => str(x)).filter((x) => x !== ''),
      gaps: arr(r.gaps)
        .map(obj)
        .map((g) => ({
          name: str(g.name),
          what: str(g.what),
          why: str(g.why),
          fix: str(g.fix),
          byPerson: g.byPerson === true,
          unlocks: str(g.unlocks),
        })),
      notHere: arr(r.notHere).map((x) => str(x)).filter((x) => x !== ''),
      summary: str(r.summary),
      git: typeof r.git === 'boolean' ? r.git : null,
    },
    message: null,
  }
}

export function asSetup(value: unknown): FixedSetupOutcome {
  const v = obj(value)
  return {
    ok: v.ok === true,
    wrote: arr(v.wrote).map((x) => str(x)).filter((x) => x !== ''),
    problem: strOrNull(v.problem) ?? (v.ok === true ? null : 'Set up did not finish.'),
  }
}

export function asMark(value: unknown): FixedMarkOutcome {
  const v = obj(value)
  return {
    ok: v.ok === true,
    marked: v.marked === true,
    already: v.already === true,
    refused: strOrNull(v.refused),
    refusedFor: v.refusedFor === 'differences' || v.refusedFor === 'unchecked' ? v.refusedFor : null,
    summary: str(v.summary, 'It could not be marked.'),
  }
}

/** The check channel answers `{ ok, results }` or `{ ok: false, message }`. */
export function asCheck(value: unknown): { results: FixedResults | null; message: string | null } {
  const v = obj(value)
  if (v.ok === true) return { results: asResults(v.results), message: null }
  return { results: null, message: str(v.message, 'The check could not start.') }
}
