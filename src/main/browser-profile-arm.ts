import { app } from 'electron'
import { logger } from './app-log'
import { statedTotal, compareCoverage, recordCoverage } from './browser-asset-coverage'
import { attachBlockWatch } from './browser-block-watch'
import { imageSizeScript } from './browser-capture-script'
import {
  CaptureStore,
  captureDir,
  defaultBounds,
  type CaptureBounds,
} from './browser-capture-store'
import { maskRects } from './browser-driven-electron'
import { SECRET_RECTS_SCRIPT, TEXT_SCRIPT, withArgs } from './browser-drive-script'
import { interceptedKinds, type FetchRules } from './browser-fetch-rules'
import { PageNetwork, type NetworkTransport } from './browser-network'
import { blockShotDirFor, coveragePath } from './browser-scrape-paths'
import {
  captureBoundsOf,
  coveragePatternOf,
  fetchRulesOf,
  onScrapeSettingsChanged,
  scrapeSettingsFor,
  type ScrapeSettings,
} from './browser-scrape-settings'
import { noteRunProfile } from './browser-scrape-status'

/**
 * The person's stored scraping settings, made true of the person's own pages.
 *
 * ## The defect this closes
 *
 * The Scraping panel stores answers per profile — fulfil images, record
 * background responses, keep this many megabytes, photograph blocks, check
 * coverage with this pattern — and until this module existed those answers were
 * read at exactly one moment: when an **agent tool** armed a page.
 * `browser-driver.ts:armNetwork` had one non-test caller,
 * `deck-control/browser-network-tool.ts`, so a person who set Images to
 * Fulfill and switched capture On got *nothing*: no debugger, no capture
 * store, no placeholders, no block camera. Every control on that panel looked
 * like it worked and did not — the exact defect Asad's own scraping rule
 * names, and the one the whole panel was rebuilt to remove.
 *
 * So: `browser-tab.ts` hands every real-profile tab to {@link
 * watchTabForScraping}, and when the tab commits a navigation this module asks
 * the profile's stored settings whether anything is wanted. If something is,
 * the page is armed with **the same machinery the agent tool arms** — a
 * {@link PageNetwork} over the tab's own CDP debugger, a {@link CaptureStore}
 * under `browser-captures/<profile>/browse-…`, the block camera of
 * `browser-block-watch.ts`, and the coverage arithmetic of
 * `browser-asset-coverage.ts`. When every setting is at its default, nothing
 * attaches: no debugger, no camera, no cost — a profile that has said nothing
 * browses exactly as it always did.
 *
 * ## What arming costs, stated plainly
 *
 * Arming attaches Chromium's debugger to the tab. That is not free: DevTools'
 * network domain observes every response, an intercepted kind takes a round
 * trip through this process per request, and some sites detect an attached
 * debugger and behave differently. The trade is the person's own — they asked
 * for it on the panel, per profile — and the way out is one toggle: set the
 * rules back to *not set* and capture Off, and the next event disarms and
 * detaches. A profile with all-default settings never pays any of it.
 *
 * ## Who holds the page: this module yields to the drive, always
 *
 * The rest of the app treats *"the CDP debugger is attached"* as *"an agent
 * holds this page"* — it is what gates password autofill
 * (`browser-fill-gate.ts`) and stamps `documentFromAgent`. This module's
 * attachment is **not** an agent, and `browser-tab.ts` subtracts it through
 * {@link personArmHolds}, which answers true only while this module's own
 * attachment is the sole reason the debugger is on.
 *
 * The subtraction is safe because the yielding is structural:
 *
 *  - the drive's `attach()` — the only other `debugger.attach` in the
 *    repository — calls {@link pageHeldByDrive} before it does anything else,
 *    which disarms this module's run and marks the tab held, so by the time an
 *    agent can send a command the page is an agent's page in every reader's
 *    eyes;
 *  - this module never arms a page whose debugger somebody else attached: an
 *    already-attached debugger it did not attach is treated as held;
 *  - `detach()` calls {@link pageFreedByDrive}, and only then does this module
 *    reclaim the page, re-arming if the settings still ask for it.
 *
 * ## The one door for commands, and what may go through it
 *
 * `browser-cdp.ts` screens every command the *drive* sends by the baton. This
 * module's commands are not a model's — no tool call reaches here, only the
 * person's own stored configuration — so the screen is a fixed allowlist
 * instead: exactly the methods {@link PageNetwork} itself issues, refused by
 * name otherwise. There is one `sendCommand` call site in this file and the
 * allowlist stands in front of it; `browser-cdp.test.ts` pins both, the same
 * way it pins the drive's.
 */

