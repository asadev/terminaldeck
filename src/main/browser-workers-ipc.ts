import { app, webContents, type IpcMain, type IpcMainInvokeEvent, type Session } from 'electron'
import { logger } from './app-log'
import { isProfileGuestSession, profileState, sessionForPartition } from './browser-profiles'
import { frameOrigin, writeSeedPreload, GUEST_SEED_CHANNEL } from './browser-seed-preload'
import {
  forgetLift,
  injectLift,
  liftById,
  liftFromPage,
  liftLine,
  liftSummaries,
  pendingSeeds,
  summariseLift,
  takeSeed,
  type InjectReport,
  type InjectTarget,
  type LiftSummary,
} from './browser-session-lift'
import { browserTabContents } from './browser-tab'
import {
  ensureWorkers,
  leaseWorker,
  registerWorker,
  setWorkerPace,
  unregisterWorker,
  workerList,
  workerPace,
  workerStatus,
  MAX_WORKER_COUNT,
} from './browser-workers'
import { cleanPace, leaseRefusalLine, paceNote, type PaceSettings } from './browser-worker-pool'

/**
 * The wires for worker profiles and for the session lift.
 *
 * Everything here is `ipcMain`, which is the whole of the permission model for
 * the half that matters. Read `browser-session-lift.ts` first; the rule it
 * states is enforced *by where these handlers live*:
 *
 *  - An `ipcMain` channel is reachable from the app's own renderer and from
 *    nowhere else. A guest page cannot reach it — the pages in the browser get
 *    `writeGuestPreload`, a different and much smaller bridge — and an agent
 *    cannot reach it, because an agent talks to this process over
 *    `deck-control`'s loopback MCP endpoint and that endpoint dispatches a
 *    **catalogue of tools**, not IPC channels.
 *  - So `browser-worker:lift` is a human gesture by construction rather than by
 *    policy. There is no tool that calls it, and `session-tools.ts` records why
 *    there must not be.
 *
 * The worker half is not a secret and is wired the same way only because it is
 * a panel's data. The parts an agent legitimately needs — which workers exist,
 * which are free, and the wait it owes — are exposed as tools in
 * `deck-control/worker-tools.ts`, and none of them touch a lift.
 */

/* ------------------------------------------------------------------ view -- */

/** One page open in a worker's jar, as a panel may see it. */
export interface WorkerPage {
  url: string
  title: string
}

export interface WorkerRow {
  profileId: string
  name: string
  partition: string
  busy: boolean
  holder: string
  heldMs: number
  readyInMs: number
  lastReleasedAt: number
  pages: WorkerPage[]
  /** Stored keys still waiting for this worker to open the origin. */
  queued: { origin: string; keys: number }[]
}

export interface WorkersView {
  workers: WorkerRow[]
  pace: PaceSettings
  /** Non-empty when the stored pace is not the pace that was typed. */
  paceNote: string
  /** Lifted sessions still in memory, as counts and names. Never values. */
  lifts: LiftSummary[]
  /** False when the seed preload could not be written — see the panel's row. */
  canSeedStorage: boolean
  max: number
}

/* ------------------------------------------------------- the seed preload -- */

/**
 * Where the seed script is, written once per run, or null if it could not be.
 *
 * Null is a real answer and it travels: {@link WorkersView.canSeedStorage} is
 * false, the panel says storage cannot be seeded in this build, and
 * `injectLift` writes the cookies anyway and reports that the stored keys did
 * not go. The failure that is not allowed is the quiet one — a worker that
 * looks injected and is not signed in.
 */
let seedPreload: string | null | undefined
/** Partitions the preload is registered on, so it is registered once each. */
const seeded = new Set<string>()

function seedPreloadPath(): string | null {
  if (seedPreload === undefined) {
    try {
      seedPreload = writeSeedPreload(app.getPath('userData'))
    } catch (error) {
      seedPreload = null
      logger.warn('browser-workers', 'could not write the storage-seed preload', {
        message: error instanceof Error ? error.message : String(error),
      })
    }
  }
  return seedPreload
}

/** Attach the seed preload to one worker partition. False when it could not be. */
function registerSeedPreload(partition: string): boolean {
  const filePath = seedPreloadPath()
  if (filePath === null) return false
  if (seeded.has(partition)) return true
  try {
    sessionForPartition(partition).registerPreloadScript({ type: 'frame', filePath })
    seeded.add(partition)
    return true
  } catch (error) {
    logger.warn('browser-workers', 'could not attach the storage-seed preload', {
      message: error instanceof Error ? error.message : String(error),
    })
    return false
  }
}

