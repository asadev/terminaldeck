import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { Session } from 'electron'
import { writeFileAtomic } from './atomic-write'
import {
  createProfile,
  partitionFor,
  profileState,
  sessionForPartition,
  type BrowserProfile,
} from './browser-profiles'
import {
  cleanPace,
  createWorkerPool,
  DEFAULT_PACE,
  MAX_WORKERS,
  type LeaseAnswer,
  type PaceSettings,
  type PoolWorker,
  type WorkerPool,
  type WorkerStatus,
} from './browser-worker-pool'

/**
 * Worker profiles: N cookie jars that can be driven at once, and never thrown
 * away.
 *
 * ## A worker is a profile, and that is the whole trick
 *
 * `browser-profiles.ts` already mints `persist:terminaldeck-browser-<uuid>`
 * partitions and already keeps them under `<userData>/Partitions/`. Each one
 * has its own cookie jar, its own `localStorage`, its own cache and its own
 * service workers — that is Chromium's own mechanism, verified in
 * `browser-session.ts` to survive a restart. Nothing about the *storage* half
 * of a scraping worker was missing.
 *
 * What was missing is the **worker shape**: a way to say "eight of these", a
 * way to know which one is busy, and a rule about how many run at once. That is
 * this file plus `browser-worker-pool.ts`, and between them they add no new
 * kind of thing to the app — a worker is a profile with a row in a sidecar
 * file.
 *
 * ## The sidecar, and why the row is not a field on `BrowserProfile`
 *
 * `browser-profiles.json` is read by `readProfileState`, which drops every
 * field it does not recognise. A `worker: true` flag added there would be a
 * change to the format every previous build reads, for a fact that only this
 * feature cares about. So workers are a **set of profile ids** in a file of
 * their own, and a profile with no row in it is an ordinary profile that no
 * part of this feature will touch.
 *
 * The consequence worth stating: `workerSessionFor` answers `null` for
 * anything that is not registered here. `browser-tab.ts` calls it with a
 * `profileId` that arrived over IPC, and that one refusal is why the new
 * argument cannot be used to open a page in some *other* profile's jar.
 *
 * ## A worker is never deleted, and this file cannot delete one
 *
 * The expensive thing in a worker is not the profile — it is the **clearance**:
 * whatever a site decided about that browser after it had been let through
 * once. It is bound to the fingerprint and to the jar, it can take a human
 * gesture to earn, and it does not transfer. Seven of his profiles carried a
 * byte-identical session token; re-earning that on a whim is exactly the kind
 * of loss the rest of this round is about.
 *
 * So {@link ensureWorkers} only ever grows the pool, and the only removal here
 * is {@link unregisterWorker}, which takes the row out of the sidecar and
 * leaves the partition, the cookies and the clearance untouched. There is no
 * call to `deleteProfile` anywhere in this file and `browser-workers.test.ts`
 * asserts that there is not. Destroying a profile is still possible — it is a
 * deliberate act in the profile menu, where it always was, and the Workers
 * panel says what it costs.
 *
 * ## No hidden windows
 *
 * A worker is driven by opening a page in it, in the visible tab strip, exactly
 * like any other page. Nothing in this file constructs a window, and nothing in
 * it can: it hands out a `Session`, and the only caller that turns one into a
 * page is `browser:create`, which puts the view in the window the person is
 * looking at. Headless is not offered anywhere, and `browser-workers.test.ts`
 * pins that — a hidden-window path would be a real capability regression, since
 * a headless client is the one thing every target this feature exists for
 * answers with a 403.
 */

/* ------------------------------------------------------------------ shape -- */

export interface WorkerProfile extends PoolWorker {
  profileId: string
  name: string
  partition: string
  /** When the row was added here, which is not when the profile was made. */
  registeredAt: number
}

export interface WorkerStore {
  /** Profile ids, in the order they became workers. */
  workers: string[]
  pace: PaceSettings
}

export const MAX_WORKER_COUNT = MAX_WORKERS

