import { existsSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { readCoverage, type CoverageCheck } from './browser-asset-coverage'
import { readLedgerFile } from './browser-asset-ledger'
import type { AssetFetchTally } from './browser-asset-fetch'
import { captureRoot, safeSegment, type CaptureCounts } from './browser-capture-store'
import { coveragePath, ledgerPath, runDir, scrapeRoot } from './browser-scrape-paths'

/**
 * The measured half of the Scraping panel: what happened, never what was asked
 * for.
 *
 * `browser-scrape-settings.ts` holds the settings and this holds the results,
 * and the two are separate files for the reason `ScrapingStatus` gives about
 * being a separate type: *"a setting is what somebody asked for and a status is
 * what happened, and the moment those two are read out of one object the screen
 * starts reporting intentions as results."*
 *
 * ## Every number here is measured or it is `null`
 *
 * `null` reaches the panel as **"not measured"** and it is never rendered as a
 * zero. That is not a stylistic rule: 48,473 assets were skipped by a tool that
 * exited reporting success, and 7% of a dataset shipped as complete. So:
 *
 *  - a profile that has never captured anything answers `null`, not `0`;
 *  - a profile whose capture runs are **still open** answers `null` for all
 *    three counts, because the sum of the runs that happen to have closed is a
 *    total nobody has, and a partial total presented as the total is the exact
 *    failure being guarded against;
 *  - the asset tallies are `null` until an `assets.fetch` batch has reported
 *    one into this process, and they say so for the whole of a session in which
 *    nothing fetched.
 */

/* --------------------------------------------------- which run, whose run -- */

/**
 * The file that says which profile a run belongs to.
 *
 * A run's folder is named by an id a caller chose and holds no other clue about
 * whose cookies fetched it, so the two per-profile acts the panel offers —
 * *"empty the ledger"* and *"what did this profile fetch"* — would have nothing
 * to select on. One line, written the first time a tool call names both, and
 * read back afterwards, which is what makes those answers survive a restart.
 * Everything about a run lives in the run's own folder; see
 * `browser-scrape-paths.ts`.
 */
export function runOwnerPath(userData: string, runId: string): string {
  return join(runDir(userData, runId), 'profile')
}

/** Remember that this run is this profile's. Best effort, and idempotent. */
export function noteRunProfile(userData: string, runId: string, profileId: string): void {
  if (runId === '' || profileId === '') return
  const path = runOwnerPath(userData, runId)
  try {
    if (existsSync(path) && readFileSync(path, 'utf8').trim() === profileId) return
    mkdirSync(runDir(userData, runId), { recursive: true })
    writeFileSync(path, `${profileId}\n`)
  } catch {
    // A run whose owner could not be written is a run this panel cannot show
    // per profile. It is not a reason to fail the fetch that provoked it.
  }
}

/**
 * Whose run this is, or `''`.
 *
 * The reason it is read as well as written: `assets.coverage` takes a run id and
 * no profile, so without this a coverage check could never find the pattern its
 * own profile stored, and could never be shown in that profile's Checks
 * section. One `assets.fetch` naming the profile is enough to file the whole
 * run, and every check on it afterwards knows where it belongs.
 */
export function runOwnerOf(userData: string, runId: string): string {
  try {
    return readFileSync(runOwnerPath(userData, runId), 'utf8').trim()
  } catch {
    return ''
  }
}

/** Every run this profile has been named in, oldest folder order. */
export function runsFor(userData: string, profileId: string): string[] {
  if (profileId === '') return []
  const root = join(scrapeRoot(userData), 'runs')
  let names: string[]
  try {
    names = readdirSync(root)
  } catch {
    return []
  }
  const out: string[] = []
  for (const name of names) {
    try {
      if (readFileSync(join(root, name, 'profile'), 'utf8').trim() === profileId) out.push(name)
    } catch {
      // A run with no owner file belongs to nobody this panel can name.
    }
  }
  return out
}

/* ---------------------------------------------------------------- capture -- */

export interface CaptureFacts {
  recorded: number | null
  bytes: number | null
  dropped: number | null
  droppedReason: string
}

/**
 * Everything this profile's capture runs wrote, added up off their own summaries.
 *
 * `CaptureStore.close()` writes `capture-summary.json` beside the manifest, and
 * that file is a superset of {@link CaptureCounts} — which is why this reads the
 * summaries rather than keeping a second tally that could disagree with the
 * folder the bytes are in.
 *
 * A run folder with no summary in it is a run that was never closed. It is
 * counted, and its existence turns all three numbers into `null`: the honest
 * answer to *"how many responses has this profile recorded"* while a run is
 * still going is that nobody knows yet, and the alternative — quietly summing
 * the runs that finished — is a total that reads as complete and is not.
 */
export function captureFactsFor(userData: string, profileId: string): CaptureFacts | null {
  const dir = join(captureRoot(userData), safeSegment(profileId === '' ? 'isolated' : profileId))
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    return null
  }
  const totals: CaptureCounts = {
    entries: 0,
    bodies: 0,
    lost: 0,
    tooLarge: 0,
    overBudget: 0,
    unfinished: 0,
    failed: 0,
    notRequested: 0,
    bytes: 0,
  }
  const shortfalls: string[] = []
  let read = 0
  let open = 0
  for (const name of names) {
    const summary = readCaptureSummary(join(dir, name, 'capture-summary.json'))
    if (summary === null) {
      /*
       * A folder under a profile's capture root is a run — `CaptureStore.open()`
       * is the only thing that makes one — so a folder with no summary in it is
       * a run that has not been closed.
       *
       * Judged on the folder rather than on the manifest, deliberately: the
       * manifest is not written until the first response arrives, so a run armed
       * a second ago and still silent would otherwise be invisible here, and the
       * totals would read as final while a capture was in flight.
       */
      try {
        if (statSync(join(dir, name)).isDirectory()) open += 1
      } catch {
        // Gone between the listing and the look. Nothing to count either way.
      }
      continue
    }
    read += 1
    for (const key of Object.keys(totals) as (keyof CaptureCounts)[]) {
      totals[key] += summary.counts[key]
    }
    if (summary.shortfall !== '') shortfalls.push(summary.shortfall)
  }
  if (read === 0 && open === 0) return null
  if (open > 0) {
    return {
      recorded: null,
      bytes: null,
      dropped: null,
      droppedReason: '',
    }
  }
  const dropped = totals.lost + totals.tooLarge + totals.overBudget + totals.unfinished
  return {
    recorded: totals.entries,
    bytes: totals.bytes,
    dropped,
    // The store's own sentence, which already names the bound that did it.
    droppedReason: dropped === 0 ? '' : shortfalls.join('; '),
  }
}

