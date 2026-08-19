/**
 * What the usage bar is allowed to say, decided away from React.
 *
 * The bar is the thing Asad asked for twice:
 *
 *   > *"Where we show the account, next to it we show a bar of the five-hour
 *   > limit — how much limit is completed, how much is left, with the time of
 *   > renewal."*
 *
 * The numbers behind it already existed and already worked — `plan-limit.ts`
 * reads Claude Code's own screen, `codex-usage.ts` reads the struct Codex writes
 * into its rollout, and `usage-ipc.ts` folds the two into one report per session
 * with the account attached. What was missing was the placement, and this module
 * is the half of that placement with no DOM in it: given a report and a clock,
 * what may be drawn, what may only be written in words, and what must be
 * refused.
 *
 * ## The three refusals, and why each of them exists
 *
 * This feature was nearly cancelled twice for being unreliable, so the rules are
 * stated as code rather than left to whoever writes the next surface.
 *
 * **A bar needs both halves.** A bar is a claim that something was measured
 * against a known limit over a known period. So one is drawn only when the
 * source reported a fraction *and* said when the window rolls over. A fraction
 * with no reset is printed as a number with the missing half admitted; neither
 * half is ever supplied by this app.
 *
 * **Unknown is not zero.** `not-reported` and `0%` are opposite facts and are
 * spelled differently everywhere here — see {@link UsageAmount}, which is a
 * union precisely so that no caller can `?? 0` its way past the distinction.
 * `~/.claude.json` carries a `cachedUsageUtilization` block with exactly the
 * fields a bar wants, and on this machine it was 21.3 hours stale and described
 * a window that had ended 17 hours earlier. Nothing here reads it.
 *
 * **A window that has rolled over is not a reading.** The same failure again,
 * one level down: a real measurement, of a period that no longer exists.
 * Codex's newest rollout on this machine reports 5% of a 30-day window that
 * reset on 4 July — exact, and about nothing that is true now. So an expired
 * reading loses its bar and its number, and keeps only the sentence saying what
 * was last seen and when.
 *
 * ## Why the freshness rule is spelled twice
 *
 * `src/main/usage-window.ts` states it first and is the authority. The renderer
 * cannot import it — `tsconfig.web.json` does not include `src/main`, which is
 * the same wall `chat/usage/types.ts` mirrors its shapes across — so the
 * fraction is restated below and `usage-bar-model.test.ts` reads the main-process
 * file as text and fails if the two ever differ. A second copy that can drift is
 * a bug; a second copy pinned to the first is a boundary.
 */

import type { ProviderId } from '@shared/types'
import { isProviderId } from '../preferences'
import type { ContextLevel } from '../chat/usage/types'
import { describeAge, formatPercent, levelOfPercent } from '../chat/usage/usage-model'

/* -------------------------------------------------------------------------- */
/* The shapes that cross the bridge                                            */
/* -------------------------------------------------------------------------- */

/** Mirrors `UsageWindowKind` in `src/main/usage-window.ts`. */
export type UsageWindowKind = 'five-hour' | 'weekly' | 'monthly' | 'other'

/** Mirrors `UsageSourceId`. Named per source, not per provider. */
export type UsageSourceId =
  | 'claude-usage-panel'
  | 'claude-warning'
  | 'claude-usage-api'
  | 'codex-rollout'

/** Mirrors `UsageAmount`: a union so "0%" and "nothing said" cannot be confused. */
export type UsageAmount = { state: 'reported'; fraction: number } | { state: 'not-reported' }

/** Mirrors `UsageReset`: an instant, words, or nothing. */
export type UsageReset =
  | { state: 'at'; at: number }
  | { state: 'described'; text: string }
  | { state: 'not-reported' }

export interface UsageAccountRef {
  /**
   * The agent whose subscription this is.
   *
   * Null where the main process named one this build does not know — a
   * possibility because the agent catalogue is a growing list and a renderer
   * can be older than the process it talks to. Null rather than a stand-in:
   * mis-naming which agent a reading belongs to is the same class of mistake as
   * mis-naming which account it belongs to, and one bar shared between two
   * subscriptions is what this whole module is arranged to prevent.
   */
  provider: ProviderId | null
  id: string | null
  name: string | null
  configDir: string | null
}

