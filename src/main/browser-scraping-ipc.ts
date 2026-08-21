import { mkdirSync } from 'node:fs'
import { resolve, sep } from 'node:path'
import { app, shell, type IpcMain, type IpcMainInvokeEvent } from 'electron'
import { captureRoot } from './browser-capture-store'
import {
  assetFactsFor,
  captureFactsFor,
  clearCaptureFor,
  clearLedgersFor,
  lastCheckFor,
} from './browser-scrape-status'
import {
  captureFolderFor,
  scrapeSettingsFor,
  setScrapeSettings,
} from './browser-scrape-settings'
import { onWorkersChanged, setWorkerPace, workerList, workerPace, workerStatus } from './browser-workers'

/**
 * The Scraping panel's four unreachable capabilities, given a door.
 *
 * ## What was actually wrong
 *
 * Request rules, passive capture, asset renditions with their ledger, and the
 * coverage self-check were all **finished engines** before this file existed —
 * and every one of them took its configuration as an argument on a tool call and
 * stored nothing. So there was no answer to *"always fulfil this profile's
 * images"* that outlived one call, and no `ipcMain` channel a window could reach
 * at all. `ScrapingPanel.tsx` drew four sections as named-and-unavailable, which
 * was the honest thing to draw and not a thing anybody could use.
 *
 * This is one file rather than forty lines in `src/main/index.ts`, in the shape
 * `browser-drive-ipc.ts`, `browser-workers-ipc.ts` and `browser-store-ipc.ts`
 * already use: one `registerBrowserScrapingIpc(ipcMain, deps)` from
 * `registerIpc()`.
 *
 * ## Channels
 *
 * - `browser-scraping:config`        (invoke, profileId)        → the whole stored configuration
 * - `browser-scraping:config-set`    (invoke, profileId, patch) → the same, as it now stands
 * - `browser-scraping:status`        (invoke, profileId)        → what was measured
 * - `browser-scraping:capture-clear` (invoke, profileId)        → an outcome carrying a count
 * - `browser-scraping:capture-reveal`(invoke, profileId)        → void
 * - `browser-scraping:ledger-clear`  (invoke, profileId)        → an outcome carrying a count
 *
 * and emits `browser-scraping:changed` with a whole status on it, for the reason
 * `browser:downloads` gives about sending the whole view rather than a delta.
 *
 * ## One read for all five groups, one write per control
 *
 * `browser-scraping:config` answers every group at once because the panel opens
 * once and shows them together, and five round trips is five chances for the
 * screen to be half one profile's settings and half another's. The write is a
 * **patch** and it is merged group by group, because more than one screen writes
 * this configuration and a panel that posted the whole thing back would silently
 * undo whatever it had not reloaded.
 *
 * The reply to a write is the stored configuration rather than a boolean, which
 * is what lets the panel draw what was *stored* rather than what was typed: a
 * `keepMB` above what the capture store will accept comes back clamped and the
 * field shows the clamp.
 *
 * ## What this file may say about numbers
 *
 * Only what something measured. Every count crossing these channels is
 * `number | null`, `null` means nobody counted, and the panel prints
 * *"not measured"*. Two of those are worth naming because they were the
 * temptation:
 *
 *  - a worker's `requests` is **always `null`**. The pool knows which workers
 *    are leased and nothing anywhere counts a worker's requests, so this reports
 *    `busy` as a measured fact and refuses to invent the other column.
 *  - `lastAt` is `null` rather than `0` for a worker that has never been let go.
 *    `0` is the first second of 1970 and it would render as a date.
 */

/* -------------------------------------------------------------- the shape -- */

/** What an act answers with. `count` is measured or it is `null`. */
interface Outcome {
  ok: boolean
  message: string
  count: number | null
}

export interface ScrapingIpcDeps {
  /** How a push reaches the window. `src/main/index.ts` holds the only one. */
  send(channel: string, ...args: unknown[]): unknown
  /** Where this app's own data lives. Injected so a test needs no `app`. */
  userData?(): string
}

