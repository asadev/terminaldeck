/**
 * The renderer's half of scraping — and, today, mostly a set of seams.
 *
 * ## What this file is for
 *
 * The scraping capability is being built as four separate things: durable worker
 * profiles and the session lift, per-resource-type request rules with passive
 * response capture, byte-exact assets with a resume ledger and its checks, and a
 * store that fetches a tool and verifies it before it can be installed. The
 * panel that shows all four (`ScrapingPanel.tsx`) is a fifth thing, and it was
 * written beside them rather than after them.
 *
 * So this module is **the contract**, and every method below is optional. Not
 * one of them is implemented under these names anywhere: the four lanes landed
 * and registered their channels under their own — `browserWorkers*`,
 * `browserStore*` — which is why `grep -c browserScraping src/preload/index.ts`
 * still answers `0`. {@link resolveScrapingApi} therefore does two things in
 * order: it binds any real `browserScraping*` a preload grows later, and then
 * lays `scraping-adapter.ts` underneath to answer the rest out of what the
 * lanes actually built.
 *
 * What the adapter cannot answer stays unanswered, and that is why the
 * availability predicates further down are not a formality: on a build where a
 * seam is unwired the panel draws that section as unavailable and draws no
 * control for it at all, because a control that appears to work and does
 * nothing is the exact defect the whole browser review is made of. Requests,
 * Capture, Assets and the coverage check are in that state today — their
 * engines exist, and they are reachable only from an agent's tool surface, not
 * from any channel a window can call.
 *
 * ## Optional, every method, for the reason the other bridges give
 *
 * `bridge.ts` refuses to resolve at all when one of `BRIDGE_METHODS` is missing,
 * which is right for the methods the panel cannot draw a pixel without and
 * catastrophic for a new one: a name added there blanks the whole browser panel
 * on every build whose preload predates it. `accounts-bridge.ts`,
 * `downloads-bridge.ts`, `draw-bridge.ts` and `drive-bridge.ts` all carry that
 * note. This is the fifth to take the same shape, and the one with the most
 * reason to: on the day it lands, *none* of it is wired.
 *
 * The types are the shape the panel asks for, and the engine side answers in it
 * — through the adapter today, directly on the day a preload grows these names.
 * They are written the way
 * `bridge.ts` asks feature types to cross: `unknown` over the wire, narrowed
 * here, never imported out of `src/main` (the renderer's tsconfig does not
 * include it).
 *
 * ## The one rule that shaped every type below
 *
 * **A count is a measured count or it is not shown.** He lost 48,473 assets to a
 * tool that skipped them and exited reporting success, and shipped 7% of a
 * dataset believing it complete. So every quantity that arrives from an engine
 * is `number | null` here, `null` means *nobody counted*, and the panel renders
 * that as "not measured" — never as 0, never as a dash that reads like a zero.
 * A reader that cannot understand an answer returns `null` rather than a
 * plausible default, and {@link readOutcome} turns an unreadable reply into a
 * failure rather than a success.
 */

import { adaptScrapingApi, type ScrapingHostContext } from './scraping-adapter'

export type { ScrapingHostContext }

/* ------------------------------------------------------------------ shape -- */

/** What a request rule can be, per resource type. */
export type RequestRule = 'allow' | 'block' | 'fulfill'

/**
 * The resource types a rule can be set for.
 *
 * Chromium's own list is longer (`ping`, `csp-report`, `websocket`, …). These
 * seven are the ones a scrape actually spends its money on, and a table with
 * twenty rows in it is a table nobody reads to the end of.
 */
export const RESOURCE_TYPES = [
  'image',
  'media',
  'font',
  'stylesheet',
  'script',
  'xhr',
  'fetch',
] as const

export type ResourceType = (typeof RESOURCE_TYPES)[number]

/**
 * The whole per-profile configuration, as the panel wants to read it.
 *
 * Every field is nullable and every group may be `null`, and both of those mean
 * the same thing: *this build did not say*. The panel draws "not set" and offers
 * the control; it never draws a default and calls it the current value, because
 * a setting invented on this side is a claim about an engine written on the
 * other.
 */
export interface ScrapingConfig {
  /** The fleet. Browser-wide rather than per profile — a worker *is* a profile. */
  fleet: FleetConfig | null
  requests: RequestRules | null
  capture: CaptureConfig | null
  assets: AssetsConfig | null
  checks: ChecksConfig | null
}