/* ------------------------------------------------------------ the decision -- */

/** What one profile's stored settings ask to happen on its pages. */
export interface PersonArming {
  /** The stored request rules, aliases resolved. May be all-allow. */
  rules: FetchRules
  /** Record background responses into a capture store. */
  capture: boolean
  /** The stored byte budget inside the engine's other bounds, or the defaults. */
  bounds: CaptureBounds
  /** Photograph pages that refuse us — see `browser-block-watch.ts`. */
  camera: boolean
  /** The stored coverage pattern, `''` when the check is off or unset. */
  coveragePattern: string
}

/**
 * What this profile's settings want, or `null` when they want nothing.
 *
 * `null` is the all-default answer and it is the load-bearing one: it is what
 * guarantees a profile nobody configured attaches nothing. The rules:
 *
 *  - the **debugger** is wanted only when a stored rule blocks or fulfills
 *    something, or capture is explicitly On. Stored `allow` rules and a stored
 *    byte budget on their own change nothing, so they arm nothing.
 *  - the **camera** follows the drive's own default *on an armed page*
 *    (`screenshotOnBlock !== false`, the default every install has had), but on
 *    a page that is not otherwise armed it requires an explicit `true` —
 *    because for an unarmed page the camera is the only thing running, and
 *    "nobody said" must not be the reason a person's browsing gets photographed.
 *  - **coverage** runs only inside a capture run: the check is recorded into
 *    the run's own folder, and with capture off there is no run to file it
 *    under and no captured count to compare.
 */
export function personArming(settings: ScrapeSettings): PersonArming | null {
  const rules = fetchRulesOf(settings) ?? {}
  const capture = settings.capture.on === true
  const debuggerWanted = interceptedKinds(rules).length > 0 || capture
  const camera = debuggerWanted
    ? settings.checks.screenshotOnBlock !== false
    : settings.checks.screenshotOnBlock === true
  if (!debuggerWanted && !camera) return null
  return {
    rules,
    capture,
    bounds: captureBoundsOf(settings) ?? defaultBounds(),
    camera,
    coveragePattern: capture ? coveragePatternOf(settings) : '',
  }
}

/** Whether this arming needs the debugger at all. */
function needsDebugger(arming: PersonArming): boolean {
  return interceptedKinds(arming.rules).length > 0 || arming.capture
}

/** One string that changes exactly when the armed configuration would. */
function fingerprintOf(arming: PersonArming): string {
  return JSON.stringify({
    rules: arming.rules,
    capture: arming.capture,
    bounds: arming.bounds,
    coverage: arming.coveragePattern,
  })
}

/* --------------------------------------------------------------- the wire -- */

/**
 * The little of a `WebContents` this module touches, stated structurally so a
 * test can drive it with a plain object — the same argument
 * `browser-block-watch.ts` makes for {@link BlockWatchTarget}.
 */