/** For tests, which must not inherit a run's registrations. */
export function resetWorkerIpcForTests(): void {
  seedPreload = undefined
  seeded.clear()
}

/* ---------------------------------------------------------- reading the app -- */

function userData(): string {
  return app.getPath('userData')
}

/**
 * Which profile a live session belongs to.
 *
 * By object identity rather than by a partition string, because
 * `session.fromPartition` returns the same object for the same string and a
 * string comparison would need the partition, which a `WebContents` does not
 * carry. The same trick `isProfileGuestSession` uses one file over.
 */
function profileOfSession(candidate: Session): { id: string; name: string } | null {
  for (const profile of profileState(userData()).profiles) {
    if (sessionForPartition(profile.partition) === candidate) {
      return { id: profile.id, name: profile.name }
    }
  }
  return null
}

/**
 * The pages open in one worker's jar right now.
 *
 * Read from `webContents.getAllWebContents()` and matched by session identity,
 * which is deliberately the *truth* rather than a registry this feature keeps
 * of its own. A registry would drift the first time a page was closed by a
 * route nobody remembered to tell it about, and a panel that lists a page that
 * is not there is a row you can press that does nothing.
 */
function pagesIn(partition: string): WorkerPage[] {
  let jar: Session
  try {
    jar = sessionForPartition(partition)
  } catch {
    return []
  }
  const out: WorkerPage[] = []
  let all: ReturnType<typeof webContents.getAllWebContents>
  try {
    all = webContents.getAllWebContents()
  } catch {
    return []
  }
  for (const contents of all) {
    try {
      if (contents.isDestroyed() || contents.session !== jar) continue
      const url = contents.getURL()
      // `about:blank` is a view that has been made and not pointed anywhere
      // yet. Listing it as a page would make an empty worker look occupied.
      if (url === '' || url === 'about:blank') continue
      out.push({ url, title: contents.getTitle() })
    } catch {
      // A view that went between the enumeration and the read. Not a page.
    }
  }
  return out
}

export function workersView(): WorkersView {
  const dir = userData()
  const workers = workerList(dir)
  const status = new Map(workerStatus(dir).map((row) => [row.profileId, row]))
  const queued = pendingSeeds()
  return {
    workers: workers.map((worker) => {
      const row = status.get(worker.profileId)
      return {
        profileId: worker.profileId,
        name: worker.name,
        partition: worker.partition,
        busy: row?.busy ?? false,
        holder: row?.holder ?? '',
        heldMs: row?.heldMs ?? 0,
        readyInMs: row?.readyInMs ?? 0,
        lastReleasedAt: row?.lastReleasedAt ?? 0,
        pages: pagesIn(worker.partition),
        queued: queued
          .filter((seed) => seed.partition === worker.partition)
          .map((seed) => ({ origin: seed.origin, keys: seed.keys })),
      }
    }),
    pace: workerPace(dir),
    paceNote: '',
    lifts: liftSummaries(),
    canSeedStorage: seedPreloadPath() !== null,
    max: MAX_WORKER_COUNT,
  }
}

/* ------------------------------------------------------------- the answers -- */

export type LiftAnswer =
  | { ok: true; summary: LiftSummary }
  | { ok: false; reason: string }

export type InjectAnswer =
  | { ok: true; reports: InjectReport[]; line: string }
  | { ok: false; reason: string }

/**
 * Refuse anything that did not come from a window of the app's own.
 *
 * Belt over braces. A guest page cannot reach `ipcMain` at all through the
 * bridge it is given, so this can only fire if that ever stops being true — and
 * the day it stops being true is the day a website would otherwise be able to
 * ask this process to copy his logged-in session into eight profiles. A check
 * that is unreachable today and catastrophic to be missing tomorrow is worth
 * four lines.
 */
function fromAppWindow(event: IpcMainInvokeEvent): boolean {
  try {
    return !isProfileGuestSession(event.sender.session)
  } catch {
    return false
  }
}

/**
 * Take the session out of the page the person is looking at.
 *
 * `viewId` is the main-process tab id the renderer already holds for the page
 * in front of it. It is resolved through `browserTabContents`, which answers
 * null for an id it does not know and for a view that has gone — so a stale id
 * is a refusal rather than a lift of some other page.
 */