export interface FleetConfig {
  /** The profiles enrolled as workers, in the order the engine holds them. */
  profileIds: string[]
  /** How many may be working at once. */
  concurrency: number | null
  /** Milliseconds to wait between one worker's requests. */
  delayMs: number | null
}

/** A rule per resource type. An absent type is `null` — set by nobody, not "allow". */
export type RequestRules = Partial<Record<ResourceType, RequestRule | null>>

export interface CaptureConfig {
  /** Whether background XHR/fetch responses are recorded at all. */
  on: boolean | null
  /** Where they go. `''` when the engine did not say. */
  directory: string
  /** The bound, in megabytes, past which the oldest are dropped. */
  keepMB: number | null
}

export interface AssetsConfig {
  /** The rendition upgrade rule: rewrite an asset URL, fall back on 404. */
  upgrade: { on: boolean | null; from: string; to: string }
  /**
   * The resume ledger, keyed on URL *plus content digest*.
   *
   * `refetch` is the deliberate-refetch switch: on, the ledger is still written
   * but no longer skips, so a run goes and gets everything again.
   */
  ledger: { on: boolean | null; refetch: boolean | null }
}

export interface ChecksConfig {
  /**
   * The coverage self-check: a pattern that finds a page's own stated total, so
   * a run can be compared against what the page said it had.
   */
  coverage: { on: boolean | null; pattern: string }
}

/*
 * `screenshotOnBlock` used to be the second field of {@link ChecksConfig} and
 * is not one any more, which is the whole of this lane.
 *
 * It was declared here, drawn in the panel, and written into a patch that no
 * engine had ever read — while `browser-block-watch.ts` had been photographing
 * blocked pages all along, attached by `BrowserDrive.watch`, with no way to
 * stop it. Two halves of one feature that had never been introduced.
 *
 * It is not in the configuration group because there is no engine behind that
 * group: nothing in `src/main` stores a per-profile scraping configuration, and
 * a field riding along inside an object the panel cannot save would be the same
 * defect wearing this fix as a disguise. It has its own seam instead —
 * {@link ScrapingApi.browserBlockCapture} — which is two `ipcMain` handlers
 * that exist, so the switch is available exactly when it works.
 */

/**
 * A change to part of a configuration.
 *
 * Deep-partial on purpose, and the engine is expected to merge it group by group
 * rather than replace: two of these lanes write to the same stored object from
 * their own screens, and a panel that posted the whole configuration back would
 * quietly undo whatever it had not reloaded since. One control changes one
 * field, and the reply says what the whole of it now is.
 */
export interface ScrapingConfigPatch {
  fleet?: Partial<FleetConfig>
  requests?: RequestRules
  capture?: Partial<CaptureConfig>
  assets?: {
    upgrade?: Partial<AssetsConfig['upgrade']>
    ledger?: Partial<AssetsConfig['ledger']>
  }
  checks?: {
    coverage?: Partial<ChecksConfig['coverage']>
  }
}

/**
 * Everything measured, as against everything set.
 *
 * Kept apart from {@link ScrapingConfig} on purpose, and the split is the whole
 * discipline of this panel: a setting is what somebody asked for and a status is
 * what happened, and the moment those two are read out of one object the screen
 * starts reporting intentions as results.
 */
export interface ScrapingStatus {
  workers: WorkerState[]
  capture: CaptureStatus | null
  assets: AssetsStatus | null
  /** The most recent coverage check, or `null` when none has ever run. */
  lastCheck: CoverageCheck | null
}

export interface WorkerState {
  /** The engine's handle for this worker. */
  id: string
  /** The profile it runs in. */
  profileId: string
  state: 'idle' | 'busy' | 'starting' | 'stopped'
  /** Requests it has made. Measured, or `null` when the engine does not count. */
  requests: number | null
  /** When it last did anything, ms since the epoch, or `null`. */
  lastAt: number | null
}

export interface CaptureStatus {
  /** Responses recorded. */
  recorded: number | null
  /** Bytes they take on disk. */
  bytes: number | null
  /** Responses dropped because a bound was hit — the number he must be able to see. */
  dropped: number | null
  /** Which bound did it, in a few words. `''` when nothing was dropped or nobody said. */
  droppedReason: string
}