/* ------------------------------------------------------------ the reading -- */

export function workersPath(userData: string): string {
  return join(userData, 'browser-workers.json')
}

/**
 * A stored file, read into something always usable.
 *
 * The same discipline `readProfileState` applies, and for the same reason: a
 * stray comma in a JSON file must not be able to stop the browser panel from
 * opening. An id that is not a shape this app mints is dropped here rather than
 * reaching `fromPartition`, which would happily make a directory for it.
 */
export function readWorkerStore(raw: unknown): WorkerStore {
  const value = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  const list = Array.isArray(value.workers) ? value.workers : []
  const workers: string[] = []
  for (const entry of list) {
    if (typeof entry !== 'string') continue
    // Never the default profile. It is the jar every build before this one
    // signed into, and enrolling it as a worker would put his own live logins
    // into a pool that gets driven in parallel.
    if (partitionFor(entry) === null || entry === 'default') continue
    if (workers.includes(entry)) continue
    if (workers.length >= MAX_WORKERS) break
    workers.push(entry)
  }
  return { workers, pace: cleanPace(value.pace) }
}

/* ------------------------------------------------------------ the state -- */

let store: WorkerStore | null = null
let storeDir: string | null = null
/** profileId → when it was registered, so a row can be ordered by age. */
const registeredAt = new Map<string, number>()

function load(userData: string): WorkerStore {
  const path = workersPath(userData)
  if (!existsSync(path)) return readWorkerStore(null)
  try {
    return readWorkerStore(JSON.parse(readFileSync(path, 'utf8')) as unknown)
  } catch {
    return readWorkerStore(null)
  }
}

function save(userData: string, next: WorkerStore): void {
  const path = workersPath(userData)
  mkdirSync(dirname(path), { recursive: true })
  writeFileAtomic(path, `${JSON.stringify({ version: 1, ...next }, null, 2)}\n`)
}

function ensure(userData: string): WorkerStore {
  if (store === null || storeDir !== userData) {
    storeDir = userData
    store = load(userData)
  }
  return store
}

/** For tests, which must not inherit each other's state. */
export function resetWorkersForTests(): void {
  store = null
  storeDir = null
  registeredAt.clear()
  pool.reset()
}

/* ------------------------------------------------------------- the list -- */

/**
 * Every worker, resolved against the profile store.
 *
 * A row whose profile has been deleted is **dropped from the answer but kept in
 * the file**, and that asymmetry is deliberate. Dropping it from the answer is
 * what stops the panel listing a worker whose jar is gone — a row that cannot
 * be opened. Keeping it in the file is what stops a profile store that failed
 * to load for one launch from silently unregistering eight workers, which would
 * read to a person as their pool evaporating.
 */
export function workerList(userData: string): WorkerProfile[] {
  const current = ensure(userData)
  const profiles = profileState(userData).profiles
  const byId = new Map<string, BrowserProfile>(profiles.map((profile) => [profile.id, profile]))
  const out: WorkerProfile[] = []
  for (const id of current.workers) {
    const profile = byId.get(id)
    if (!profile) continue
    out.push({
      profileId: profile.id,
      name: profile.name,
      partition: profile.partition,
      registeredAt: registeredAt.get(profile.id) ?? profile.createdAt,
    })
  }
  return out
}

export function isWorkerProfile(userData: string, profileId: unknown): boolean {
  if (typeof profileId !== 'string' || profileId === '') return false
  return ensure(userData).workers.includes(profileId)
}

/**
 * The hardened session for a worker, or null.
 *
 * Null for every id that is not a registered worker, including a perfectly real
 * profile of his own — which is the point. This is the function `browser-tab.ts`
 * consults when a `browser:create` names a profile, so "not a worker" has to be
 * indistinguishable from "not a profile" at that seam, or the new argument
 * becomes a way to open a page in the jar holding his bank login.
 */