export interface UsageWindowReading {
  id: string
  account: UsageAccountRef
  window: UsageWindowKind
  windowMinutes: number | null
  /** The source's own words for this window. Never re-worded here. */
  label: string
  used: UsageAmount
  resets: UsageReset
  /** When this app looked. */
  observedAt: number
  /** When the source produced the number — for Codex, often much earlier. */
  reportedAt: number
  source: UsageSourceId
}

export interface UsageReport {
  sessionId: string | null
  readings: UsageWindowReading[]
  /** One sentence, present exactly when `readings` is empty. */
  reason: string | null
  /**
   * Whose subscription the report is about, whether or not it has readings.
   *
   * The empty report is the ordinary one — Claude Code says nothing about its
   * limits until it is near one or is asked — so without this the bar would
   * spend most of its life saying "not reported" and unable to say by whom,
   * which is not something the account chip beside it could then be checked
   * against.
   */
  account: UsageAccountRef | null
  assembledAt: number
}

/* ------------------------------------------------------------ reading it -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function nullableStr(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null
}

const WINDOWS: UsageWindowKind[] = ['five-hour', 'weekly', 'monthly', 'other']
const SOURCES: UsageSourceId[] = [
  'claude-usage-panel',
  'claude-warning',
  'claude-usage-api',
  'codex-rollout',
]

/**
 * The amount, read without ever inventing one.
 *
 * Anything that is not an explicit `{ state: 'reported', fraction: <finite> }`
 * comes back as `not-reported`. That includes a payload from an older build
 * that sent a bare number: a shape this side does not recognise is not a
 * measurement, and guessing what it meant is how the zero gets in.
 */
function readAmount(raw: unknown): UsageAmount {
  if (!isRecord(raw) || raw.state !== 'reported') return { state: 'not-reported' }
  const fraction = raw.fraction
  if (typeof fraction !== 'number' || !Number.isFinite(fraction) || fraction < 0) {
    return { state: 'not-reported' }
  }
  return { state: 'reported', fraction }
}

function readReset(raw: unknown): UsageReset {
  if (!isRecord(raw)) return { state: 'not-reported' }
  if (raw.state === 'at' && typeof raw.at === 'number' && Number.isFinite(raw.at) && raw.at > 0) {
    return { state: 'at', at: raw.at }
  }
  if (raw.state === 'described') {
    const text = str(raw.text).trim()
    if (text !== '') return { state: 'described', text }
  }
  return { state: 'not-reported' }
}

function readAccount(raw: unknown): UsageAccountRef {
  const source = isRecord(raw) ? raw : {}
  return {
    provider: isProviderId(source.provider) ? source.provider : null,
    id: nullableStr(source.id),
    name: nullableStr(source.name),
    configDir: nullableStr(source.configDir),
  }
}

function readReading(raw: unknown): UsageWindowReading | null {
  if (!isRecord(raw)) return null
  const id = str(raw.id)
  if (id === '') return null
  const window = WINDOWS.find((kind) => kind === raw.window) ?? 'other'
  const source = SOURCES.find((known) => known === raw.source)
  if (source === undefined) return null
  const observedAt = num(raw.observedAt)
  return {
    id,
    account: readAccount(raw.account),
    window,
    windowMinutes:
      typeof raw.windowMinutes === 'number' && Number.isFinite(raw.windowMinutes)
        ? raw.windowMinutes
        : null,
    label: str(raw.label),
    used: readAmount(raw.used),
    resets: readReset(raw.resets),
    observedAt,
    // A reading with no `reportedAt` is as old as the look that found it, which
    // is the conservative reading of an absence rather than "just now".
    reportedAt: num(raw.reportedAt) || observedAt,
    source,
  }
}

