import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join, posix } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import {
  DEFAULT_MAX_BODY_BYTES,
  DEFAULT_MAX_ENTRIES,
  MAX_MAX_TOTAL_BYTES,
  captureRoot,
  safeSegment,
  type CaptureBounds,
} from './browser-capture-store'
import { readFetchRules, RESOURCE_KINDS, type FetchRules } from './browser-fetch-rules'
import type { LedgerMode } from './browser-asset-ledger'
import type { RenditionRule } from './browser-asset-rendition'

/**
 * What one profile has been told to do when it scrapes, kept on disk.
 *
 * ## Why this file exists
 *
 * Four engines were finished before it — `browser-fetch-rules.ts`,
 * `browser-capture-store.ts`, the three `browser-asset-*` modules and
 * `browser-asset-coverage.ts` — and every one of them takes its configuration
 * **as an argument on the call**. That is the right shape for an engine and it
 * left the four capabilities unreachable by a person: there was nowhere for an
 * answer to the question *"always fulfil this profile's images"* to live, so the
 * Scraping panel drew all four sections as named-and-unavailable.
 *
 * So: one small store, keyed by profile, holding the answers a person gives on
 * that screen. Nothing here runs anything. `browser-scraping-ipc.ts` is what a
 * window talks to, and the three `…Of()` readers at the bottom are what the
 * engines' callers use to fall back to it when a tool call names nothing.
 *
 * ## `null` means nobody said, and it is not a default
 *
 * Every switch is `boolean | null` and every number is `number | null`, matching
 * `renderer/browser/scraping-bridge.ts` field for field. `null` is *not set*,
 * the panel draws it as such and offers the control, and the engine's own
 * default is what runs. A store that wrote `false` the first time it was read
 * would be this app inventing a decision and then showing it back to him as
 * his — and on the capture switch that is the difference between a run that
 * records the JSON the data is actually in and one that does not.
 *
 * ## What is *not* stored, deliberately
 *
 * The capture directory. It is derived — {@link captureFolderFor} — because
 * `captureDir()` already decides where a run writes, and a second copy of that
 * path in a settings file is a copy that can disagree with the folder the bytes
 * are in. The panel shows the derived one and Reveal opens the same one.
 */

/* ------------------------------------------------------------------ shape -- */

export interface CaptureSettings {
  /** Whether background XHR/fetch responses are recorded at all. `null`: unset. */
  on: boolean | null
  /** The run's total byte budget, in megabytes. `null`: the engine's own. */
  keepMB: number | null
}

export interface AssetSettings {
  /**
   * The rendition upgrade, as **one from→to pair** rather than a rule list.
   *
   * `RenditionRule` is a list of regular expressions and this is one literal
   * substitution, and the gap is closed on this side on purpose. What he asked
   * for is *"a configurable rewrite rule"*; a screen that made him write
   * `([?&]w=)\d+` → `$11920` to raise an image's size is a screen he would not
   * use, and one that accepted a regular expression from a text field would be
   * this process compiling something a stray `(` turns into a refusal in the
   * middle of a run of sixty thousand. {@link renditionRulesOf} escapes the pair
   * into exactly one rule, so the engine keeps its full vocabulary for callers
   * that have one and the panel keeps a control anybody can use.
   */
  upgrade: { on: boolean | null; from: string; to: string }
  ledger: { on: boolean | null; refetch: boolean | null }
}

export interface CheckSettings {
  coverage: { on: boolean | null; pattern: string }
  screenshotOnBlock: boolean | null
}

export interface ScrapeSettings {
  /** Only the kinds somebody actually set. An absent kind is unset, not `allow`. */
  requests: FetchRules
  capture: CaptureSettings
  assets: AssetSettings
  checks: CheckSettings
}

/** Nothing set. Not "the defaults" — see the header. */
export function emptyScrapeSettings(): ScrapeSettings {
  return {
    requests: {},
    capture: { on: null, keepMB: null },
    assets: {
      upgrade: { on: null, from: '', to: '' },
      ledger: { on: null, refetch: null },
    },
    checks: { coverage: { on: null, pattern: '' }, screenshotOnBlock: null },
  }
}

/* ---------------------------------------------------------------- reading -- */

/** Megabytes, held inside what the capture store will actually accept. */
export const MAX_KEEP_MB = Math.floor(MAX_MAX_TOTAL_BYTES / (1024 * 1024))