export interface ArmTarget {
  isDestroyed(): boolean
  getURL(): string
  getTitle(): string
  on(event: string, listener: (...args: never[]) => void): unknown
  once(event: string, listener: (...args: never[]) => void): unknown
  capturePage(): Promise<Electron.NativeImage>
  executeJavaScriptInIsolatedWorld(
    worldId: number,
    scripts: { code: string }[],
  ): Promise<unknown>
  debugger: {
    isAttached(): boolean
    attach(protocolVersion?: string): void
    detach(): void
    sendCommand(method: string, commandParams?: unknown): Promise<unknown>
    on(event: 'message', listener: (event: unknown, method: string, params: unknown) => void): unknown
    off(event: 'message', listener: (event: unknown, method: string, params: unknown) => void): unknown
  }
}

/**
 * A world of this module's own, beside the drive's `31_017`.
 *
 * Distinct so that nothing this module defines can collide with what the drive
 * keeps in its world on the same page; arbitrary and high for the reason the
 * drive's is.
 */
const PERSON_WORLD = 31_018

/**
 * Every method this module may send, by name — the exact set
 * {@link PageNetwork} issues and nothing else. See the header: this is the
 * screen in front of the one `sendCommand` call site in this file.
 */
const PERSON_METHODS: ReadonlySet<string> = new Set([
  'Network.enable',
  'Network.disable',
  'Network.getResponseBody',
  'Fetch.enable',
  'Fetch.disable',
  'Fetch.continueRequest',
  'Fetch.failRequest',
  'Fetch.fulfillRequest',
])

/* ---------------------------------------------------------------- the state -- */

export interface PersonArmDeps {
  userData(): string
  now(): number
  /** The stored settings for a profile. Injected so a test needs no disk. */
  settings(profileId: string): ScrapeSettings
}

let injected: PersonArmDeps | null = null

/** For tests. `null` restores the real store and clock. */
export function setPersonArmDepsForTests(deps: PersonArmDeps | null): void {
  injected = deps
}

function depsNow(): PersonArmDeps {
  if (injected !== null) return injected
  return {
    userData: () => app.getPath('userData'),
    now: () => Date.now(),
    settings: (profileId: string) => scrapeSettingsFor(app.getPath('userData'), profileId),
  }
}

interface Entry {
  tabId: string
  profileId: string
  wc: ArmTarget
  /** The drive holds this page; everything here stands down until freed. */
  held: boolean
  /** This module attached the debugger — the fact `personArmHolds` reports. */
  weAttached: boolean
  network: PageNetwork | null
  offEvents: (() => void) | null
  fingerprint: string
  runId: string
  /** The last committed main-frame URL, `''` before the first. */
  pageUrl: string
  /** The store's entry count when the current page committed. */
  entriesAtPage: number
  cameraAttached: boolean
  coverageBusy: boolean
  gone: boolean
  /** Serializes arm/disarm/reconcile so two events cannot interleave them. */
  queue: Promise<void>
}

const byTab = new Map<string, Entry>()
const byContents = new Map<object, Entry>()
let runSeq = 0
let listening = false

/** For tests, which must not inherit each other's tabs. */
export function resetPersonArmForTests(): void {
  byTab.clear()
  byContents.clear()
  runSeq = 0
  listening = false
}

/* ------------------------------------------------------- the public answers -- */

/**
 * Is this page's debugger attached by this module alone?
 *
 * Read by `browser-tab.ts:agentHolds`, which otherwise treats *attached* as
 * *an agent holds this page* — the fact that withholds password autofill and
 * stamps `documentFromAgent`. True only while this module made the attachment
 * **and** no drive has claimed the page since; the moment the drive's
 * `attach()` runs, {@link pageHeldByDrive} has flipped `held` and this answers
 * false — so the safe direction is preserved: a page an agent could act on is
 * never reported as merely person-armed.
 */
export function personArmHolds(contents: unknown): boolean {
  if (typeof contents !== 'object' || contents === null) return false
  const entry = byContents.get(contents)
  return entry !== undefined && entry.weAttached && !entry.held
}