export interface AssetsStatus {
  fetched: number | null
  /** URLs the upgrade rule rewrote and that answered. */
  upgraded: number | null
  /** Upgrades that 404'd and came back as the original. */
  fellBack: number | null
  /** Assets the ledger skipped because URL *and* digest already matched. */
  skipped: number | null
  /** Rows in the ledger. */
  ledgerEntries: number | null
}

export interface CoverageCheck {
  /** The page checked. */
  url: string
  /** What the page said it had. `null` when the pattern found nothing. */
  stated: number | null
  /** What the run actually got. `null` when nobody counted. */
  got: number | null
  at: number
}

/**
 * A session lift somebody — or something — has asked for and nobody has granted.
 *
 * The lift itself is a human gesture and this is the mechanism that keeps it
 * one: an agent that wants a logged-in session copied into the workers does not
 * get to do it, it gets to *ask*, and the ask arrives here to be shown in the
 * panel with Approve and Decline beside it. Nothing in this file can approve
 * one, and {@link ScrapingApi.browserScrapingLiftAnswer} is called from exactly
 * one place: a button a person pressed.
 */
export interface LiftRequest {
  id: string
  /** Who asked, in words a person can recognise — a session name, usually. */
  askedBy: string
  fromProfileId: string
  intoProfileIds: string[]
  /** Why, if the asker said. `''` when it did not. */
  reason: string
  at: number
}

/** A tool in the store, as it is before anybody presses Install. */
export interface ToolListing {
  id: string
  name: string
  version: string
  publisher: string
  /**
   * What it may reach, one phrase per capability, in words.
   *
   * Shown *before* install, which is the whole point of it: a permission list
   * that appears after the code is on disk is a receipt, not a decision.
   */
  reach: string[]
  installed: boolean
  /** Whether the store could prove this is the tool it claims to be. */
  identity: ToolIdentity
  /** The digest that was checked, for the row to show. `''` when there is none. */
  digest: string
}

/**
 * The four answers to "is this the tool it says it is".
 *
 * `unverified` and `unknown` are kept apart because they are different facts: no
 * signature was offered, against a signature this build could not evaluate. Only
 * `verified` may install — see `canInstall` in `scraping-view.ts`.
 */
export type ToolIdentity = 'verified' | 'unverified' | 'mismatch' | 'unknown'

/**
 * What an act answers with.
 *
 * `count` is the measured half and it is nullable for the reason at the top of
 * this file: a lift that says "done" without saying how many cookies moved, and
 * an install that says "installed" without saying what it verified, are the two
 * shapes of the failure that cost him 48,473 assets.
 */
export interface ScrapingOutcome {
  ok: boolean
  message: string
  count: number | null
}

/* ------------------------------------------------------------------- seams -- */

/**
 * Every method the panel will call, and not one it implements.
 *
 * Grouped by the lane that owns it, because that is how they will be wired and
 * because a seam whose owner is unclear is a seam two people implement
 * differently. The comment above each group names it.
 */
export interface ScrapingApi {
  /* -- the configuration itself: one read, one write, per profile -------- */

  /**
   * The stored configuration for one profile.
   *
   * One read for all five groups rather than five reads, because the panel opens
   * once and shows them together, and because five round trips is five chances
   * for the screen to be half a profile's settings and half another's.
   */
  browserScrapingConfig?(profileId: string): Promise<unknown>
  /**
   * Store a patch of it, and answer with the configuration as it now stands.
   *
   * A patch rather than the whole object: two of these lanes write to this
   * configuration from their own screens as well, and a panel that sent the
   * whole thing back would silently undo whatever it had not reloaded.
   *
   * Answering with the new state rather than a boolean is what lets the panel
   * show what was *stored* rather than what was typed — a value the engine
   * clamped or refused has to appear clamped or refused on screen.
   */
  browserScrapingConfigSet?(profileId: string, patch: ScrapingConfigPatch): Promise<unknown>

  /* -- measured state, pushed and pulled --------------------------------- */

  browserScrapingStatus?(profileId: string): Promise<unknown>
  /** The push. Whole status each time, for the reason `browser:downloads` gives. */
  onBrowserScrapingStatus?(cb: (status: unknown) => void): () => void

  /* -- workers (scrape-workers) ------------------------------------------ */