/**
 * How long a typed pattern or a rewrite half may be.
 *
 * Short because both are escaped or compiled downstream: a rewrite is escaped
 * into a regular expression, which can double its length against
 * `readRenditionRules`' own 400-character cap, and a coverage pattern is
 * compiled and run against page text. Neither is a place for a payload.
 */
const MAX_TEXT_CHARS = 180

function flag(raw: unknown): boolean | null {
  return typeof raw === 'boolean' ? raw : null
}

function text(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  const trimmed = raw.trim()
  return trimmed.length > MAX_TEXT_CHARS ? trimmed.slice(0, MAX_TEXT_CHARS) : trimmed
}

function whole(raw: unknown, min: number, max: number): number | null {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return null
  return Math.min(max, Math.max(min, Math.trunc(raw)))
}

/**
 * One profile's settings, read off whatever was in the file.
 *
 * The same discipline `readWorkerStore` applies: a stray comma, an older shape
 * or a hand-edited file must not be able to stop the panel opening. Anything
 * unreadable becomes `null`, which is *unset* — never a value this process made
 * up and then showed him as his own.
 */
export function readScrapeSettings(raw: unknown): ScrapeSettings {
  const value = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  const out = emptyScrapeSettings()

  // `readFetchRules` is the engine's own reader, aliases and all, so a file
  // written before `cheap` was renamed reads back as `fulfill`.
  out.requests = readFetchRules(value.requests).rules

  const capture = group(value.capture)
  out.capture = { on: flag(capture.on), keepMB: whole(capture.keepMB, 1, MAX_KEEP_MB) }

  const assets = group(value.assets)
  const upgrade = group(assets.upgrade)
  const ledger = group(assets.ledger)
  out.assets = {
    upgrade: { on: flag(upgrade.on), from: text(upgrade.from), to: text(upgrade.to) },
    ledger: { on: flag(ledger.on), refetch: flag(ledger.refetch) },
  }

  const checks = group(value.checks)
  const coverage = group(checks.coverage)
  out.checks = {
    coverage: { on: flag(coverage.on), pattern: safePattern(coverage.pattern) },
    screenshotOnBlock: flag(checks.screenshotOnBlock),
  }
  return out
}

function group(raw: unknown): Record<string, unknown> {
  return typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
}

/**
 * A coverage pattern that will compile, or `''`.
 *
 * Checked here rather than where it is used, because the place it is used is
 * inside a run: `statedTotal` takes it, builds a `RegExp` and reads a page with
 * it, and an expression that throws there is a coverage check that never
 * happens on a run that believes it is checking itself. Refused at the door
 * means the field comes back empty and the panel shows it empty, which is a
 * person seeing their typo rather than a run quietly not checking.
 */
export function safePattern(raw: unknown): string {
  const pattern = text(raw)
  if (pattern === '') return ''
  try {
    void new RegExp(pattern)
    return pattern
  } catch {
    return ''
  }
}

/* ---------------------------------------------------------------- merging -- */

/**
 * A patch from the panel, merged group by group into what is stored.
 *
 * Merged rather than replaced, and the reason is on `ScrapingConfigPatch`: more
 * than one screen writes this object, and a panel that posted the whole
 * configuration back would silently undo whatever it had not reloaded since. One
 * control changes one field.
 */
export function mergeScrapeSettings(current: ScrapeSettings, patch: unknown): ScrapeSettings {
  const value = group(patch)
  const next: ScrapeSettings = {
    requests: { ...current.requests },
    capture: { ...current.capture },
    assets: {
      upgrade: { ...current.assets.upgrade },
      ledger: { ...current.assets.ledger },
    },
    checks: {
      coverage: { ...current.checks.coverage },
      screenshotOnBlock: current.checks.screenshotOnBlock,
    },
  }

  if (value.requests !== undefined) {
    const read = readFetchRules(value.requests)
    for (const kind of RESOURCE_KINDS) {
      const rule = read.rules[kind]
      if (rule !== undefined) next.requests[kind] = rule
    }
  }

  if (value.capture !== undefined) {
    const capture = group(value.capture)
    if (capture.on !== undefined) next.capture.on = flag(capture.on)
    if (capture.keepMB !== undefined) next.capture.keepMB = whole(capture.keepMB, 1, MAX_KEEP_MB)
    // `directory` is deliberately not taken: it is derived, and a stored one
    // could disagree with the folder the bytes are actually in.
  }

  if (value.assets !== undefined) {
    const assets = group(value.assets)
    if (assets.upgrade !== undefined) {
      const upgrade = group(assets.upgrade)
      if (upgrade.on !== undefined) next.assets.upgrade.on = flag(upgrade.on)
      if (upgrade.from !== undefined) next.assets.upgrade.from = text(upgrade.from)
      if (upgrade.to !== undefined) next.assets.upgrade.to = text(upgrade.to)
    }
    if (assets.ledger !== undefined) {
      const ledger = group(assets.ledger)
      if (ledger.on !== undefined) next.assets.ledger.on = flag(ledger.on)
      if (ledger.refetch !== undefined) next.assets.ledger.refetch = flag(ledger.refetch)
    }
  }

  if (value.checks !== undefined) {
    const checks = group(value.checks)
    if (checks.coverage !== undefined) {
      const coverage = group(checks.coverage)
      if (coverage.on !== undefined) next.checks.coverage.on = flag(coverage.on)
      if (coverage.pattern !== undefined) next.checks.coverage.pattern = safePattern(coverage.pattern)
    }
    if (checks.screenshotOnBlock !== undefined) {
      next.checks.screenshotOnBlock = flag(checks.screenshotOnBlock)
    }
  }

  return next
}