function readCaptureSummary(
  path: string,
): { counts: CaptureCounts; shortfall: string } | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8')) as unknown
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const value = parsed as Record<string, unknown>
  const counts: CaptureCounts = {
    entries: 0,
    bodies: 0,
    lost: 0,
    tooLarge: 0,
    overBudget: 0,
    unfinished: 0,
    failed: 0,
    notRequested: 0,
    bytes: 0,
  }
  let any = false
  for (const key of Object.keys(counts) as (keyof CaptureCounts)[]) {
    const raw = value[key]
    if (typeof raw === 'number' && Number.isFinite(raw) && raw >= 0) {
      counts[key] = Math.trunc(raw)
      any = true
    }
  }
  if (!any) return null
  return { counts, shortfall: typeof value.shortfall === 'string' ? value.shortfall : '' }
}

/**
 * Throw away everything this profile has captured, and say how many runs went.
 *
 * A count rather than a boolean, because *"cleared"* with nothing counted is the
 * shape of report this panel refuses. Nothing outside the profile's own capture
 * folder is touched.
 */
export function clearCaptureFor(userData: string, profileId: string): number {
  const dir = join(captureRoot(userData), safeSegment(profileId === '' ? 'isolated' : profileId))
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    return 0
  }
  let gone = 0
  for (const name of names) {
    try {
      rmSync(join(dir, name), { recursive: true, force: true })
      gone += 1
    } catch {
      // One run that will not go is not a reason to leave the rest.
    }
  }
  return gone
}

/* ----------------------------------------------------------------- assets -- */

export interface AssetFacts {
  fetched: number | null
  upgraded: number | null
  fellBack: number | null
  skipped: number | null
  ledgerEntries: number | null
}

/**
 * What `assets.fetch` has reported into this process, per profile.
 *
 * Memory, and it stays memory. The tallies are what *this session* measured; a
 * relaunch answers `null` — "not measured" — rather than a number carried over
 * from a file that nobody guarantees matches the assets on disk. The rows in the
 * ledger are the durable half and they are counted from the ledgers themselves.
 */