  /** Enrol an existing profile as a worker. */
  browserScrapingWorkerAdd?(profileId: string): Promise<unknown>
  /** Retire one. The profile and everything in it stays; it stops being a worker. */
  browserScrapingWorkerRemove?(profileId: string): Promise<unknown>
  /**
   * Make worker profiles until there are this many in total.
   *
   * Separate from {@link browserScrapingWorkerAdd}, and the two are not
   * variants of one another: enrolling takes a profile that already exists —
   * one somebody has signed something into, or spent weeks warming up — and
   * this one *mints* fresh ones, which is the only workable way to stand up
   * eight of them at once. A total rather than a delta, because a field that
   * adds four every time it is pressed is a field somebody presses twice.
   *
   * It only ever adds. Nothing on this seam deletes a profile: whatever a site
   * decided about a worker is bound to that cookie jar and cannot be earned
   * again by making a new one.
   */
  browserScrapingWorkerMint?(total: number): Promise<unknown>

  /* -- the session lift (scrape-workers), human-initiated only ----------- */

  /**
   * Copy the logged-in session from one profile into the named workers.
   *
   * Called from one button, which a person pressed, twice. There is deliberately
   * no argument for "quietly", no batch form, and no variant that takes a
   * predicate instead of a list of ids: a lift is a named act between named
   * profiles or it is not this method.
   */
  browserScrapingLift?(fromProfileId: string, intoProfileIds: readonly string[]): Promise<unknown>
  /** Lifts asked for and not yet answered. */
  browserScrapingLiftRequests?(): Promise<unknown>
  /** Grant or refuse one. The only door, and it is behind a button. */
  browserScrapingLiftAnswer?(requestId: string, approve: boolean): Promise<unknown>
  /** A new request arrived while the panel is open. */
  onBrowserScrapingLiftRequest?(cb: (request: unknown) => void): () => void

  /* -- capture (scrape-capture) ------------------------------------------ */

  /** Throw away what has been captured for this profile. */
  browserScrapingCaptureClear?(profileId: string): Promise<unknown>
  /** Show the capture directory in the file manager. */
  browserScrapingCaptureReveal?(profileId: string): Promise<unknown>

  /* -- assets (scrape-assets) -------------------------------------------- */

  /**
   * Empty the resume ledger for this profile.
   *
   * Distinct from the refetch switch and both are offered, because they are
   * different acts: refetch goes and gets everything again while the ledger
   * keeps its rows, and this forgets what was ever fetched.
   */
  browserScrapingLedgerClear?(profileId: string): Promise<unknown>

  /* -- the tools store (browser-tools-store) ----------------------------- */

  /** What the store has, installed or not, with what each may reach. */
  browserScrapingTools?(): Promise<unknown>
  /**
   * Fetch, verify and install one.
   *
   * The verification is the store's, not the panel's — the panel refuses to
   * *offer* Install for anything not already `verified`, which is a second lock
   * on the same door and not the door itself.
   */
  browserScrapingToolInstall?(toolId: string): Promise<unknown>
  browserScrapingToolRemove?(toolId: string): Promise<unknown>

  /* -- the block camera (browser-block-watch) ---------------------------- */

  /**
   * Is this profile's browser photographing the pages that refuse it?
   *
   * Its own pair rather than a field of the configuration, and the note above
   * {@link ChecksConfig} says why: this one has an engine and that object does
   * not, so binding them together would make an available control out of an
   * unavailable one.
   */
  browserBlockCapture?(profileId: string): Promise<unknown>
  /** Turn it off, or back on. Answers with what is now stored, not with `true`. */
  browserBlockCaptureSet?(profileId: string, on: boolean): Promise<unknown>
}

const METHODS = [
  'browserScrapingConfig',
  'browserScrapingConfigSet',
  'browserScrapingStatus',
  'onBrowserScrapingStatus',
  'browserScrapingWorkerAdd',
  'browserScrapingWorkerRemove',
  'browserScrapingWorkerMint',
  'browserScrapingLift',
  'browserScrapingLiftRequests',
  'browserScrapingLiftAnswer',
  'onBrowserScrapingLiftRequest',
  'browserScrapingCaptureClear',
  'browserScrapingCaptureReveal',
  'browserScrapingLedgerClear',
  'browserScrapingTools',
  'browserScrapingToolInstall',
  'browserScrapingToolRemove',
  'browserBlockCapture',
  'browserBlockCaptureSet',
] as const satisfies readonly (keyof ScrapingApi)[]

