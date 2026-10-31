/**
 * The renderer's half of worker profiles and the session lift.
 *
 * Optional, every method of it, for the reason `accounts-bridge.ts` states at
 * length: `bridge.ts` refuses to resolve at all when a name in `BRIDGE_METHODS`
 * is missing, which is right for the methods the panel cannot draw a pixel
 * without and catastrophic for a new one — adding a name there would blank the
 * whole browser panel on every build whose preload predates it. This is the
 * fourth feature to take that shape.
 *
 * **There is no worker panel of its own any more.** This file is now the
 * narrowing layer under `scraping-adapter.ts`, which answers the Scraping
 * panel's Workers and Session sections out of these methods — one door to the
 * job, inside the ⋯ menu, which is where he asked for it. What used to be this
 * bridge's phrasing lives in `scraping-view.ts` with the rest of what that
 * panel is allowed to say.
 *
 * **Nothing here returns a cookie value or a stored key.** A lift answers with
 * counts, cookie *names* and the host it was taken from; the values stay in the
 * main process and are never written to disk at all. That is the rule
 * `browser-session.ts` set for the cookie panel — *"those values are session
 * tokens, the literal credentials"* — applied to the one feature that moves
 * them.
 */

/** Mirrors `PaceSettings` in `src/main/browser-worker-pool.ts`. */
export interface PaceSettings {
  maxConcurrent: number
  minDelayMs: number
  jitterMs: number
}

/** Mirrors `WorkerRow` in `src/main/browser-workers-ipc.ts`. */
export interface WorkerRow {
  profileId: string
  name: string
  partition: string
  busy: boolean
  holder: string
  heldMs: number
  readyInMs: number
  lastReleasedAt: number
  pages: { url: string; title: string }[]
  queued: { origin: string; keys: number }[]
}

/** Mirrors `LiftSummary` in `src/main/browser-session-lift.ts`. Note: no values. */
export interface LiftSummary {
  id: string
  takenAt: number
  expiresAt: number
  sourceProfileId: string
  sourceProfileName: string
  host: string
  origin: string
  cookieCount: number
  cookieNames: string[]
  cookieNamesTruncated: boolean
  localKeys: number
  sessionKeys: number
  storageTruncated: boolean
}

/** Mirrors `WorkersView` in `src/main/browser-workers-ipc.ts`. */
export interface WorkersView {
  workers: WorkerRow[]
  pace: PaceSettings
  paceNote: string
  lifts: LiftSummary[]
  canSeedStorage: boolean
  max: number
}

/** Mirrors `InjectReport` in `src/main/browser-session-lift.ts`. */
export interface InjectReport {
  profileId: string
  name: string
  cookiesSet: number
  cookiesRefused: number
  storageQueued: number
  note: string
}

export interface WorkersApi {
  browserWorkers?(): Promise<unknown>
  browserWorkersEnsure?(count: number): Promise<unknown>
  browserWorkerRegister?(profileId: string): Promise<unknown>
  browserWorkerUnregister?(profileId: string): Promise<unknown>
  browserWorkerPace?(pace: PaceSettings): Promise<unknown>
  browserWorkerLift?(request: { viewId: string }): Promise<unknown>
  browserWorkerInject?(request: { liftId: string; profileIds?: string[] }): Promise<unknown>
  browserWorkerForgetLift?(liftId: string): Promise<unknown>
  /*
   * The ask inbox — asks agents file, answers a person gives. See
   * `src/main/browser-lift-requests.ts` for the desk and its rules; the shapes
   * these carry are `scraping-bridge.ts`'s `LiftRequest` and `ScrapingOutcome`.
   */
  browserWorkerLiftRequests?(): Promise<unknown>
  browserWorkerLiftAnswer?(requestId: string, approve: boolean): Promise<unknown>
  onBrowserWorkerLiftRequest?(cb: (inbox: unknown) => void): () => void
}

const METHODS = [
  'browserWorkers',
  'browserWorkersEnsure',
  'browserWorkerRegister',
  'browserWorkerUnregister',
  'browserWorkerPace',
  'browserWorkerLift',
  'browserWorkerInject',
  'browserWorkerForgetLift',
  'browserWorkerLiftRequests',
  'browserWorkerLiftAnswer',
  'onBrowserWorkerLiftRequest',
] as const satisfies readonly (keyof WorkersApi)[]

export function resolveWorkersApi(host?: unknown): WorkersApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as WorkersApi
}

/**
 * Are workers wired in this build?
 *
 * List, mint and pace together. A panel that can list workers but not make one
 * is a screen that cannot act, and the honest answer to a half-wired preload is
 * not to offer the row at all.
 *
 * The lift is checked separately by {@link liftAvailable}, because a build with
 * workers and no lift is still a useful panel — it just draws no Lift button —
 * whereas a build with a Lift button that resolves to nothing is the dead
 * control this whole round is about.
 */
export function workersAvailable(api: WorkersApi): boolean {
  return (
    typeof api.browserWorkers === 'function' &&
    typeof api.browserWorkersEnsure === 'function' &&
    typeof api.browserWorkerPace === 'function'
  )
}

/** Both halves, or neither: lifting with no way to inject is a dead end. */
export function liftAvailable(api: WorkersApi): boolean {
  return typeof api.browserWorkerLift === 'function' && typeof api.browserWorkerInject === 'function'
}