/**
 * The drive took this page. Called from `browser-driver.ts:attach`, before the
 * drive does anything else with the debugger.
 *
 * The standing run is disarmed — its summary closed and written, its `Fetch`
 * and `Network` domains disabled so the drive starts from the state it has
 * always started from — and the debugger is left attached for the drive to
 * co-use. Nothing here re-arms until {@link pageFreedByDrive}.
 */
export function pageHeldByDrive(tabId: string): void {
  const entry = byTab.get(tabId)
  if (entry === undefined || entry.held) return
  entry.held = true
  enqueue(entry, async () => {
    await stopRun(entry, 'an agent claimed the page')
  })
}

/** The drive let go. Reclaim the page if the settings still ask for anything. */
export function pageFreedByDrive(tabId: string): void {
  const entry = byTab.get(tabId)
  if (entry === undefined || !entry.held) return
  entry.held = false
  // The drive detached the debugger on its way out, whoever attached it.
  entry.weAttached = false
  enqueue(entry, () => reconcile(entry))
}

/* ------------------------------------------------------------- the watching -- */

/**
 * Watch one browser tab for the life of its view.
 *
 * Called by `browser-tab.ts` for every tab it builds in a real profile. Until
 * the profile stores something, the whole cost is the two navigation listeners
 * this registers — no debugger, no camera, nothing on the wire.
 */
export function watchTabForScraping(input: {
  tabId: string
  profileId: string
  contents: ArmTarget
}): void {
  if (input.profileId === '') return
  const entry: Entry = {
    tabId: input.tabId,
    profileId: input.profileId,
    wc: input.contents,
    held: false,
    weAttached: false,
    network: null,
    offEvents: null,
    fingerprint: '',
    runId: '',
    pageUrl: '',
    entriesAtPage: 0,
    cameraAttached: false,
    coverageBusy: false,
    gone: false,
    queue: Promise.resolve(),
  }
  byTab.set(entry.tabId, entry)
  byContents.set(input.contents, entry)
  listen()

  entry.wc.on('did-navigate', ((_event: unknown, url: unknown) => {
    entry.pageUrl = typeof url === 'string' ? url : ''
    if (entry.network !== null) {
      // A new page under the same run: remember where its captures start, so
      // the coverage check below compares this page against its own traffic.
      entry.entriesAtPage = entry.network.status().captured?.entries ?? 0
    }
    enqueue(entry, () => reconcile(entry))
  }) as (...args: never[]) => void)

  entry.wc.on('did-stop-loading', (() => {
    void coverageCheck(entry)
  }) as (...args: never[]) => void)

  entry.wc.once('destroyed', (() => {
    entry.gone = true
    // No commands to a dead page — the books close without sending anything,
    // and the summary of anything captured is still written. See
    // `PageNetwork.abandon`.
    entry.network?.abandon('the tab closed')
    entry.network = null
    entry.offEvents?.()
    entry.offEvents = null
    byTab.delete(entry.tabId)
    byContents.delete(entry.wc)
  }) as (...args: never[]) => void)

  /*
   * The camera goes on *now* when the profile already asks for it, not on the
   * queue: `attachBlockWatch` judges a navigation from events it saw start,
   * so a camera attached after the first `did-navigate` would miss the first
   * refusal — and the first page of a run is the one most likely to be the
   * wall. A camera wanted only later, by a toggle flip, is attached by the
   * reconcile that flip triggers and catches every navigation after it.
   */
  const arming = personArming(depsNow().settings(entry.profileId))
  if (arming?.camera === true) attachCamera(entry)

  // The tab may already be somewhere: `browser:create` navigates before this
  // module's listener could see it in some orders. Reconcile once at watch.
  const url = safeUrl(entry.wc)
  if (url !== '') {
    entry.pageUrl = url
    enqueue(entry, () => reconcile(entry))
  }
}