const batches = new Map<string, { fetched: number; upgraded: number; fellBack: number; skipped: number }>()

/** Told about one finished batch. Called from `deck-control/asset-tools.ts`. */
export function noteAssetBatch(profileId: string, tally: AssetFetchTally): void {
  if (profileId === '') return
  const running = batches.get(profileId) ?? { fetched: 0, upgraded: 0, fellBack: 0, skipped: 0 }
  running.fetched += whole(tally.fetched)
  running.upgraded += whole(tally.upgraded)
  running.fellBack += whole(tally.fellBack)
  running.skipped += whole(tally.skipped)
  batches.set(profileId, running)
}

function whole(raw: unknown): number {
  return typeof raw === 'number' && Number.isFinite(raw) && raw > 0 ? Math.trunc(raw) : 0
}

/**
 * Rows in this profile's ledgers, counted off the files.
 *
 * Cached on the file's size and modification time, because the status is pushed
 * as well as pulled and a ledger of sixty thousand rows should not be parsed
 * every time a worker is leased.
 */
const ledgerCounts = new Map<string, { stamp: string; entries: number }>()

function ledgerEntriesAt(path: string): number | null {
  let stamp: string
  try {
    const info = statSync(path)
    stamp = `${info.size}:${info.mtimeMs}`
  } catch {
    return null
  }
  const cached = ledgerCounts.get(path)
  if (cached && cached.stamp === stamp) return cached.entries
  try {
    const entries = readLedgerFile(readFileSync(path, 'utf8')).entries.size
    ledgerCounts.set(path, { stamp, entries })
    return entries
  } catch {
    return null
  }
}

export function assetFactsFor(userData: string, profileId: string): AssetFacts | null {
  const runs = runsFor(userData, profileId)
  let rows: number | null = null
  for (const runId of runs) {
    const counted = ledgerEntriesAt(ledgerPath(userData, runId))
    if (counted === null) continue
    rows = (rows ?? 0) + counted
  }
  const running = batches.get(profileId) ?? null
  if (running === null && rows === null) return null
  return {
    fetched: running?.fetched ?? null,
    upgraded: running?.upgraded ?? null,
    fellBack: running?.fellBack ?? null,
    skipped: running?.skipped ?? null,
    ledgerEntries: rows,
  }
}

/**
 * Forget every asset this profile has fetched, and say how many ledgers went.
 *
 * The ledgers, not the files: the assets on disk are his and are never deleted
 * by a settings panel. What this empties is the record that would make the next
 * run skip them — which is the difference the panel spells out between this and
 * the refetch switch.
 */
export function clearLedgersFor(userData: string, profileId: string): number {
  let gone = 0
  for (const runId of runsFor(userData, profileId)) {
    const path = ledgerPath(userData, runId)
    if (!existsSync(path)) continue
    try {
      rmSync(path, { force: true })
      ledgerCounts.delete(path)
      gone += 1
    } catch {
      // One that will not go is not a reason to leave the rest.
    }
  }
  batches.delete(profileId)
  return gone
}

/* ----------------------------------------------------------------- checks -- */

export interface CheckFacts {
  url: string
  stated: number | null
  got: number | null
  at: number
}

/**
 * The newest coverage check any of this profile's runs recorded.
 *
 * Newest by the check's own timestamp rather than by the folder's, because a run
 * resumed a day later appends to a log whose directory is older than a run that
 * started and finished this morning.
 */
export function lastCheckFor(userData: string, profileId: string): CheckFacts | null {
  let newest: CoverageCheck | null = null
  for (const runId of runsFor(userData, profileId)) {
    for (const check of readCoverage(coveragePath(userData, runId))) {
      if (newest === null || check.at > newest.at) newest = check
    }
  }
  if (newest === null) return null
  return {
    url: newest.url,
    // `stated` is already `number | null` in the engine and `null` there means
    // the pattern found nothing on the page. It travels as `null`, which is the
    // one case `coverageVerdict` refuses to call complete.
    stated: newest.stated,
    got: whole(newest.captured),
    at: newest.at,
  }
}

/** For tests, which must not inherit each other's tallies. */
export function resetScrapeStatusForTests(): void {
  batches.clear()
  ledgerCounts.clear()
}