/**
 * Bind whatever of the seam this build has, and adapt the rest out of what the
 * lanes actually shipped.
 *
 * Two layers, in this order, and the order is the whole design:
 *
 *  1. **The real names first.** Method by method, exactly as `resolveDriveApi`
 *     does it, so a preload older than any one lane contributes what it has and
 *     nothing else — and so the availability answers below can each be one
 *     honest check instead of a `typeof` at every call site. The day a preload
 *     grows `browserScrapingConfig`, that engine wins outright and nothing
 *     below it is consulted for that method.
 *  2. **The adapter underneath.** `scraping-adapter.ts` answers what it can out
 *     of `browserWorkers*` and `browserStore*`, which is what those four lanes
 *     registered. It fills a gap and never covers a real method.
 *
 * A seam neither layer can answer stays absent, which is the point: the panel
 * turns each absence into a named, unavailable section rather than a control
 * that does nothing.
 *
 * `context` carries the one thing a bridge resolved off `window.deck` cannot
 * know — the id of the page in front of the person — and without it the lift is
 * simply not offered, because a lift with no page is not this gesture.
 */
export function resolveScrapingApi(host?: unknown, context?: ScrapingHostContext): ScrapingApi {
  const source =
    host ??
    (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  const adapted = adaptScrapingApi(source, context) as Record<string, unknown>
  for (const name of METHODS) {
    const value = adapted[name]
    if (api[name] === undefined && typeof value === 'function') api[name] = value
  }
  return api as ScrapingApi
}

/* ---------------------------------------------------------- availability -- */

/**
 * Can this build show and change a scraping configuration at all?
 *
 * The read and the write together, and neither on its own: a panel that can show
 * settings it cannot change is a screen that cannot act, and one that can write
 * settings it cannot read back would be a panel whose every control is a guess
 * about what it just did.
 */
export function scrapingConfigAvailable(api: ScrapingApi): boolean {
  return (
    typeof api.browserScrapingConfig === 'function' &&
    typeof api.browserScrapingConfigSet === 'function'
  )
}

/**
 * Can it report what actually happened?
 *
 * Pull and push, for the reason `downloadsAvailable` gives about its two: with
 * only the pull the numbers on screen are as old as the last time the panel was
 * opened, and a stale measured count is worse than none — it is the same lie
 * with a timestamp.
 */
/**
 * Can this build turn the block camera off, and say what it is doing now?
 *
 * Both, and neither alone, for the reason `scrapingConfigAvailable` gives about
 * its two — with an edge this one does not share. What is being switched
 * produces nothing visible when it is on: no window, no progress, no count. A
 * switch that could be written and not read back would show whichever position
 * it was last clicked into, on a feature whose real state nobody can see, which
 * is worse than no switch at all.
 */
export function blockCaptureAvailable(api: ScrapingApi): boolean {
  return (
    typeof api.browserBlockCapture === 'function' &&
    typeof api.browserBlockCaptureSet === 'function'
  )
}

export function scrapingStatusAvailable(api: ScrapingApi): boolean {
  return (
    typeof api.browserScrapingStatus === 'function' &&
    typeof api.onBrowserScrapingStatus === 'function'
  )
}

/** Can workers be enrolled and retired? Both, or the section offers neither. */
export function workersAvailable(api: ScrapingApi): boolean {
  return (
    typeof api.browserScrapingWorkerAdd === 'function' &&
    typeof api.browserScrapingWorkerRemove === 'function'
  )
}

/**
 * Can fresh workers be made?
 *
 * Its own answer rather than part of {@link workersAvailable}, because the two
 * are genuinely separable: a build that can enrol the profiles somebody already
 * has and cannot mint new ones is still a usable fleet screen, and it should
 * draw the enrol control and no mint field rather than neither.
 */
export function mintAvailable(api: ScrapingApi): boolean {
  return typeof api.browserScrapingWorkerMint === 'function'
}

/** Can a session be lifted by hand? */
export function liftAvailable(api: ScrapingApi): boolean {
  return typeof api.browserScrapingLift === 'function'
}

/**
 * Can the panel show what has been *asked for* and answer it?
 *
 * All three, because two of them make a trap: an inbox that can list requests
 * and not answer them leaves an agent's ask sitting on screen with no way to
 * refuse it, and a build that can answer but never lists has an approval path
 * nobody can see.
 */
export function liftRequestsAvailable(api: ScrapingApi): boolean {
  return (
    typeof api.browserScrapingLiftRequests === 'function' &&
    typeof api.browserScrapingLiftAnswer === 'function' &&
    typeof api.onBrowserScrapingLiftRequest === 'function'
  )
}

/**
 * Is the store wired?
 *
 * List, install and remove. Install without remove is a one-way door, and this
 * app's rule about those is written across `FEATURE-STORE.md`: whatever can be
 * put in has to be able to come out.
 */
export function storeAvailable(api: ScrapingApi): boolean {
  return (
    typeof api.browserScrapingTools === 'function' &&
    typeof api.browserScrapingToolInstall === 'function' &&
    typeof api.browserScrapingToolRemove === 'function'
  )
}

/* ---------------------------------------------------------------- reading -- */

/**
 * Everything below narrows a shape that came from this app's own main process,
 * which is not a trust boundary — it is the discipline every other `unknown` on
 * this side gets, and it is what makes an older or newer engine a quiet
 * "not measured" instead of a crash inside an effect.
 */

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

/** A count, or `null` for anything that is not one. Never a fallback to zero. */
export function readCount(raw: unknown): number | null {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0) return null
  return Math.floor(raw)
}