/** One listener for the whole store, replaced idempotently on every watch. */
function listen(): void {
  if (listening) return
  listening = true
  onScrapeSettingsChanged((profileId) => {
    for (const entry of byTab.values()) {
      if (entry.profileId !== profileId) continue
      enqueue(entry, () => reconcile(entry))
    }
  })
}

function enqueue(entry: Entry, step: () => Promise<void>): void {
  entry.queue = entry.queue.then(step).catch((error) => {
    logger.warn(
      'scraping',
      `arming ${entry.profileId} failed: ${error instanceof Error ? error.message : String(error)}`,
    )
  })
}

/* ------------------------------------------------------------ the reconcile -- */

function isHttp(url: string): boolean {
  return /^https?:/i.test(url)
}

function safeUrl(wc: ArmTarget): string {
  try {
    return wc.isDestroyed() ? '' : wc.getURL()
  } catch {
    return ''
  }
}

function safeTitle(wc: ArmTarget): string {
  try {
    return wc.isDestroyed() ? '' : wc.getTitle()
  } catch {
    return ''
  }
}

/**
 * Make the page match what its profile's settings say, right now.
 *
 * Runs on every committed navigation, on every settings write for the profile,
 * and when the drive lets go. Always on the entry's queue, so an arm and a
 * disarm can never interleave.
 */
async function reconcile(entry: Entry): Promise<void> {
  if (entry.gone || entry.held || entry.wc.isDestroyed()) return
  const deps = depsNow()
  const arming = personArming(deps.settings(entry.profileId))

  if (arming?.camera === true) attachCamera(entry)

  const url = entry.pageUrl !== '' ? entry.pageUrl : safeUrl(entry.wc)
  const wanted = arming !== null && needsDebugger(arming) && isHttp(url)

  if (!wanted) {
    if (entry.network !== null) {
      await stopRun(entry, "the profile's scraping settings were turned back to defaults")
    }
    return
  }
  const fingerprint = fingerprintOf(arming)
  if (entry.network !== null && entry.fingerprint === fingerprint) return
  if (entry.network !== null) {
    await stopRun(entry, "the profile's scraping settings changed, so a fresh run was started")
  }
  await startRun(entry, arming, deps)
}