async function handleLift(event: IpcMainInvokeEvent, raw: unknown): Promise<LiftAnswer> {
  if (!fromAppWindow(event)) return { ok: false, reason: 'that request did not come from this app’s window' }
  const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
  const contents = browserTabContents(input.viewId)
  if (!contents) return { ok: false, reason: 'there is no page open to take a session from' }

  const profile = profileOfSession(contents.session)
  if (profile === null) {
    // An Isolated tab. Its partition is in memory and dies with the process, so
    // a session lifted from it is a session that is about to stop existing — and
    // the *point* of Isolated is that what happens in it does not travel.
    return {
      ok: false,
      reason:
        'this page is in an Isolated tab, whose session is thrown away when the app closes. Open it in a profile first.',
    }
  }

  const answer = await liftFromPage({
    page: contents,
    jar: contents.session,
    profileId: profile.id,
    profileName: profile.name,
  })
  if (!answer.ok) return answer

  /*
   * Written down, and written down without values.
   *
   * A lift is the one action in this feature that moves a credential, so there
   * has to be a record of it having happened that is not a React state. The
   * summary is exactly what the panel sees — counts, names, the host — which is
   * why it is the thing that is logged rather than a hand-written line that
   * could drift from it.
   */
  logger.info('browser-workers', 'a session was lifted by hand', {
    host: answer.summary.host,
    from: answer.summary.sourceProfileName,
    cookies: answer.summary.cookieCount,
    localKeys: answer.summary.localKeys,
    sessionKeys: answer.summary.sessionKeys,
  })
  return answer
}

/**
 * Copy a lift into workers.
 *
 * Automatic in the sense that matters — it does not ask again — because the
 * scope was decided when the person pressed Lift: this host, this profile,
 * these workers. Naming a subset is allowed; naming nothing means all of them,
 * which is the case the feature exists for.
 */
async function handleInject(event: IpcMainInvokeEvent, raw: unknown): Promise<InjectAnswer> {
  if (!fromAppWindow(event)) return { ok: false, reason: 'that request did not come from this app’s window' }
  const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
  const lift = liftById(input.liftId)
  if (lift === null) {
    return {
      ok: false,
      reason: 'that lifted session has expired or was already forgotten. Sign in on the page again and lift it.',
    }
  }

  const wanted = Array.isArray(input.profileIds)
    ? input.profileIds.filter((id): id is string => typeof id === 'string')
    : null
  const all = workerList(userData())
  const chosen = wanted === null ? all : all.filter((worker) => wanted.includes(worker.profileId))
  if (chosen.length === 0) {
    return { ok: false, reason: 'there are no workers to put it into. Add some first.' }
  }
  // Never into the profile it came from: it is already signed in there, and a
  // `set` of a cookie onto itself is a write of a live credential for no reason.
  const targets: InjectTarget[] = chosen
    .filter((worker) => worker.profileId !== lift.sourceProfileId)
    .map((worker) => ({
      profileId: worker.profileId,
      name: worker.name,
      partition: worker.partition,
      jar: sessionForPartition(worker.partition),
    }))
  if (targets.length === 0) {
    return { ok: false, reason: 'the only worker chosen is the profile the session came from, which is already signed in.' }
  }

  const reports = await injectLift({ lift, targets, register: registerSeedPreload })
  logger.info('browser-workers', 'a lifted session was injected', {
    host: lift.host,
    workers: reports.length,
    cookiesSet: reports.reduce((sum, report) => sum + report.cookiesSet, 0),
    cookiesRefused: reports.reduce((sum, report) => sum + report.cookiesRefused, 0),
    storageQueued: reports.reduce((sum, report) => sum + report.storageQueued, 0),
  })
  return { ok: true, reports, line: liftLine(summariseLift(lift), targets.length) }
}

/* --------------------------------------------------------------- register -- */

/**
 * Wire worker profiles and the session lift. Call once from `registerIpc()`:
 *
 *     import { registerBrowserWorkerIpc } from './browser-workers-ipc'
 *     registerBrowserWorkerIpc(ipcMain)
 *
 * Channels:
 * - `browser-worker:list`        (invoke)                    → {@link WorkersView}
 * - `browser-worker:ensure`      (invoke, count)             → {@link WorkersView}
 * - `browser-worker:register`    (invoke, profileId)         → {@link WorkersView}
 * - `browser-worker:unregister`  (invoke, profileId)         → {@link WorkersView}
 * - `browser-worker:pace`        (invoke, pace)              → {@link WorkersView}
 * - `browser-worker:lift`        (invoke, {viewId})          → {@link LiftAnswer}
 * - `browser-worker:inject`      (invoke, {liftId, profileIds?}) → {@link InjectAnswer}
 * - `browser-worker:forget-lift` (invoke, liftId)            → {@link WorkersView}
 * - `terminaldeck-browser:seed`  (invoke, from a worker frame) → the seed, once
 */