/* ------------------------------------------------------- what engines read -- */

/** This profile's capture folder: the parent of every run `captureDir` makes. */
export function captureFolderFor(userData: string, profileId: string): string {
  // A server capture folder, keyed the same way `captureDir` keys it: `/` on
  // every host, so a run filed on a Linux box is named the same from Windows.
  return posix.join(captureRoot(userData), safeSegment(profileId === '' ? 'isolated' : profileId))
}

/** The stored rules, or `null` when this profile has set none. */
export function fetchRulesOf(settings: ScrapeSettings): FetchRules | null {
  return Object.keys(settings.requests).length === 0 ? null : { ...settings.requests }
}

/** The stored byte budget, or `null`. The other two bounds are the engine's. */
export function captureBoundsOf(settings: ScrapeSettings): CaptureBounds | null {
  if (settings.capture.keepMB === null) return null
  return {
    maxBodyBytes: DEFAULT_MAX_BODY_BYTES,
    maxTotalBytes: settings.capture.keepMB * 1024 * 1024,
    maxEntries: DEFAULT_MAX_ENTRIES,
  }
}

/** Everything a `RegExp` treats as syntax, made literal. */
function escapeRegExp(raw: string): string {
  return raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * The from→to pair as the one rule the rendition engine runs, or `[]`.
 *
 * Both halves are escaped: the match so a `?` in a query string is a question
 * mark rather than a quantifier, and the replacement's `$` so a URL containing
 * `$1` is not read as a back-reference. `g` because the size a page hides
 * usually appears twice in one URL — once in the path and once in the query.
 */
export function renditionRulesOf(settings: ScrapeSettings): RenditionRule[] {
  const upgrade = settings.assets.upgrade
  if (upgrade.on !== true || upgrade.from === '') return []
  return [
    {
      id: 'upgrade',
      match: escapeRegExp(upgrade.from),
      replace: upgrade.to.replace(/\$/g, '$$$$'),
      flags: 'g',
    },
  ]
}

/**
 * `resume`, `refetch`, or `null` when this profile has not said.
 *
 * The switch and the mode are not the same question and both are stored: the
 * ledger being *off* means nothing consults it, and `refetch` means it is still
 * written and no longer skips. `off` reads as `refetch` here, because a run that
 * must not skip is what "no ledger" means to an engine that always writes one —
 * and a ledger that is written anyway is a run that can be resumed after
 * somebody changes their mind, which deleting the file would have cost them.
 */
export function ledgerModeOf(settings: ScrapeSettings): LedgerMode | null {
  const ledger = settings.assets.ledger
  if (ledger.on === false) return 'refetch'
  if (ledger.refetch === true) return 'refetch'
  if (ledger.on === true || ledger.refetch === false) return 'resume'
  return null
}

/** The stored coverage pattern, or `''` when it is unset or switched off. */
export function coveragePatternOf(settings: ScrapeSettings): string {
  return settings.checks.coverage.on === true ? settings.checks.coverage.pattern : ''
}

/* ------------------------------------------------------------ the arming -- */

/** What a page's profile has to say, as `browser-drive-ipc.ts` answers it. */
export interface ArmingDefaults {
  rules: FetchRules | null
  capture: boolean | null
  bounds: CaptureBounds | null
  blockShots: boolean | null
}

/** What a `browser.network` call asked for, and which parts it actually named. */
export interface ArmingAsk {
  rules: FetchRules
  capture: boolean
  bounds: CaptureBounds
  named?: { rules?: boolean; capture?: boolean; bounds?: boolean }
}

/**
 * What will actually be armed: the call, with the profile filling its silences.
 *
 * Pure, and separate from the driver, because the whole rule lives in it and the
 * rule is easy to get subtly backwards: **a stored setting never overrules an
 * argument, it only fills a silence.** Both halves matter. A stored rule that
 * beat an explicit `rules: {}` would be a caller unable to ask for a page that
 * behaves normally; a stored rule that lost to a call that named nothing would
 * make the Scraping panel a screen full of controls that store a preference
 * nothing reads.
 *
 * `named` is what tells the two apart. `capture` defaults to true and `bounds`
 * is filled with the engine's own numbers long before this is reached, so
 * *"said nothing"* and *"said exactly the default"* arrive identical without it.
 */
export function resolveArming(
  ask: ArmingAsk,
  stored: ArmingDefaults | null,
): { rules: FetchRules; capture: boolean; bounds: CaptureBounds } {
  const named = ask.named ?? {}
  return {
    rules: named.rules === true || !stored?.rules ? ask.rules : stored.rules,
    capture:
      named.capture === true || stored === null || stored.capture === null
        ? ask.capture
        : stored.capture,
    bounds: named.bounds === true || !stored?.bounds ? ask.bounds : stored.bounds,
  }
}

/* -------------------------------------------------------------- the store -- */

export function scrapeSettingsPath(userData: string): string {
  return join(userData, 'browser-scraping.json')
}

type Stored = Record<string, ScrapeSettings>

let store: Stored | null = null
let storeDir: string | null = null

function load(userData: string): Stored {
  const path = scrapeSettingsPath(userData)
  if (!existsSync(path)) return {}
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as unknown
    const profiles = group(group(parsed).profiles)
    const out: Stored = {}
    for (const [profileId, raw] of Object.entries(profiles)) {
      if (profileId === '') continue
      out[profileId] = readScrapeSettings(raw)
    }
    return out
  } catch {
    // A file that will not parse is an empty store, which costs a person the
    // settings they typed and never costs them a browser that will not open.
    return {}
  }
}