export const SCRAPING_CHANGED_CHANNEL = 'browser-scraping:changed'

/* ------------------------------------------------------------- the answers -- */

function idOf(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

/**
 * The whole configuration for one profile.
 *
 * The fleet is read out of `browser-workers.ts` rather than stored here, and
 * that is the same rule the panel states on its own section heads: a worker *is*
 * a profile, so the list of them belongs to the browser and there is exactly one
 * of it. Storing a second copy per profile would be two answers to *"how many
 * workers are there"*.
 */
export function scrapingConfig(userData: string, profileId: string): unknown {
  const settings = scrapeSettingsFor(userData, profileId)
  const pace = workerPace(userData)
  return {
    fleet: {
      profileIds: workerList(userData).map((worker) => worker.profileId),
      concurrency: pace.maxConcurrent,
      delayMs: pace.minDelayMs,
    },
    // Only the kinds somebody set. An absent kind arrives as `null` on the far
    // side, which the panel draws as "not set" — never as `allow`, which would
    // be this process reporting a decision nobody made.
    requests: { ...settings.requests },
    capture: {
      on: settings.capture.on,
      /*
       * Derived, not stored. `captureDir()` decides where a run actually
       * writes, and a second copy of that path in a settings file is a copy
       * that can disagree with the folder the bytes are in — a Show button
       * opening somewhere nothing was ever written.
       */
      directory: captureFolderFor(userData, profileId),
      keepMB: settings.capture.keepMB,
    },
    assets: settings.assets,
    checks: settings.checks,
  }
}

/** What was measured for one profile. Nothing here is a setting. */
export function scrapingStatus(userData: string, profileId: string): unknown {
  return {
    workers: workerStatus(userData).map((worker) => ({
      id: worker.profileId,
      profileId: worker.profileId,
      // `busy` is the fact the pool holds; `idle` is the honest other half of
      // it. Neither is a claim about a process — a worker is a cookie jar.
      state: worker.busy ? 'busy' : 'idle',
      requests: null,
      lastAt: worker.lastReleasedAt === 0 ? null : worker.lastReleasedAt,
    })),
    capture: captureFactsFor(userData, profileId),
    assets: assetFactsFor(userData, profileId),
    lastCheck: lastCheckFor(userData, profileId),
  }
}

/**
 * Store a patch and answer with the whole of what now stands.
 *
 * The fleet half goes to `browser-workers.ts`, which is where the pace lives and
 * where clamping it is already argued out; the other four groups go to the
 * settings store. Both are merges: one control changes one field.
 */
export function setScrapingConfig(userData: string, profileId: string, patch: unknown): unknown {
  const value = typeof patch === 'object' && patch !== null ? (patch as Record<string, unknown>) : {}
  const fleet = typeof value.fleet === 'object' && value.fleet !== null
    ? (value.fleet as Record<string, unknown>)
    : null
  if (fleet !== null && (fleet.concurrency !== undefined || fleet.delayMs !== undefined)) {
    const current = workerPace(userData)
    setWorkerPace(userData, {
      maxConcurrent: fleet.concurrency ?? current.maxConcurrent,
      minDelayMs: fleet.delayMs ?? current.minDelayMs,
      // Untouched: the panel has no control for it, and a write that reset a
      // field nobody edited is how a setting gets lost by using a different one.
      jitterMs: current.jitterMs,
    })
  }
  setScrapeSettings(userData, profileId, value)
  return scrapingConfig(userData, profileId)
}

/* ------------------------------------------------------------- the pushing -- */

/**
 * Which profile the window is looking at.
 *
 * The panel's push carries a whole status and no profile — that is its contract
 * — so this process pushes the status for whichever profile the window last
 * asked about. The panel blanks and re-pulls whenever the profile picker
 * changes, so the pull is what sets this, and every push after it is about the
 * profile on screen.
 */
let watching = ''

export function registerBrowserScrapingIpc(ipcMain: IpcMain, deps: ScrapingIpcDeps): void {
  const dir = deps.userData ?? (() => app.getPath('userData'))

  ipcMain.handle('browser-scraping:config', (_event: IpcMainInvokeEvent, profileId: unknown) =>
    scrapingConfig(dir(), idOf(profileId)),
  )

  ipcMain.handle(
    'browser-scraping:config-set',
    (_event: IpcMainInvokeEvent, profileId: unknown, patch: unknown) =>
      setScrapingConfig(dir(), idOf(profileId), patch),
  )

  ipcMain.handle('browser-scraping:status', (_event: IpcMainInvokeEvent, profileId: unknown) => {
    watching = idOf(profileId)
    return scrapingStatus(dir(), watching)
  })

  ipcMain.handle(
    'browser-scraping:capture-clear',
    (_event: IpcMainInvokeEvent, profileId: unknown): Outcome => {
      const id = idOf(profileId)
      if (id === '') return { ok: false, message: 'No profile was named.', count: null }
      const gone = clearCaptureFor(dir(), id)
      return {
        ok: true,
        message:
          gone === 0
            ? 'There was nothing captured for this profile.'
            : `${gone} capture ${gone === 1 ? 'run' : 'runs'} thrown away.`,
        count: gone,
      }
    },
  )

  ipcMain.handle(
    'browser-scraping:capture-reveal',
    (_event: IpcMainInvokeEvent, profileId: unknown) => {
      const id = idOf(profileId)
      if (id === '') return
      const folder = resolve(captureFolderFor(dir(), id))
      /*
       * The same containment check `browser-view:reveal` makes, and for the
       * same reason: this channel turns a string from a renderer into a path
       * the operating system opens, and a renderer bug that passed something
       * else through must not become a "reveal any folder on disk" primitive.
       * `safeSegment` already flattens a profile id to one path component; this
       * is the second lock on the same door.
       */
      if (folder !== resolve(captureRoot(dir())) && !folder.startsWith(resolve(captureRoot(dir())) + sep)) {
        return
      }
      /*
       * Made if it is not there yet, and only here.
       *
       * `browser-scrape-paths.ts` is right that nothing should grow empty
       * folders on its own — but `showItemInFolder` on a path that does not
       * exist does *nothing at all*, and a Show button that silently does
       * nothing is the defect this whole panel was rebuilt to remove. A person
       * pressing Show has asked to see the folder; one empty directory is the
       * whole cost of answering them.
       */
      try {
        mkdirSync(folder, { recursive: true })
      } catch {
        // Then `showItemInFolder` will do nothing, which is the same as before.
      }
      shell.showItemInFolder(folder)
    },
  )

  ipcMain.handle(
    'browser-scraping:ledger-clear',
    (_event: IpcMainInvokeEvent, profileId: unknown): Outcome => {
      const id = idOf(profileId)
      if (id === '') return { ok: false, message: 'No profile was named.', count: null }
      const gone = clearLedgersFor(dir(), id)
      return {
        ok: true,
        message:
          gone === 0
            ? 'This profile has no ledger to empty.'
            : `${gone} ${gone === 1 ? 'ledger' : 'ledgers'} emptied. The files themselves are untouched.`,
        count: gone,
      }
    },
  )

  /*
   * The push, coalesced onto the next tick.
   *
   * `queued` is what stops a re-entry: building a status reads the pool, the
   * pool sweeps expired leases, and a sweep can announce — so the flag is
   * cleared only after the send, and an announcement arriving during one is
   * folded into the send already in flight rather than starting a second.
   */
  let queued = false
  onWorkersChanged(() => {
    if (queued) return
    queued = true
    setImmediate(() => {
      try {
        deps.send(SCRAPING_CHANGED_CHANNEL, scrapingStatus(dir(), watching))
      } finally {
        queued = false
      }
    })
  })
}

/** For tests, which must not inherit each other's watched profile. */
export function resetScrapingIpcForTests(): void {
  watching = ''
  onWorkersChanged(null)
}