/* ---------------------------------------------------------------- reading -- */

/**
 * Everything below validates a shape that came from this app's own main
 * process, which is not a trust boundary — it is the discipline every other
 * `unknown` on this side gets, and it is what makes an older or newer main
 * process a quiet no-op rather than a crash inside an effect.
 */

function str(record: Record<string, unknown>, key: string): string {
  const value = record[key]
  return typeof value === 'string' ? value : ''
}

function int(record: Record<string, unknown>, key: string): number {
  const value = record[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

export function readPace(raw: unknown): PaceSettings {
  const value = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  return {
    maxConcurrent: int(value, 'maxConcurrent'),
    minDelayMs: int(value, 'minDelayMs'),
    jitterMs: int(value, 'jitterMs'),
  }
}

export function readWorkersView(raw: unknown): WorkersView | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (!Array.isArray(value.workers)) return null
  const workers: WorkerRow[] = []
  for (const entry of value.workers) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    // A row with no id is a row nothing can be done to — a press that would go
    // nowhere. Dropped rather than drawn.
    if (typeof record.profileId !== 'string' || record.profileId === '') continue
    workers.push({
      profileId: record.profileId,
      name: str(record, 'name'),
      partition: str(record, 'partition'),
      busy: record.busy === true,
      holder: str(record, 'holder'),
      heldMs: int(record, 'heldMs'),
      readyInMs: int(record, 'readyInMs'),
      lastReleasedAt: int(record, 'lastReleasedAt'),
      pages: readPages(record.pages),
      queued: readQueued(record.queued),
    })
  }
  return {
    workers,
    pace: readPace(value.pace),
    paceNote: str(value, 'paceNote'),
    lifts: readLifts(value.lifts),
    canSeedStorage: value.canSeedStorage === true,
    max: int(value, 'max'),
  }
}

function readPages(raw: unknown): { url: string; title: string }[] {
  if (!Array.isArray(raw)) return []
  const out: { url: string; title: string }[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.url !== 'string' || record.url === '') continue
    out.push({ url: record.url, title: str(record, 'title') })
  }
  return out
}

function readQueued(raw: unknown): { origin: string; keys: number }[] {
  if (!Array.isArray(raw)) return []
  const out: { origin: string; keys: number }[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.origin !== 'string' || record.origin === '') continue
    out.push({ origin: record.origin, keys: int(record, 'keys') })
  }
  return out
}

export function readLifts(raw: unknown): LiftSummary[] {
  if (!Array.isArray(raw)) return []
  const out: LiftSummary[] = []
  for (const entry of raw) {
    const one = readLift(entry)
    if (one !== null) out.push(one)
  }
  return out
}

export function readLift(raw: unknown): LiftSummary | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (typeof value.id !== 'string' || value.id === '') return null
  return {
    id: value.id,
    takenAt: int(value, 'takenAt'),
    expiresAt: int(value, 'expiresAt'),
    sourceProfileId: str(value, 'sourceProfileId'),
    sourceProfileName: str(value, 'sourceProfileName'),
    host: str(value, 'host'),
    origin: str(value, 'origin'),
    cookieCount: int(value, 'cookieCount'),
    cookieNames: Array.isArray(value.cookieNames)
      ? value.cookieNames.filter((name): name is string => typeof name === 'string')
      : [],
    cookieNamesTruncated: value.cookieNamesTruncated === true,
    localKeys: int(value, 'localKeys'),
    sessionKeys: int(value, 'sessionKeys'),
    storageTruncated: value.storageTruncated === true,
  }
}

export type LiftAnswer =
  | { ok: true; summary: LiftSummary }
  | { ok: false; reason: string }

export function readLiftAnswer(raw: unknown): LiftAnswer {
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, reason: 'this build could not take a session from that page.' }
  }
  const value = raw as Record<string, unknown>
  if (value.ok === true) {
    const summary = readLift(value.summary)
    if (summary !== null) return { ok: true, summary }
    // `ok` with nothing usable in it is a success this side cannot draw, and
    // drawing a blank success is worse than saying so.
    return { ok: false, reason: 'the session was taken but could not be read back.' }
  }
  return { ok: false, reason: str(value, 'reason') || 'that session could not be taken.' }
}

export type InjectAnswer =
  | { ok: true; reports: InjectReport[]; line: string }
  | { ok: false; reason: string }

export function readInjectAnswer(raw: unknown): InjectAnswer {
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, reason: 'this build could not put that session into the workers.' }
  }
  const value = raw as Record<string, unknown>
  if (value.ok !== true) {
    return { ok: false, reason: str(value, 'reason') || 'that session could not be copied.' }
  }
  const reports: InjectReport[] = []
  for (const entry of Array.isArray(value.reports) ? value.reports : []) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.profileId !== 'string') continue
    reports.push({
      profileId: record.profileId,
      name: str(record, 'name'),
      cookiesSet: int(record, 'cookiesSet'),
      cookiesRefused: int(record, 'cookiesRefused'),
      storageQueued: int(record, 'storageQueued'),
      note: str(record, 'note'),
    })
  }
  return { ok: true, reports, line: str(value, 'line') }
}
