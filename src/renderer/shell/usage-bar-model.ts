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
import { describeAge, formatPercent, formatTokens, levelOfPercent } from '../chat/usage/usage-model'

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

/*
 * `windowNoun` used to live here — "the five-hour window", "the weekly window"
 * — and it existed only to be dropped into the sentences under these rows. The
 * sentences are gone, so it is too, rather than left as a helper nobody calls
 * that the next person would feel invited to use.
 */

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
     * The exact failure this whole feature is written around, and it is now
     * stated in facts rather than in a paragraph about them: what was last
     * measured, and when the period it measured ended. Codex on this machine is
     * permanently in this state until it takes another turn.
     *
     * The sentence that used to be here — and the source clause after it — went
     * with every other explanatory line in this file. Asad: *"I don't want any
     * kind of long descriptions anywhere."* Where the reason for an absence is
     * genuinely needed it belongs behind an (i), the way Settings does it, not
     * printed under a row somebody is scanning.
     */
    const last =
      reading.used.state === 'reported'
        ? `Last ${formatPercent(reading.used.fraction * 100)}${age ? ` ${age}` : ''}`
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
      detail: [last, reset ? `reset ${reset}` : 'window reset'].filter((part) => part !== '').join(' · '),
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
      // Named, with no number behind the name. The row's own head already
      // prints the label and `Not reported`, so all this adds is the half that
      // did arrive.
      detail: reset === null ? '' : `Renews ${reset}`,
    }
  }

  const percent = reading.used.fraction * 100
  const level = levelOfPercent(percent)
  const shown = formatPercent(percent)

  if (reset === null) {
    /*
     * A figure with no renewal time, and it now draws a bar like any other.
     *
     * It used to be barred deliberately, on the argument that a window without
     * a reset time is only half a reading — and the missing half was then
     * printed as a sentence saying so. That sentence is what Asad was reading
     * off the copilot page: *"current session 0% of 5 hours. This long
     * description is not required."*
     *
     * Withholding the bar was the wrong half to cut. The percentage is the
     * proven part — the source stated it — and the bar draws exactly that and
     * claims nothing about renewal; it was the *prose* that was making the row
     * long. So the fraction is drawn, `Renews …` is simply absent from the
     * facts line under it, and nothing explains the absence.
     */
    return {
      reading,
      state: 'no-reset',
      short,
      bar: true,
      percent,
      level,
      value: shown,
      caveat: 'no reset time reported',
      reset,
      age,
      source,
      // Not printed under the row — it has a bar now, so the row prints its
      // facts line — which makes this the screen reader's copy, in the same
      // shape and order as every other window's, minus the clause the source
      // never gave.
      detail: [`${shown} used`, age ? `read ${age}` : ''].filter((part) => part !== '').join(' · '),
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
    /*
     * Not printed under the row — a row with a bar prints its facts line
     * instead — so this is what a screen reader gets for the window, and it is
     * the same facts in the same order rather than a paragraph about them.
     */
    detail: [`${shown} used`, `renews ${reset}`, age ? `read ${age}` : ''].filter((p) => p !== '').join(' · '),
  }
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

/* -------------------------------------------------------------------------- */
/* The context window                                                          */
/* -------------------------------------------------------------------------- */

/**
 * How full the model's context window is, as it crosses the bridge.
 *
 * Mirrors `ContextWindowReading` in `src/main/context-window.ts` for the reason
 * every other shape in this file is mirrored: `tsconfig.web.json` does not
 * include `src/main`, so the renderer cannot import the definition and has to
 * restate it. Only the fields a bar or a tooltip actually uses are restated —
 * the path of the file that was read stays in the main process, where it is
 * a debugging fact rather than something to draw.
 *
 * ## Why this reading is on the bar at all when the plan figures are not
 *
 * Asad settled it on 2026-08-19 — *"no lets keep it in the dropdown and keep
 * context outside"* — and the split is a cost, not a taste. Measured on this
 * machine today:
 *
 *  - This figure is a bounded tail read of a file Claude Code already wrote:
 *    2–17 ms across three real project folders, no process, no network, and
 *    current by construction because the agent writes it as it works.
 *  - A fresh plan figure boots the whole Claude Code binary to ask one
 *    question: **725 MB peak RSS, ~3 s**, measured with the exact `PROBE_ARGS`
 *    control request in `src/main/usage-probe.ts`.
 *
 * So one of them can be permanently on screen and the other cannot, and the
 * dropdown is where the expensive one lives.
 */
export type ContextReadingState = 'ok' | 'nothing-yet' | 'not-reported'

/** How the denominator was arrived at. Mirrors `ContextWindowBasis`. */
export type ContextWindowBasis = 'model' | 'observed' | 'reported'

export interface ContextReading {
  provider: ProviderId | null
  state: ContextReadingState
  /** Tokens resident in the model's context, or null when there is no figure. */
  tokens: number | null
  /** The window they sit in, or null when nothing on disk names one. */
  window: number | null
  /** `tokens / window`, or null when either half is missing. Never clamped. */
  percent: number | null
  windowBasis: ContextWindowBasis | null
  /** The model id exactly as the transcript recorded it — `claude-opus-5`. */
  model: string | null
  /** The same model under the name this app's menus use — `Opus 5`. */
  modelLabel: string | null
  /** The transcript's own session id, and whether it was named or guessed. */
  sessionId: string | null
  chosen: 'named' | 'inferred' | null
  /** Other conversations in the same folder written at about the same time. */
  rivals: number
  /** When the agent wrote the figure. 0 when the line carried no timestamp. */
  reportedAt: number
  /** When this app read the file. */
  observedAt: number
  /** A sentence a person can read. Always set, in every state. */
  detail: string
}

const CONTEXT_STATES: readonly ContextReadingState[] = ['ok', 'nothing-yet', 'not-reported']
const CONTEXT_BASES: readonly ContextWindowBasis[] = ['model', 'observed', 'reported']

function nullableNum(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * A `ContextReading` off the bridge, or null when the payload is not one.
 *
 * Defensive in the same way and for the same reason as {@link readUsageReport}:
 * this crosses a process boundary, and a build whose main process predates the
 * channel answers `undefined`. A bar drawn from a half-read payload is worse
 * than a bar with nothing on it, because only one of those two is honest about
 * what it knows.
 */
export function readContextReading(raw: unknown): ContextReading | null {
  if (!isRecord(raw)) return null
  const state = CONTEXT_STATES.find((known) => known === raw.state)
  if (state === undefined) return null
  const source = isRecord(raw.source) ? raw.source : null
  const observedAt = num(raw.observedAt)
  return {
    provider: isProviderId(raw.provider) ? raw.provider : null,
    state,
    tokens: nullableNum(raw.tokens),
    window: nullableNum(raw.window),
    percent: nullableNum(raw.percent),
    windowBasis: CONTEXT_BASES.find((known) => known === raw.windowBasis) ?? null,
    model: nullableStr(raw.model),
    modelLabel: nullableStr(raw.modelLabel),
    sessionId: source ? nullableStr(source.sessionId) : null,
    chosen: source?.chosen === 'named' ? 'named' : source?.chosen === 'inferred' ? 'inferred' : null,
    rivals: num(source?.rivals),
    // Same conservative reading of an absence as `readReading` above: a figure
    // with no stamp on it is as old as the look that found it, not "just now".
    reportedAt: num(raw.reportedAt) || observedAt,
    observedAt,
    detail: str(raw.detail),
  }
}

/**
 * What the bar prints for the context window, or null when it prints nothing.
 *
 * A number and a unit and nothing else — *"we will give an icon for it instead
 * of title"* was said of the plan control beside this, and the same economy
 * applies here: the bar has no room for the word "context" and the reader has
 * the tooltip. `formatTokens` is the app's own spelling, shared with the chat
 * pane and the dashboard so that one session's occupancy reads the same in all
 * three.
 *
 * Null rather than a dash or a zero for a reading that has no figure. An agent
 * that does not write its context down — Gemini, verified on this machine:
 * nine session files under `~/.gemini/tmp/*` and not one token count in any of
 * them — must show *nothing*, because a dash in the place a number goes is
 * still an element claiming the app is measuring something, and a zero is a
 * claim that the context is empty.
 */
export function contextFigure(reading: ContextReading | null, compact = false): string | null {
  if (!reading || reading.state !== 'ok' || reading.tokens === null) return null
  const full = formatTokens(reading.tokens)
  /*
   * `compact` drops the tenth, and it is only ever asked for at the app's
   * minimum window width, where the whole controls cluster has about a hundred
   * pixels. `154.1k` measures 39.6 there and `154k` measures 33.4, and the
   * tenth it costs is a hundred tokens out of a hundred and fifty thousand —
   * below the resolution of anything a reader would act on. Nothing else on
   * this bar is allowed to round, and this is allowed to because the rounding
   * is invisible at the scale the figure is printed in.
   */
  return compact ? full.replace(/\.\d+(?=[kMB]$)/, '') : full
}

/* ------------------------------------------------- the breakdown on hover -- */

/**
 * One coloured length of the context bar, and one row under it.
 *
 * ## Why there are exactly two of these and there will not be more
 *
 * Asad asked for what Claude Code's own `/context` shows — a segmented bar with
 * `Messages`, `System tools`, `Memory files`, `System prompt`, `Skills`,
 * `Custom agents` and `Free space` under it, each with a token count and a
 * share. Every one of those rows is real, and **none of them is on disk**. An
 * exhaustive path scan of a live 17 MB transcript (4,987 lines) and of sixty
 * more written since 2026-08-10 found exactly one decomposition anywhere in the
 * format — a `contextUsage` object on a `{type:"system", subtype:"local_command"}`
 * line — and it is written *only* when somebody runs `/context` in that
 * session. Of 5,381 transcripts on this machine, four contain one, and all four
 * were produced by a probe run deliberately while this was being investigated.
 * Asad has never run `/context` in a real session, so for his transcripts the
 * rows do not exist and cannot be computed.
 *
 * What *is* on disk, on every assistant line, is `input_tokens`,
 * `cache_read_input_tokens` and `cache_creation_input_tokens`. Their sum is the
 * resident context — verified to the token against Claude's own
 * `contextUsage.total_tokens` on four sessions of wildly different sizes
 * (31,289 / 39,802 / 764,503 / 59,216, the last after three auto-compactions).
 * That sum against the window is the one split this app can prove, so it is the
 * one it draws.
 *
 * The tempting wrong answer is to segment the bar by that cache split instead,
 * because it is three numbers and it is right there. It is a fact about
 * *caching*, not about what is in the context: on consecutive turns of one
 * session, its conversation unchanged, it went 765,011/372 → 22,119/738,868 →
 * 760,987/912 as the cache expired and was rewritten. A bar drawn from it would
 * look exactly like Claude's and would flip colour between two replies for no
 * reason a reader could act on. It is not drawn here, in any form.
 */
export interface ContextSegment {
  key: 'used' | 'free'
  /** `Used`, `Free` — the only two this app can measure. */
  label: string
  tokens: number
  /** `154.1k`, the app's own spelling, shared with the chat pane. */
  amount: string
  /** `15%`, or `<1%` — never rounded down to a zero that claims emptiness. */
  share: string
  /** Width of this length of the bar, 0..100, clamped. */
  width: number
}

/** One short labelled line of provenance. Never a sentence. */
export interface ContextFact {
  label: string
  value: string
}

export interface ContextPanel {
  /** `154.1k` — what is resident right now. */
  used: string
  /** `1M`, or null when nothing on disk names a window. */
  window: string | null
  /** `15%`, or null without a window to measure against. */
  share: string | null
  level: ContextLevel
  /** Two lengths, or empty when there is no window to divide up. */
  segments: ContextSegment[]
  /** At most two short lines under the bar. Lines, not prose. */
  facts: ContextFact[]
  /**
   * Everything the lines no longer print, as one sentence for the panel's own
   * `title`.
   *
   * This is where the provenance went, and it went somewhere rather than away.
   * Asad, reading `Session d4601913 · inferred · 1 other active here` off the
   * panel: *"it's not understandable so don't keep something which is not
   * understandable"*. He is right that it is unreadable, and it is still true —
   * which transcript this came out of, whether this app was told or guessed, and
   * how many other conversations were live in the folder at the same time are
   * the facts that decide whether the number above is his session's at all.
   *
   * So the jargon comes off the screen and stays reachable: hovering anywhere in
   * the open panel shows it, and {@link contextSummary} still speaks the whole
   * of it to a screen reader. Never empty — there is always at least a model and
   * a time to say.
   */
  provenance: string
}

/**
 * The breakdown behind the figure, or null when there is nothing to break down.
 *
 * ## What this replaced, and why
 *
 * A paragraph. The figure's hover used to be one run-on sentence that said the
 * same thing twice — *"Read from the most recently updated transcript in this
 * folder…"* out of the main process's `detail`, and then *"Read from the most
 * recently written transcript in this folder (92b0e6db…), which this app
 * inferred rather than was told"* again a clause later. Asad put it next to
 * Claude Code's own `/context` panel and asked for *"this clean and visual…
 * keep the main bar in header and rest when hover"*.
 *
 * So the provenance is not deleted — every fact it carried is still here — it
 * is turned into labelled lines, and the duplicated sentence collapses into the
 * single word `inferred` on the session line. Nothing is invented to fill the
 * shape out: see {@link ContextSegment} for the rows that were asked for, are
 * real, and are not on this machine's disk to draw.
 */
export function contextPanel(reading: ContextReading | null, now: number): ContextPanel | null {
  if (!reading || reading.state !== 'ok' || reading.tokens === null) return null
  const tokens = reading.tokens
  const window = reading.window
  const percent = reading.percent

  const segments: ContextSegment[] = []
  if (window !== null && window > 0) {
    /*
     * Free space is arithmetic on two measured quantities, not a third
     * measurement — and it is the same arithmetic Claude does: on the first
     * `/context` of a session `total_tokens + Free space === raw_max_tokens`
     * exactly, checked against real records.
     *
     * Floored at zero because the two halves can disagree. `context-window.ts`
     * raises the window to a high-water mark when a transcript proves the model
     * held more than the table says — the `[1m]` tag the usage lines never carry
     * — and until that lands a reading can be over its own denominator. A
     * negative length is not drawn; the `used` row simply fills the bar and says
     * so with a share past 100%.
     */
    const free = Math.max(0, window - tokens)
    segments.push({
      key: 'used',
      label: 'Used',
      tokens,
      amount: formatTokens(tokens),
      share: formatPercent((tokens / window) * 100),
      width: Math.min(100, Math.max(0, (tokens / window) * 100)),
    })
    if (free > 0) {
      segments.push({
        key: 'free',
        label: 'Free',
        tokens: free,
        amount: formatTokens(free),
        share: formatPercent((free / window) * 100),
        width: Math.min(100, Math.max(0, (free / window) * 100)),
      })
    }
  }

  /*
   * Two lines at most, and each of them a thing he can read.
   *
   * What was here was five: the raw model id, the session id with `inferred` and
   * a rival count after it, a note on where the denominator came from, and an
   * age. He named the failure precisely — *"the way it is typing claude-opus
   * star dash 5 and then the other way it's too messy"*, *"don't keep something
   * which is not understandable"* — and the shape of the fix is the one he asked
   * for the whole panel to have: *"clean and visual"*.
   *
   * So the lines that survive are the ones a person acts on, under the names the
   * rest of the app already uses for them, and everything else is one hover
   * away in {@link ContextPanel.provenance}. Nothing is dropped; the panel just
   * stops shouting the parts only this app cares about.
   */
  const facts: ContextFact[] = []
  /*
   * The model, because it sets the denominator — the one thing on this panel
   * that changes what the percentage means. He half-granted it himself: *"model
   * I think yeah maybe"*. What he would not have is the id, and there is no
   * reason to print one: `labelModelId` in the main process is the same table
   * the model chip on this very bar reads through, so the panel and the chip now
   * say `Opus 5` in the same words. The id is still in the hover, for the case
   * where the difference between `claude-opus-5` and `claude-opus-4-8` is
   * exactly what somebody is checking.
   */
  const model = reading.modelLabel ?? reading.model
  if (model !== null) facts.push({ label: 'Model', value: model })
  /*
   * And how current the figure is — but only when that is news.
   *
   * This is the line he caught lying: `Written 7d ago` on a session he had
   * opened minutes earlier. The lie was in the reading, not the row — the app
   * was reading a transcript whose file had been touched but whose conversation
   * had stopped a week before, and `context-window.ts` now picks by the age of
   * the last *turn* rather than the age of the file. See the walk in
   * `readContextWindow` for the measurements.
   *
   * With that fixed the age is worth having, on his own test: a figure written
   * seconds ago needs no caption, and one written hours ago is a warning that
   * the number is a memory of a conversation that has stopped. So the row is
   * drawn only when `describeAge` has something to say — its own `just now`
   * threshold is where "current" ends, and it is already the boundary every plan
   * reading in this app is captioned against. `Updated` rather than `Written`,
   * which is the word he read as being about the transcript rather than about
   * the number above it.
   */
  const age = describeAge(reading.reportedAt, now)
  if (age !== '' && age !== 'just now') facts.push({ label: 'Updated', value: age })

  return {
    used: formatTokens(tokens),
    window: window === null ? null : formatTokens(window),
    share: percent === null ? null : formatPercent(percent),
    level: levelOfPercent(percent),
    segments,
    facts,
    provenance: contextProvenance(reading, now),
  }
}

/**
 * The provenance the panel used to print, as one sentence for its `title`.
 *
 * Written as prose rather than as the labelled fragments it replaces, because a
 * tooltip has the room a 300px panel does not and because the fragments are
 * exactly what was unreadable. Every clause is conditional on there being
 * something true to say: an app that was *told* which transcript to read does
 * not explain that it guessed, and a folder with one conversation in it does not
 * mention rivals.
 */
function contextProvenance(reading: ContextReading, now: number): string {
  const parts: string[] = []
  if (reading.model !== null) parts.push(`Model ${reading.model}.`)
  if (reading.sessionId !== null) {
    const how =
      reading.chosen === 'inferred'
        ? ', which this app picked as the folder’s most recent conversation rather than being told'
        : ''
    parts.push(`Read from session ${reading.sessionId}${how}.`)
  }
  if (reading.rivals > 0) {
    parts.push(
      reading.rivals === 1
        ? 'One other conversation was active in this folder at the same time, so this may be that one’s.'
        : `${reading.rivals} other conversations were active in this folder at the same time, so this may be one of theirs.`,
    )
  }
  /*
   * Where the denominator came from, and only when it is not the ordinary
   * answer. `model` is this app's own table and needs no remark; `observed`
   * means the transcript proved a larger window than the table knows — the
   * `[1m]` session whose usage lines never carry the tag — and `reported` means
   * the agent stated its own. Both change what the percentage means.
   */
  if (reading.windowBasis === 'observed') {
    parts.push('The window is larger than this app’s table for that model, and was taken from what the transcript proves it held.')
  }
  if (reading.windowBasis === 'reported') parts.push('The window is the one the agent reports for itself.')
  const age = describeAge(reading.reportedAt, now)
  if (age !== '') parts.push(`The agent wrote this figure ${age === 'just now' ? 'just now' : age}.`)
  return parts.join(' ')
}

/**
 * The same reading in one line, for a screen reader and for the bar's own name.
 *
 * The panel above is a hover, and a hover is not available to everybody. This
 * is what the control is *called*, so the whole reading survives being unable
 * to open it: the figure, the window, the share, and then the provenance in
 * full.
 *
 * It reads {@link ContextPanel.provenance} rather than the lines the panel
 * draws, and that is the point of the split rather than an accident of it. The
 * lines were cut down to the two a person can act on at a glance; an accessible
 * name has no width to run out of and no reason to be shortened, so it keeps
 * everything — including the session id spelled out in full, which is the one
 * place the eight characters that used to be on screen can be resolved back.
 */
export function contextSummary(reading: ContextReading | null, now: number): string | null {
  const panel = contextPanel(reading, now)
  if (!panel || !reading) return null
  const head =
    panel.window === null
      ? `Context ${panel.used} — no window reported`
      : `Context ${panel.used} of ${panel.window}${panel.share === null ? '' : ` (${panel.share})`}`
  return panel.provenance === '' ? `${head}.` : `${head}. ${panel.provenance}`
}

/**
 * What colour the context figure takes, on the app's own thresholds.
 *
 * The same `levelOfPercent` the chat pane's context meter and every plan
 * reading use, so one session's occupancy is the same colour wherever it is
 * drawn. `ok` when there is no percentage at all, which is the honest answer:
 * a token count with no known window is not a reading that is *fine*, it is a
 * reading with nothing to be measured against, and colouring it as a warning
 * would be a claim the app cannot support.
 */
export function contextLevel(reading: ContextReading | null): ContextLevel {
  return levelOfPercent(reading?.state === 'ok' ? reading.percent : null)
}

/**
 * The same reading as a bar length, 0..100, or null when there is none to draw.
 *
 * Clamped at the top, and the clamp is not defensive tidiness: a transcript can
 * report more resident tokens than the window it names — an auto-compaction
 * lands mid-turn, or the window came from the model table rather than from the
 * transcript — and a length past 100 draws a fill wider than its own track.
 * Not clamped at the bottom to a visible minimum: a nearly-empty window is
 * nearly-empty, and a floor would draw occupancy that is not there.
 */
export function contextShare(reading: ContextReading | null): number | null {
  if (!reading || reading.state !== 'ok' || reading.percent === null) return null
  return Math.max(0, Math.min(100, reading.percent))
}