function ensure(userData: string): Stored {
  if (store === null || storeDir !== userData) {
    storeDir = userData
    store = load(userData)
  }
  return store
}

function save(userData: string, next: Stored): void {
  const path = scrapeSettingsPath(userData)
  mkdirSync(dirname(path), { recursive: true })
  writeFileAtomic(path, `${JSON.stringify({ version: 1, profiles: next }, null, 2)}\n`)
}

/** What this profile has been told to do. Unset everywhere until somebody says. */
export function scrapeSettingsFor(userData: string, profileId: unknown): ScrapeSettings {
  const id = typeof profileId === 'string' ? profileId : ''
  if (id === '') return emptyScrapeSettings()
  return ensure(userData)[id] ?? emptyScrapeSettings()
}

/**
 * Told once per stored write, with the profile and what now stands.
 *
 * The hook that makes a toggle a live control rather than a stored note:
 * `browser-profile-arm.ts` listens here and re-arms (or disarms) every open
 * page of that profile the moment the panel writes — events, not polling.
 * One listener, replaced on registration; nothing else has asked to hear.
 */
type ScrapeSettingsListener = (profileId: string, settings: ScrapeSettings) => void

let announce: ScrapeSettingsListener | null = null

export function onScrapeSettingsChanged(listener: ScrapeSettingsListener | null): void {
  announce = listener
}

/**
 * Store one patch and answer with the whole of what is now stored.
 *
 * The whole of it, never a boolean: the panel takes this reply as the truth and
 * redraws from it, which is what makes a number this store clamped appear
 * clamped on screen instead of sitting in the field as it was typed.
 */
export function setScrapeSettings(
  userData: string,
  profileId: unknown,
  patch: unknown,
): ScrapeSettings {
  const id = typeof profileId === 'string' ? profileId : ''
  if (id === '') return emptyScrapeSettings()
  const current = ensure(userData)
  const next = mergeScrapeSettings(current[id] ?? emptyScrapeSettings(), patch)
  current[id] = next
  try {
    save(userData, current)
  } catch {
    // Kept in memory either way. The reply says what is in force, and a disk
    // that refused the file has not made the panel lie about this session.
  }
  try {
    announce?.(id, next)
  } catch {
    // A listener that throws must not take the panel's reply down with it.
  }
  return next
}

/** For tests, which must not inherit each other's file. */
export function resetScrapeSettingsForTests(): void {
  store = null
  storeDir = null
  announce = null
}