/** A `UsageReport` off the bridge, or null when the payload is not one. */
export function readUsageReport(raw: unknown): UsageReport | null {
  if (!isRecord(raw) || !Array.isArray(raw.readings)) return null
  const readings = raw.readings
    .map(readReading)
    .filter((reading): reading is UsageWindowReading => reading !== null)
  return {
    sessionId: nullableStr(raw.sessionId),
    readings,
    reason: nullableStr(raw.reason),
    // Absent from a build whose main process predates the field, in which case
    // the bar names the agent and leaves the login to the chip beside it.
    account: isRecord(raw.account) ? readAccount(raw.account) : null,
    assembledAt: num(raw.assembledAt),
  }
}

/* --------------------------------------------------------------- freshness */

/**
 * How much of a window may pass before its reading stops being current.
 *
 * A twelfth — twenty-five minutes of a five-hour window, fourteen hours of a
 * week. Copied from `STALE_WINDOW_FRACTION` in `src/main/usage-window.ts`, where
 * the judgement is argued, and pinned to it by this module's test.
 */
export const STALE_WINDOW_FRACTION = 1 / 12

/** Nominal lengths, for the staleness threshold only. Never shown. */
function nominalWindowMinutes(window: UsageWindowKind): number | null {
  if (window === 'five-hour') return 300
  if (window === 'weekly') return 10080
  if (window === 'monthly') return 43200
  return null
}

/* ----------------------------------------------------------------- naming */

/**
 * The window in as few characters as a bar can spare.
 *
 * Named after the period, not after either vendor's word for it: Claude Code
 * calls the five hours "Current session" and Codex calls it "primary", and a
 * reader should not have to learn both to know that one bar is the other bar.
 * The source's own label survives untouched in `reading.label` and is what the
 * panel prints, so nothing is lost by being short here.
 */
export function shortWindowName(reading: UsageWindowReading): string {
  if (reading.window === 'five-hour') return '5h'
  if (reading.window === 'weekly') return 'Week'
  if (reading.window === 'monthly') return '30d'
  // An unrecognised period still has a length whenever the source stated one,
  // and a length is a fact. Falling back to the vendor's label is the last
  // resort, because it is the one thing that is certainly true.
  const minutes = reading.windowMinutes
  if (minutes !== null && minutes > 0) {
    if (minutes % 1440 === 0) return `${minutes / 1440}d`
    if (minutes % 60 === 0) return `${minutes / 60}h`
    return `${minutes}m`
  }
  return reading.label || 'Limit'
}

/** The window in a sentence: "the five-hour window", "the weekly window". */
export function windowNoun(reading: UsageWindowReading): string {
  if (reading.window === 'five-hour') return 'the five-hour window'
  if (reading.window === 'weekly') return 'the weekly window'
  if (reading.window === 'monthly') return 'the 30-day window'
  return reading.label === '' ? 'this window' : `“${reading.label}”`
}

/** Where a reading came from, in words, for the sentence under the bars. */
export function sourceSentence(source: UsageSourceId): string {
  /*
   * The one that answers the question a reader of this bar actually has.
   *
   * "Where did this number come from" used to have an uncomfortable answer —
   * this app typed `/usage` into your session and read the panel — and the
   * sentence had to say so because it was true. It is no longer true, and this
   * says what happens instead in the same breath, because the change is the
   * point: the figure is fetched by a Claude Code of this app's own, and no
   * session is touched to get it.
   */
  if (source === 'claude-usage-api') {
    return 'Fetched by Claude Code itself, in this app’s own process — no session is typed into.'
  }
  if (source === 'claude-usage-panel') return 'Read from Claude Code’s own /usage panel.'
  if (source === 'claude-warning') return 'Read from a limit warning Claude Code printed in this session.'
  return 'Read from the rollout Codex writes as it works — no need to ask it.'
}

/* --------------------------------------------------------------- the clock */

const HOUR = 3_600_000

/**
 * A reset instant, written the way a person would say it.
 *
 * The time alone while it is inside a day either way, because "resets 9:04 pm"
 * is the whole answer then and the date would be noise; the date as well once
 * it is further off, because "resets 9:04 pm" on the fourth of next month is a
 * sentence that reads as tonight. The locale is the machine's own — this is the
 * one place in the feature where a number becomes words, and the words should
 * be the reader's.
 */