export function registerBrowserWorkerIpc(ipcMain: IpcMain): void {
  ipcMain.handle('browser-worker:list', () => workersView())

  ipcMain.handle('browser-worker:ensure', (_event, count: unknown) => {
    ensureWorkers(userData(), count)
    return workersView()
  })

  ipcMain.handle('browser-worker:register', (_event, profileId: unknown) => {
    registerWorker(userData(), profileId)
    return workersView()
  })

  ipcMain.handle('browser-worker:unregister', (_event, profileId: unknown) => {
    unregisterWorker(userData(), profileId)
    return workersView()
  })

  ipcMain.handle('browser-worker:pace', (_event, raw: unknown) => {
    const stored = setWorkerPace(userData(), raw)
    // The clamp is shown rather than applied in silence: a field that stores a
    // different number from the one it displays is a control that lies quietly.
    return { ...workersView(), pace: stored, paceNote: paceNote(raw, cleanPace(raw)) }
  })

  ipcMain.handle('browser-worker:lift', handleLift)
  ipcMain.handle('browser-worker:inject', handleInject)

  ipcMain.handle('browser-worker:forget-lift', (_event, liftId: unknown) => {
    forgetLift(liftId)
    return workersView()
  })

  /*
   * The seed, answered to a frame rather than to a claim.
   *
   * Neither the partition nor the origin comes from the message: the partition
   * is `event.sender.session`, matched against the worker jars by identity, and
   * the origin is `event.senderFrame.url`, which is Chromium's record of where
   * that frame actually is. The preload sends no arguments at all — see
   * `browser-seed-preload.ts` for why a design that trusted them would be one
   * bad release away from handing a token to whoever asked.
   */
  ipcMain.handle(GUEST_SEED_CHANNEL, (event: IpcMainInvokeEvent) => {
    let partition: string | null = null
    try {
      const dir = userData()
      for (const worker of workerList(dir)) {
        if (sessionForPartition(worker.partition) === event.sender.session) {
          partition = worker.partition
          break
        }
      }
    } catch {
      return null
    }
    if (partition === null) return null
    const origin = frameOrigin(event.senderFrame?.url)
    if (origin === '') return null
    const seed = takeSeed(partition, origin)
    if (seed === null) return null
    return { local: seed.local, session: seed.session }
  })
}

/* ------------------------------------------------------------- the leasing -- */

/**
 * Lease a worker on behalf of a caller that is not the person.
 *
 * Exported for `deck-control/worker-tools.ts` rather than being an IPC channel,
 * because the caller is an agent and an agent's door is the tool catalogue. It
 * awaits the pace — see `browser-workers.ts` — so the delay is served inside
 * the call rather than handed over as a number to be honoured.
 */
export async function leaseForCaller(input: {
  holder: string
  profileId?: string | null
  holdMs?: number
}): Promise<{ ok: true; profileId: string; name: string; pacedMs: number; expiresAt: number } | { ok: false; reason: string }> {
  const dir = userData()
  const answer = await leaseWorker(dir, input)
  if (!answer.ok) return { ok: false, reason: leaseRefusalLine(answer.reason, workerPace(dir)) }
  const worker = workerList(dir).find((one) => one.profileId === answer.lease.profileId)
  return {
    ok: true,
    profileId: answer.lease.profileId,
    name: worker?.name ?? answer.lease.profileId,
    pacedMs: answer.pacedMs ?? 0,
    expiresAt: answer.lease.expiresAt,
  }
}

/** Which worker a live browser view is in, or null. For the tools. */
export function workerOfView(viewId: unknown): { profileId: string; name: string } | null {
  const contents = browserTabContents(viewId)
  if (!contents) return null
  try {
    for (const worker of workerList(userData())) {
      if (sessionForPartition(worker.partition) === contents.session) {
        return { profileId: worker.profileId, name: worker.name }
      }
    }
  } catch {
    return null
  }
  return null
}