export function workerSessionFor(userData: string, profileId: unknown): Session | null {
  if (!isWorkerProfile(userData, profileId)) return null
  const partition = partitionFor(profileId)
  if (partition === null) return null
  return sessionForPartition(partition)
}

/** Which worker a live session belongs to, by object identity. */
export function workerForSession(userData: string, candidate: Session): WorkerProfile | null {
  for (const worker of workerList(userData)) {
    if (sessionForPartition(worker.partition) === candidate) return worker
  }
  return null
}

/* ------------------------------------------------------------- the minting -- */

/**
 * Make sure there are at least `count` workers, and hand back all of them.
 *
 * **Grows only.** Asking for three when eight exist returns eight, because the
 * five that would have to go are five earned clearances and this function is
 * not entitled to spend them. How many run *at once* is a different question
 * with a different answer — `pace.maxConcurrent` — and it is the one a person
 * who asks for "three" almost always means.
 *
 * The names are `Worker 1`, `Worker 2`, … and they are the profile's real name,
 * so the same string appears in the profile menu, in the tab strip's badge and
 * in what the agent is told. A worker with a private name would be a second
 * vocabulary for the same object.
 */
/**
 * The next free number in the `Worker N` series, counted across **every**
 * profile rather than across the workers.
 *
 * Numbering from `workers.length` was wrong in a way that only shows up after a
 * removal: unregister `Worker 2` out of three and the pool is two long, so the
 * next mint would be a *second* profile called `Worker 3`. Two rows with one
 * name is an ambiguity the tools cannot resolve — a caller asking for
 * `Worker 3` gets whichever comes first — and it is the same fault
 * `browser-binding.ts` refuses ordinals for: a number that is reused is not an
 * identity.
 *
 * Every profile is counted, not only the registered ones, because the profile
 * that was unregistered still exists and still wears its name in the profile
 * menu.
 */
function nextWorkerNumber(userData: string): number {
  let highest = 0
  for (const profile of profileState(userData).profiles) {
    const match = /^Worker (\d{1,4})$/.exec(profile.name)
    if (match) highest = Math.max(highest, Number(match[1]))
  }
  return highest + 1
}

export function ensureWorkers(userData: string, count: unknown): WorkerProfile[] {
  const current = ensure(userData)
  const wanted = Math.min(
    Math.max(typeof count === 'number' && Number.isFinite(count) ? Math.trunc(count) : 0, 0),
    MAX_WORKERS,
  )
  const existing = workerList(userData)
  if (existing.length >= wanted) return existing

  const now = Date.now()
  let next = nextWorkerNumber(userData)
  for (let n = existing.length; n < wanted; n += 1) {
    const profile = createProfile(userData, `Worker ${next}`)
    next += 1
    current.workers.push(profile.id)
    registeredAt.set(profile.id, now)
  }
  save(userData, current)
  return workerList(userData)
}

/**
 * Enrol a profile that already exists as a worker.
 *
 * The route that matters for item 2: a profile he already signed something into
 * — or one he has spent weeks warming up — becomes part of the pool without
 * being recreated. Refused for the default profile, which holds every login
 * from before this feature existed.
 */
export function registerWorker(userData: string, profileId: unknown): WorkerProfile[] {
  const current = ensure(userData)
  if (typeof profileId !== 'string' || profileId === 'default' || partitionFor(profileId) === null) {
    return workerList(userData)
  }
  if (!profileState(userData).profiles.some((profile) => profile.id === profileId)) {
    return workerList(userData)
  }
  if (!current.workers.includes(profileId) && current.workers.length < MAX_WORKERS) {
    current.workers.push(profileId)
    registeredAt.set(profileId, Date.now())
    save(userData, current)
  }
  return workerList(userData)
}

/**
 * Take a profile out of the pool and **leave everything in it alone**.
 *
 * Not a delete. The partition, the cookies, the clearance and the profile row
 * all stay exactly as they were; what changes is that this feature stops
 * offering it. That distinction is the whole reason this function is not called
 * `removeWorker`: the word people reach for when they want a row gone is the
 * word that would have destroyed the expensive part.
 */