/** A stored boolean, or `null` for "this build did not say". */
export function readFlag(raw: unknown): boolean | null {
  return typeof raw === 'boolean' ? raw : null
}

function group(raw: unknown, key: string): Record<string, unknown> | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = (raw as Record<string, unknown>)[key]
  if (typeof value !== 'object' || value === null) return null
  return value as Record<string, unknown>
}

export function readRequestRule(raw: unknown): RequestRule | null {
  return raw === 'allow' || raw === 'block' || raw === 'fulfill' ? raw : null
}

function readFleet(raw: unknown): FleetConfig | null {
  const value = group(raw, 'fleet')
  if (!value) return null
  const ids = Array.isArray(value.profileIds)
    ? value.profileIds.filter((id): id is string => typeof id === 'string' && id !== '')
    : []
  return {
    profileIds: ids,
    concurrency: readCount(value.concurrency),
    delayMs: readCount(value.delayMs),
  }
}

function readRequestRules(raw: unknown): RequestRules | null {
  const value = group(raw, 'requests')
  if (!value) return null
  const rules: RequestRules = {}
  for (const type of RESOURCE_TYPES) rules[type] = readRequestRule(value[type])
  return rules
}

function readCapture(raw: unknown): CaptureConfig | null {
  const value = group(raw, 'capture')
  if (!value) return null
  return { on: readFlag(value.on), directory: text(value.directory), keepMB: readCount(value.keepMB) }
}

function readAssets(raw: unknown): AssetsConfig | null {
  const value = group(raw, 'assets')
  if (!value) return null
  const upgrade = group(value, 'upgrade')
  const ledger = group(value, 'ledger')
  return {
    upgrade: {
      on: readFlag(upgrade?.on),
      from: text(upgrade?.from),
      to: text(upgrade?.to),
    },
    ledger: { on: readFlag(ledger?.on), refetch: readFlag(ledger?.refetch) },
  }
}

function readChecks(raw: unknown): ChecksConfig | null {
  const value = group(raw, 'checks')
  if (!value) return null
  const coverage = group(value, 'coverage')
  return {
    coverage: { on: readFlag(coverage?.on), pattern: text(coverage?.pattern) },
  }
}

/**
 * The stored configuration, or `null` when there is nothing readable in it.
 *
 * `null` and "all five groups absent" are the same answer and are collapsed into
 * one deliberately: an engine that replies `{}` has told the panel nothing, and
 * a panel holding an object of five nulls would draw five sections of "not set"
 * as though somebody had a choice to make. Unavailable is the truer word for it.
 */
export function readScrapingConfig(raw: unknown): ScrapingConfig | null {
  if (typeof raw !== 'object' || raw === null) return null
  const config: ScrapingConfig = {
    fleet: readFleet(raw),
    requests: readRequestRules(raw),
    capture: readCapture(raw),
    assets: readAssets(raw),
    checks: readChecks(raw),
  }
  const empty =
    config.fleet === null &&
    config.requests === null &&
    config.capture === null &&
    config.assets === null &&
    config.checks === null
  return empty ? null : config
}