export function formatResetInstant(at: number, now: number): string {
  const time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(at)
  const near = Math.abs(at - now) < 18 * HOUR
  if (near) return time
  const date = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' }).format(at)
  return `${date}, ${time}`
}

/** How a reset is written, whichever way the source gave it. */
export function resetText(reading: UsageWindowReading, now: number): string | null {
  if (reading.resets.state === 'at') return formatResetInstant(reading.resets.at, now)
  if (reading.resets.state === 'described') return reading.resets.text
  return null
}

/**
 * The same reset, with a trailing parenthetical dropped, for a one-line bar.
 *
 * Claude Code prints `4am (Asia/Dubai)` and `Aug 14 at 2pm (Asia/Dubai)`. On the
 * bar that timezone is both the longest part of the phrase and the least
 * informative one — it is the machine's own zone, which is the zone every other
 * clock the reader can see is already in. Left in and capped, it drew as
 * `resets 8:50am (…`, which is an ellipsis where a fact should be; taken out,
 * the whole answer fits.
 *
 * This is the only place in the feature where a source's words are shortened,
 * and it shortens rather than rewrites: the verbatim string is what the panel
 * prints under `Renews`, and what the hover label carries. The model chip beside
 * this one makes the same trade with `Opus 5 (1M context) (default)`.
 */
export function chipReset(text: string): string {
  return text.replace(/\s*\([^)]*\)\s*$/, '').trim() || text
}

/* -------------------------------------------------------------- the readout */

/**
 * What one reading is allowed to look like right now.
 *
 * - `live` — measured, reset known, window still running and the number recent.
 *   The only state that gets a bar at full strength.
 * - `aged` — the same, but enough of the window has gone by unmeasured that the
 *   number has drifted. The bar is drawn back and the age is printed beside it,
 *   because the alternative — dropping the bar twenty-five minutes after a
 *   `/usage` run — teaches people the feature is broken.
 * - `expired` — the window it describes has rolled over. No bar and no
 *   percentage: what is true now is that nothing has been reported since.
 * - `no-reset` — a fraction with no renewal time. The number is printed, the
 *   bar is not, and the missing half is named.
 * - `unmeasured` — the source named a limit without a number, which Claude Code
 *   does whenever it warns before it counts.
 */
export type UsageReadoutState = 'live' | 'aged' | 'expired' | 'no-reset' | 'unmeasured'

export interface UsageReadout {
  reading: UsageWindowReading
  state: UsageReadoutState
  /** `5h`, `Week`, `30d` — what the chip calls this window. */
  short: string
  /** True only where a bar is honest. Everything else is words. */
  bar: boolean
  /** 0..100+, or null when nothing was reported. Never defaulted to zero. */
  percent: number | null
  level: ContextLevel
  /** The value on the chip: `39%`, or `Not reported`. */
  value: string
  /** One clause after the value, or `''` when the state has nothing to add. */
  caveat: string
  /**
   * When the window renews, written out in full — the source's own words, with
   * nothing trimmed. Null when the source did not say.
   *
   * Carried beside {@link UsageReadout.detail} rather than only inside it so a
   * surface with room can print the fact on its own line instead of quoting a
   * sentence that also contains it. The panel does exactly that; printing both
   * gave every row the same reset time twice, three lines apart.
   */
  reset: string | null
  /** How old the reading is, in words, or `''` when it was just taken. */
  age: string
  /** Where the reading came from, in a sentence. */
  source: string
  /** The whole account, for a tooltip and for the panel's absence states. */
  detail: string
}

/** How old the reading is, in words, or `''` when it was just taken. */
function ageText(reading: UsageWindowReading, now: number): string {
  return describeAge(reading.reportedAt, now)
}