async function startRun(entry: Entry, arming: PersonArming, deps: PersonArmDeps): Promise<void> {
  const wc = entry.wc
  if (wc.isDestroyed() || entry.held) return
  try {
    if (!wc.debugger.isAttached()) {
      wc.debugger.attach('1.3')
      entry.weAttached = true
    } else if (!entry.weAttached) {
      /*
       * Somebody else's attachment — the drive's, on a path where its hook has
       * not reached this entry yet, or a devtools session. Arming on top of it
       * would put two answerers on one paused request; standing down loses one
       * page of capture and corrupts nothing.
       */
      entry.held = true
      return
    }
  } catch (error) {
    logger.warn(
      'scraping',
      `could not attach to a ${entry.profileId} page to apply its scraping settings: ${
        error instanceof Error ? error.message : String(error)
      }`,
    )
    return
  }

  const transport: NetworkTransport = {
    send: async (method, params = {}) => {
      // The allowlist in front of the one sendCommand in this file — header.
      if (!PERSON_METHODS.has(method)) {
        throw new Error(`${method} is not a command profile arming may send`)
      }
      const out = await wc.debugger.sendCommand(method, params)
      return typeof out === 'object' && out !== null ? (out as Record<string, unknown>) : {}
    },
    onEvent: (handler) => {
      const listener = (_event: unknown, method: string, params: unknown): void => {
        handler(
          method,
          typeof params === 'object' && params !== null ? (params as Record<string, unknown>) : {},
        )
      }
      wc.debugger.on('message', listener)
      return () => {
        try {
          wc.debugger.off('message', listener)
        } catch {
          // The page is gone and took its emitter with it.
        }
      }
    },
    sizeOf: (url) =>
      wc.executeJavaScriptInIsolatedWorld(PERSON_WORLD, [{ code: imageSizeScript(url) }]),
    now: () => deps.now(),
  }

  let store: CaptureStore | null = null
  if (arming.capture) {
    runSeq += 1
    const runId = `browse-${deps.now()}-${runSeq}`
    const made = new CaptureStore(
      captureDir(deps.userData(), entry.profileId, runId),
      arming.bounds,
      { now: () => deps.now() },
    )
    try {
      made.open()
      store = made
      entry.runId = runId
      // Filed under its profile the same way an agent's run is, so the
      // panel's Checks section can find the coverage log after a restart.
      noteRunProfile(deps.userData(), runId, entry.profileId)
    } catch (error) {
      /*
       * The disk refused the folder and there is no caller to refuse to. The
       * rules still arm — they cost the person nothing to lose — and the
       * failure is written where the app writes its own faults rather than
       * swallowed. A capture switch that silently recorded nothing is the
       * defect this module exists to remove, so it must not reproduce it.
       */
      logger.error(
        'scraping',
        `capture is on for ${entry.profileId} but its folder could not be made, so this run records ` +
          `nothing: ${error instanceof Error ? error.message : String(error)}`,
      )
    }
  }

  if (store === null && interceptedKinds(arming.rules).length === 0) {
    // Capture was the only thing wanted and it cannot write. Arming now would
    // arm nothing — undo the attachment rather than hold a debugger for show.
    if (entry.weAttached) {
      try {
        if (wc.debugger.isAttached()) wc.debugger.detach()
      } catch {
        // Already gone.
      }
      entry.weAttached = false
    }
    return
  }

  const network = new PageNetwork(transport)
  await network.arm({
    rules: arming.rules,
    capture: store === null ? null : { store, bodyKinds: new Set(['xhr', 'fetch']) },
  })
  network.notePage({ url: safeUrl(wc), title: safeTitle(wc), armed: true })
  entry.network = network
  entry.fingerprint = fingerprintOf(arming)
  entry.entriesAtPage = 0
}

async function stopRun(entry: Entry, why: string): Promise<void> {
  const network = entry.network
  entry.network = null
  entry.fingerprint = ''
  if (network !== null) {
    network.notePage({ url: safeUrl(entry.wc), title: safeTitle(entry.wc) })
    try {
      await network.disarm(why)
    } catch (error) {
      // The page may have gone mid-disarm; the books are closed either way.
      logger.warn(
        'scraping',
        `disarming a ${entry.profileId} page: ${error instanceof Error ? error.message : String(error)}`,
      )
    }
  }
  if (entry.weAttached && !entry.held) {
    try {
      if (!entry.wc.isDestroyed() && entry.wc.debugger.isAttached()) entry.wc.debugger.detach()
    } catch {
      // Already gone, or the drive got there first.
    }
    entry.weAttached = false
  }
}

/* --------------------------------------------------------------- the camera -- */

/**
 * The block camera, attached once per tab and switched by the live settings.
 *
 * `attachBlockWatch` has no detach, so the listeners stay for the life of the
 * view — but `enabled` is read on every settled navigation, so flipping the
 * panel's switch takes effect on the next page, and "off" costs nothing at
 * all. While the drive holds the page this stands down too: the drive's own
 * watcher covers a driven page, and two watchers would photograph one refusal
 * twice.
 *
 * `state` answers `'agent'` unconditionally, and that is not a claim that an
 * agent is here — on this path there is no baton. The check that dep exists
 * for — never photograph a page while the *person* holds it away from an agent
 * mid-handover — has no analogue on a page no agent touches, and the person's
 * own stored switch is the permission. The screenshot is masked exactly as the
 * drive's is, secret fields painted over before the PNG exists.
 */