function readWorkerState(raw: unknown): WorkerState['state'] {
  // Anything unrecognised is `stopped` rather than `idle`: "idle" says a worker
  // is up and waiting, which is a claim, and "stopped" says it is not working,
  // which is the safe half of the truth in every case where the engine's word
  // could not be read.
  return raw === 'idle' || raw === 'busy' || raw === 'starting' ? raw : 'stopped'
}

export function readScrapingStatus(raw: unknown): ScrapingStatus | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  const workers: WorkerState[] = []
  if (Array.isArray(value.workers)) {
    for (const entry of value.workers) {
      if (typeof entry !== 'object' || entry === null) continue
      const record = entry as Record<string, unknown>
      if (typeof record.profileId !== 'string' || record.profileId === '') continue
      workers.push({
        id: text(record.id),
        profileId: record.profileId,
        state: readWorkerState(record.state),
        requests: readCount(record.requests),
        lastAt: readCount(record.lastAt),
      })
    }
  }
  const capture = group(value, 'capture')
  const assets = group(value, 'assets')
  const check = group(value, 'lastCheck')
  return {
    workers,
    capture: capture
      ? {
          recorded: readCount(capture.recorded),
          bytes: readCount(capture.bytes),
          dropped: readCount(capture.dropped),
          droppedReason: text(capture.droppedReason),
        }
      : null,
    assets: assets
      ? {
          fetched: readCount(assets.fetched),
          upgraded: readCount(assets.upgraded),
          fellBack: readCount(assets.fellBack),
          skipped: readCount(assets.skipped),
          ledgerEntries: readCount(assets.ledgerEntries),
        }
      : null,
    lastCheck:
      check && typeof check.url === 'string' && check.url !== ''
        ? {
            url: check.url,
            stated: readCount(check.stated),
            got: readCount(check.got),
            at: readCount(check.at) ?? 0,
          }
        : null,
  }
}

export function readLiftRequests(raw: unknown): LiftRequest[] {
  if (!Array.isArray(raw)) return []
  const out: LiftRequest[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    // An id and a source are what an answer needs; without either there is
    // nothing a button could be wired to, and a row that cannot be answered is
    // worse on this screen than a row that is missing.
    if (typeof record.id !== 'string' || record.id === '') continue
    if (typeof record.fromProfileId !== 'string' || record.fromProfileId === '') continue
    const into = Array.isArray(record.intoProfileIds)
      ? record.intoProfileIds.filter((id): id is string => typeof id === 'string' && id !== '')
      : []
    if (into.length === 0) continue
    out.push({
      id: record.id,
      askedBy: text(record.askedBy),
      fromProfileId: record.fromProfileId,
      intoProfileIds: into,
      reason: text(record.reason),
      at: readCount(record.at) ?? 0,
    })
  }
  return out
}

function readIdentity(raw: unknown): ToolIdentity {
  // Unreadable is `unknown`, which cannot install. The default is the one that
  // refuses, so a store that answers in a shape this build does not understand
  // costs a person an install they can retry — never an install they cannot undo.
  return raw === 'verified' || raw === 'unverified' || raw === 'mismatch' ? raw : 'unknown'
}

export function readToolListings(raw: unknown): ToolListing[] {
  if (!Array.isArray(raw)) return []
  const out: ToolListing[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.id !== 'string' || record.id === '') continue
    out.push({
      id: record.id,
      name: text(record.name) === '' ? record.id : text(record.name),
      version: text(record.version),
      publisher: text(record.publisher),
      reach: Array.isArray(record.reach)
        ? record.reach.filter((line): line is string => typeof line === 'string' && line !== '')
        : [],
      installed: record.installed === true,
      identity: readIdentity(record.identity),
      digest: text(record.digest),
    })
  }
  return out
}

/**
 * What an act answered, read so that silence is never success.
 *
 * An engine that replies with something this build cannot read has not told the
 * panel a lift happened, and the panel will not say one did. `ok` is `true` for
 * exactly one shape — the literal `true` — and everything else, including a
 * missing field, a truthy string and a rejected promise handled upstream, comes
 * back as a failure carrying a sentence somebody can act on.
 */
export function readOutcome(raw: unknown): ScrapingOutcome {
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, message: 'No answer came back, so nothing here is confirmed.', count: null }
  }
  const value = raw as Record<string, unknown>
  const ok = value.ok === true
  const message = text(value.message)
  return {
    ok,
    message:
      message !== ''
        ? message
        : ok
          ? 'Done.'
          : 'It did not say what went wrong.',
    count: readCount(value.count),
  }
}