export function usageReadout(reading: UsageWindowReading, now: number): UsageReadout {
  const short = shortWindowName(reading)
  const reset = resetText(reading, now)
  const age = ageText(reading, now)
  const source = sourceSentence(reading.source)
  const expired = reading.resets.state === 'at' && reading.resets.at <= now
  const minutes = reading.windowMinutes ?? nominalWindowMinutes(reading.window)
  const drifted =
    minutes !== null && now - reading.reportedAt > minutes * 60_000 * STALE_WINDOW_FRACTION

  if (expired) {
    /*
     * The exact failure this whole feature is written around, so it gets the
     * longest sentence: what was last measured, when it was measured, and the
     * fact that the period it measured has since ended. Codex on this machine
     * is permanently in this state until it takes another turn.
     */
    const last =
      reading.used.state === 'reported'
        ? `Last reported ${formatPercent(reading.used.fraction * 100)}${age ? ` ${age}` : ''}. `
        : ''
    return {
      reading,
      state: 'expired',
      short,
      bar: false,
      percent: null,
      level: 'ok',
      value: 'Not reported',
      caveat: 'window has reset',
      reset,
      age,
      source,
      detail: `${last}${capitalise(windowNoun(reading))} reset${
        reset ? ` at ${reset}` : ''
      }, and nothing has been reported since. ${source}`,
    }
  }

  if (reading.used.state !== 'reported') {
    return {
      reading,
      state: 'unmeasured',
      short,
      bar: false,
      percent: null,
      level: 'ok',
      value: 'Not reported',
      reset,
      age,
      source,
      // A limit named without a number often still comes with a reset time —
      // "Approaching weekly limit · resets Aug 14" — and that half is worth
      // keeping even though there is no bar to hang it on.
      caveat: reset ? `resets ${chipReset(reset)}` : '',
      detail: `${reading.label || capitalise(windowNoun(reading))} was named without a figure${
        reset ? `, resetting ${reset}` : ''
      }. ${source}`,
    }
  }

  const percent = reading.used.fraction * 100
  const level = levelOfPercent(percent)
  const shown = formatPercent(percent)

  if (reset === null) {
    return {
      reading,
      state: 'no-reset',
      short,
      bar: false,
      percent,
      level,
      value: shown,
      caveat: 'no reset time reported',
      reset,
      age,
      source,
      detail: `${shown} of ${windowNoun(reading)} used${
        age ? `, ${age}` : ''
      }. The source did not say when it renews, so there is no bar — only what it said. ${source}`,
    }
  }

  return {
    reading,
    state: drifted ? 'aged' : 'live',
    short,
    bar: true,
    percent,
    level,
    value: shown,
    reset,
    age,
    source,
    // Aged readings trade the renewal time for their own age, because the age
    // is the thing that changes what the number means. The panel prints both.
    caveat: drifted ? `read ${age || 'a while ago'}` : `resets ${chipReset(reset)}`,
    detail: `${shown} of ${windowNoun(reading)} used, resetting ${reset}${
      age ? `, read ${age}` : ''
    }. ${source}`,
  }
}

function capitalise(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1)
}

/* ------------------------------------------------------------ which one -- */

/**
 * The reading the bar itself shows.
 *
 * The shortest window, which is the one he asked for — *"for Claude we have a
 * five hour window"* — and the one that actually moves during an afternoon. The
 * main process already sorts shortest-first (`sortReadings`), so this is the
 * first of them; sorting again here would be a second opinion about an order
 * that is already decided.
 */
export function primaryReading(report: UsageReport | null): UsageWindowReading | null {
  return report?.readings[0] ?? null
}

/**
 * A second window worth putting on the bar beside the first.
 *
 * Only ever one, and only when it is in trouble. A weekly limit at 100% behind
 * a five-hour bar reading 5% is a screen that says "you are fine" to someone who
 * is not, and that is precisely the kind of confidently-wrong reading this
 * feature was nearly cancelled for. When every other window is quiet this
 * returns null and the bar stays as short as it looks in the mock-up.
 */
export function alertReading(
  report: UsageReport | null,
  primary: UsageWindowReading | null,
  now: number,
): UsageReadout | null {
  if (!report || !primary) return null
  const others = report.readings
    .filter((reading) => reading.id !== primary.id)
    .map((reading) => usageReadout(reading, now))
    .filter((readout) => readout.percent !== null && readout.level !== 'ok')
  if (others.length === 0) return null
  return others.reduce((worst, readout) =>
    (readout.percent ?? 0) > (worst.percent ?? 0) ? readout : worst,
  )
}