function attachCamera(entry: Entry): void {
  if (entry.cameraAttached || entry.gone || entry.wc.isDestroyed()) return
  entry.cameraAttached = true
  const wc = entry.wc
  attachBlockWatch(wc, {
    state: () => 'agent',
    enabled: () => {
      if (entry.held || entry.gone) return false
      const arming = personArming(depsNow().settings(entry.profileId))
      return arming?.camera === true
    },
    dir: () => blockShotDirFor(depsNow().userData(), entry.profileId),
    text: async () => {
      try {
        const read = (await wc.executeJavaScriptInIsolatedWorld(PERSON_WORLD, [
          { code: withArgs(TEXT_SCRIPT, { limit: 2_000 }) },
        ])) as { text?: unknown } | null
        return read !== null && typeof read.text === 'string' ? read.text : null
      } catch {
        return null
      }
    },
    shot: async () => {
      /*
       * Masked or not at all, the same rule as `browser-driver.ts:maskedPng`:
       * a picture that cannot be redacted is not taken. One attempt — a block
       * page is on screen right now or it is not worth photographing.
       */
      try {
        const secrets = (await wc.executeJavaScriptInIsolatedWorld(PERSON_WORLD, [
          { code: withArgs(SECRET_RECTS_SCRIPT, {}) },
        ])) as {
          rects?: { x: number; y: number; width: number; height: number }[]
          viewport?: { width: number; height: number }
        } | null
        if (secrets === null || typeof secrets !== 'object') return null
        const image = await wc.capturePage()
        const size = image.getSize()
        if (size.width <= 0 || size.height <= 0) return null
        return maskRects(image, secrets.rects ?? [], secrets.viewport ?? { width: 0, height: 0 })
          .png
      } catch {
        return null
      }
    },
    now: () => depsNow().now(),
  })
}

/* ------------------------------------------------------------- the coverage -- */

/**
 * The stored coverage pattern, run against the page the person is looking at.
 *
 * On every settled navigation of a page whose run is capturing and whose
 * profile has the check switched on with a pattern: the page's own text is
 * read (bounded), the stated total is pulled out with the stored pattern, and
 * the comparison is recorded into the run's coverage log — where the panel's
 * Checks section and `assets.coverage op summary` both already read.
 *
 * What `captured` counts here is stated on the row itself: **background
 * responses recorded from this page**, because that is the one number a browse
 * run actually has. It is not "items", and the row's `what` says so in words —
 * a check that quietly compared unlike units would be the 7% failure with
 * better paperwork. A page where the pattern matches nothing records nothing:
 * most pages state no total, and a log of ten thousand `unknown` rows would
 * bury the one that matters.
 */
async function coverageCheck(entry: Entry): Promise<void> {
  if (entry.gone || entry.held || entry.network === null || entry.runId === '') return
  const deps = depsNow()
  const arming = personArming(deps.settings(entry.profileId))
  const pattern = arming?.coveragePattern ?? ''
  if (pattern === '' || entry.coverageBusy) return
  entry.coverageBusy = true
  try {
    const read = (await entry.wc.executeJavaScriptInIsolatedWorld(PERSON_WORLD, [
      { code: withArgs(TEXT_SCRIPT, { limit: 4_000 }) },
    ])) as { text?: unknown } | null
    const text = read !== null && typeof read.text === 'string' ? read.text : ''
    if (text === '') return
    const reading = statedTotal(text, { pattern })
    if (reading.total === null) return
    const network = entry.network
    if (network === null) return
    const entries = network.status().captured?.entries ?? 0
    const check = compareCoverage({
      stated: reading.total,
      captured: Math.max(0, entries - entry.entriesAtPage),
      what: 'background responses recorded from this page (not items)',
      url: entry.pageUrl !== '' ? entry.pageUrl : safeUrl(entry.wc),
      now: deps.now(),
    })
    recordCoverage(coveragePath(deps.userData(), entry.runId), check)
  } catch {
    // A page that cannot be read states no total. Nothing to record.
  } finally {
    entry.coverageBusy = false
  }
}