export function unregisterWorker(userData: string, profileId: unknown): WorkerProfile[] {
  const current = ensure(userData)
  const index = current.workers.indexOf(profileId as string)
  if (index >= 0) {
    current.workers.splice(index, 1)
    // Before the save, and unconditionally: a worker that has left the pool must
    // not leave a lease behind that nothing can see and nothing can release.
    pool.forget(profileId as string)
    save(userData, current)
  }
  return workerList(userData)
}

/* --------------------------------------------------------------- the pace -- */

export function workerPace(userData: string): PaceSettings {
  return ensure(userData).pace
}

export function setWorkerPace(userData: string, raw: unknown): PaceSettings {
  const current = ensure(userData)
  current.pace = cleanPace(raw)
  save(userData, current)
  return current.pace
}

/* --------------------------------------------------------------- the pool -- */

/**
 * The one pool.
 *
 * Module-level rather than per-caller because "which worker is busy" has to be
 * one answer across the panel, the tools and every session — two pools would be
 * two agents confidently driving the same cookie jar.
 *
 * It reads the worker list and the pace through closures rather than being
 * handed them, so a worker minted a second ago is in the pool without anything
 * having to rebuild it.
 */
export const pool: WorkerPool = createWorkerPool({
  workers: () => (storeDir === null ? [] : workerList(storeDir)),
  pace: () => (storeDir === null ? { ...DEFAULT_PACE } : workerPace(storeDir)),
  now: () => Date.now(),
  random: () => Math.random(),
})

export function workerStatus(userData: string): WorkerStatus[] {
  ensure(userData)
  return pool.status()
}

/**
 * A sleep that is actually a sleep.
 *
 * A seam rather than a bare `setTimeout` so the pacing can be tested against a
 * fake clock. The rule it exists to keep is the one that cost the pipeline its
 * politeness: a delay that a caller may skip, or that is written down in a
 * config and never awaited, is not a delay. Every path that hands out a lease
 * goes through {@link leaseWorker}, and {@link leaseWorker} awaits this.
 */
export type Sleep = (ms: number) => Promise<void>

const realSleep: Sleep = (ms) =>
  new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    timer.unref?.()
  })

/**
 * Take a worker **and serve its wait**.
 *
 * The wait is enforced here, inside the call, rather than returned as a number
 * for the caller to honour. That is the entire difference between a delay and a
 * setting: a number handed to an agent is a suggestion it will drop the moment
 * a retry loop gets involved, and a promise that does not resolve for 2.3
 * seconds is not.
 *
 * `pacedMs` comes back so the answer can say what actually happened. A caller
 * that reads `pacedMs: 0` on every lease has a pace of zero, and that is worth
 * being able to see.
 */
/**
 * Let a worker go, or keep it a while longer.
 *
 * Thin wrappers rather than `pool.release` reached for directly, and the reason
 * is the closure the pool is built on: it reads its workers through `storeDir`,
 * which is only set once something has called {@link ensure}. A caller that
 * released before anything had listed would be talking to a pool that believed
 * it had no workers. One line each, and the seam cannot be got wrong.
 */
export function releaseWorker(
  userData: string,
  input: { holder: string; profileId: string },
): boolean {
  ensure(userData)
  return pool.release(input)
}

export function renewWorker(
  userData: string,
  input: { holder: string; profileId: string; holdMs?: number },
): boolean {
  ensure(userData)
  return pool.renew(input)
}

export async function leaseWorker(
  userData: string,
  input: { holder: string; profileId?: string | null; holdMs?: number },
  sleep: Sleep = realSleep,
): Promise<LeaseAnswer & { pacedMs?: number }> {
  ensure(userData)
  const answer = pool.lease(input)
  if (!answer.ok) return answer
  if (answer.waitMs > 0) await sleep(answer.waitMs)
  return { ...answer, pacedMs: answer.waitMs }
}
