/**
 * One vocabulary for "how much of a subscription window is gone", whatever
 * agent reported it.
 *
 * The feature this serves is a bar next to the account: five hours of Claude,
 * five hours of Codex, the week behind each of them. Two agents report that
 * number in two entirely different ways — Claude Code draws it on its own
 * screen in prose, Codex writes a struct into its rollout transcript — and the
 * chrome that draws the bar must not have to know which. So the readers here
 * each translate into the one shape below, and the shape is deliberately
 * pedantic about the two things that turned this feature into a near-miss:
 *
 * **Unknown is not zero.** `~/.claude.json` carries a `cachedUsageUtilization`
 * block with exactly the fields a bar wants, and on this machine it was 21.3
 * hours stale, described a window that had *already ended*, and did not move
 * across a day of continuous use, five rewrites of the file, or two fresh TUI
 * launches. A bar drawn from it would have been confidently wrong. That is why
 * {@link UsageAmount} and {@link UsageReset} are unions with an explicit
 * `not-reported` case rather than `number | null` fields that some caller will
 * eventually `?? 0`. Nothing in this module can produce a zero it was not told.
 *
 * **A reading is only as good as when it was taken.** Every reading carries
 * both `observedAt` — when this app looked — and `reportedAt` — when the source
 * produced the number. For Codex those are far apart by construction: the
 * rollout only gains a `rate_limits` record when a turn runs, so a reading can
 * be a week old and still be *exact about a week ago*. {@link usageFreshness}
 * turns that gap into the two facts a consumer actually needs: has the window
 * itself rolled over since, and how much of it has gone by unmeasured.
 *
 * No estimating, anywhere. If a source did not say it, this module does not
 * know it.
 */

import type { ProviderId } from '../shared/types'

/* -------------------------------------------------------------------------- */
/* The reading                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Which rolling window a reading describes.
 *
 * Named after the period rather than after the vendor's word for it, because
 * "session" (Claude) and "primary" (Codex) are the same five hours and a
 * consumer that had to know both spellings would be a consumer that gets one of
 * them wrong. `other` is the honest answer for a window whose length is not one
 * of the three — a credit pool, or a period a vendor ships next month — and it
 * still carries its `windowMinutes` so the consumer can decide for itself.
 */
export type UsageWindowKind = 'five-hour' | 'weekly' | 'monthly' | 'other'

/** Where a reading was taken from. Named per source, not per provider. */
export type UsageSourceId = 'claude-usage-panel' | 'claude-warning' | 'codex-rollout'

/**
 * How much of the window has been used.
 *
 * A union rather than `number | null` so that "the source said 0%" and "the
 * source said nothing" cannot be spelled the same way, and so that a consumer
 * has to look at `state` before it can reach the number. Those two facts are
 * opposites: one means the bar is empty, the other means there is no bar.
 */
export type UsageAmount =
  /** `fraction` is 0..1 of the limit, and may exceed 1 — a limit can be blown through. */
  | { state: 'reported'; fraction: number }
  | { state: 'not-reported' }

/**
 * When the window rolls over.
 *
 * Three cases because the sources genuinely differ. Codex writes a Unix
 * instant, which is exact and comparable. Claude Code prints words — `4am
 * (Asia/Dubai)`, `Aug 14 at 2pm (Asia/Dubai)` — and turning those into an
 * instant means guessing a year, a locale and a DST rule from a string that
 * omits all three. So the words are carried verbatim and the consumer shows
 * them; a wrong instant would silently poison every "is this still valid?"
 * comparison downstream, which is a far worse failure than not being able to
 * count down.
 */
export type UsageReset =
  | { state: 'at'; at: number }
  | { state: 'described'; text: string }
  | { state: 'not-reported' }

/**
 * Which login a reading belongs to.
 *
 * An account in this app is a configuration directory handed to somebody else's
 * CLI — see `provider-accounts.ts` — so that is what identifies one here too.
 * `id` is the profile id when this app resolved one; `configDir` is the thing
 * that is actually true whether or not a profile exists. Neither is ever
 * invented: a session with no account resolved carries nulls, because saying
 * which account a number belongs to when you do not know is how two logins end
 * up sharing one bar.
 */
export interface UsageAccountRef {
  provider: ProviderId
  /** Profile id, when this app resolved one. Null for an unattributed reading. */
  id: string | null
  /** What to call the account on screen. Null when nothing is known. */
  name: string | null
  /** The configuration directory the reading belongs to, when known. */
  configDir: string | null
}

export interface UsageWindowReading {
  /**
   * Stable across pushes, unique within a report: `<provider>/<account>/<window>`.
   *
   * The account is part of the key on purpose. A machine-wide read can hold two
   * Codex accounts, and keying on the window alone would have the second
   * silently replace the first in any consumer that maps by id.
   */
  id: string
  account: UsageAccountRef
  window: UsageWindowKind
  /**
   * The window's length in minutes, exactly as the source stated it, or null
   * when the source did not state one.
   *
   * Claude Code never states it — the panel says "Current session", not "300
   * minutes" — so this is null for every Claude reading, and
   * {@link nominalWindowMinutes} supplies a length for freshness arithmetic
   * without pretending the source provided it.
   */
  windowMinutes: number | null
  /**
   * What to call this window on screen.
   *
   * The source's own words wherever it gives any — Claude Code's `Current week
   * (all models)` is carried through exactly as printed, wording and
   * parentheses and all. Codex names nothing (`limit_name` is null in every
   * rollout on this machine) and states a length instead, so its label is that
   * length written out. Either way this is a statement of what the source said,
   * never a re-interpretation of it.
   */
  label: string
  used: UsageAmount
  resets: UsageReset
  /** When this app read it. */
  observedAt: number
  /**
   * When the *source* produced the number, which is never later than
   * `observedAt` and for Codex is frequently much earlier.
   */
  reportedAt: number
  source: UsageSourceId
}

/**
 * Everything readable for one scope at one moment.
 *
 * `readings` empty is not an error and not a zero — it is "nothing has been
 * reported", and `reason` is the sentence explaining which flavour of nothing.
 * Claude Code prints usage only near a limit or when `/usage` is run, so an
 * empty report is the *normal* state for a fresh session and the consumer must
 * be able to say so rather than draw an empty bar.
 */
export interface UsageReport {
  /** The session this was assembled for, or null for a machine-wide read. */
  sessionId: string | null
  readings: UsageWindowReading[]
  /** One sentence, present exactly when `readings` is empty. */
  reason: string | null
  /**
   * Whose subscription this report is about, when the scope has one login.
   *
   * Carried separately from the readings because the *ordinary* state of this
   * feature is a report with no readings in it — Claude Code prints its limits
   * only near one or when `/usage` is run — and a surface that can only name an
   * account by reading one off a reading is a surface that says "not reported"
   * without ever saying by whom. "Nothing has been reported for
   * app.imatch.ae@gmail.com" and "nothing has been reported" are different
   * sentences, and only the first can be checked against the account chip
   * sitting next to it.
   *
   * Null for a machine-wide read, which by definition spans several logins, and
   * null for a session this process cannot identify.
   */
  account: UsageAccountRef | null
  assembledAt: number
}

/** Channel the renderer receives pushed reports on. */
export const USAGE_CHANNEL = 'usage:update'

/* -------------------------------------------------------------------------- */
/* Constructors                                                                */
/* -------------------------------------------------------------------------- */

export const NOT_REPORTED: UsageAmount = { state: 'not-reported' }
export const NO_RESET: UsageReset = { state: 'not-reported' }

/**
 * A percentage as reported by a CLI, turned into a fraction — or `not-reported`.
 *
 * Everything that is not a finite, non-negative number becomes `not-reported`,
 * including `null`, `undefined` and `NaN`. The ceiling matches
 * `plan-limit.ts`: over 100% is real, because a limit can be exhausted and then
 * exceeded, but a four-digit percentage is a mis-parse and a mis-parse must not
 * be drawn.
 */
export function fractionFromPercent(percent: number | null | undefined): UsageAmount {
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return NOT_REPORTED
  if (percent < 0 || percent > 999) return NOT_REPORTED
  return { state: 'reported', fraction: percent / 100 }
}

/**
 * A reset instant from a source that gives one.
 *
 * Seconds and milliseconds are both accepted because the Unix epoch in seconds
 * is what Codex writes (`"resets_at":1777519084`, checked against the rollout
 * it sits in) while every timestamp inside this app is milliseconds. The
 * threshold is the only place the two can be told apart, and it is safe by a
 * factor of thirty thousand years.
 */
export function resetAtEpoch(value: number | null | undefined): UsageReset {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return NO_RESET
  const ms = value < 1e12 ? value * 1000 : value
  return { state: 'at', at: Math.round(ms) }
}

/** A reset a source only described in words. Blank text is no reset at all. */
export function resetDescribed(text: string | null | undefined): UsageReset {
  const trimmed = typeof text === 'string' ? text.trim() : ''
  return trimmed === '' ? NO_RESET : { state: 'described', text: trimmed }
}

/**
 * Classify a window by the length the source stated.
 *
 * Exact matches only, and the three values are the ones seen in real rollouts
 * on this machine: 300 (five hours), 10080 (a week), 43200 (thirty days,
 * written by a `plan_type: "go"` account). Anything else is `other` rather than
 * being rounded into the nearest familiar bucket — a 360-minute window called
 * "five-hour" would be a bar that is wrong by 20% at every point of its length.
 */
export function windowFromMinutes(minutes: number | null | undefined): UsageWindowKind {
  if (minutes === 300) return 'five-hour'
  if (minutes === 10080) return 'weekly'
  if (minutes === 43200) return 'monthly'
  return 'other'
}

/**
 * The length of a window in minutes for arithmetic, when the source did not
 * say.
 *
 * Deliberately *not* written into `windowMinutes`, which is a record of what
 * the source stated. This is only ever used to scale a staleness threshold —
 * "how long before a five-hour reading stops meaning much" — and never shown,
 * so a nominal length is doing no work that a real one would do better. Null
 * for `other`, where guessing would be exactly the invention this module is
 * built to refuse.
 */
export function nominalWindowMinutes(window: UsageWindowKind): number | null {
  if (window === 'five-hour') return 300
  if (window === 'weekly') return 10080
  if (window === 'monthly') return 43200
  return null
}

/* -------------------------------------------------------------------------- */
/* Freshness                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * How much of a window may pass before its reading stops being worth drawing.
 *
 * A twelfth: twenty-five minutes of a five-hour window, fourteen hours of a
 * week. It is a judgement, not a measurement, and it is here rather than in a
 * consumer so that every surface agrees. A consumer that disagrees has `ageMs`
 * and can decide for itself — which is the point of carrying the timestamps
 * rather than a boolean.
 */
export const STALE_WINDOW_FRACTION = 1 / 12

export interface UsageFreshness {
  /** How long ago the *source* produced the number. */
  ageMs: number
  /**
   * The window this reading describes has since rolled over, so the number
   * describes a period that no longer exists.
   *
   * This is the exact failure of `~/.claude.json`'s cached block: a
   * percentage for a window that had ended seventeen hours earlier, which
   * reads as current unless something checks. Only decidable when the source
   * gave an instant; a reset the CLI merely described in words cannot be
   * compared to the clock, and false here means "not known to have expired".
   */
  expired: boolean
  /** Enough of the window has gone by unmeasured that the number has drifted. */
  stale: boolean
}

export function usageFreshness(reading: UsageWindowReading, now = Date.now()): UsageFreshness {
  const ageMs = Math.max(0, now - reading.reportedAt)
  const expired = reading.resets.state === 'at' && reading.resets.at <= now
  const minutes = reading.windowMinutes ?? nominalWindowMinutes(reading.window)
  // No length, no threshold. Reporting `stale: false` for a window of unknown
  // length would be a claim about drift that nothing here can support, so the
  // age is handed over bare and the consumer decides.
  const stale =
    minutes === null ? false : ageMs > minutes * 60_000 * STALE_WINDOW_FRACTION
  return { ageMs, expired, stale }
}

/**
 * Whether a bar may honestly be drawn from this reading.
 *
 * Three conditions, all of which have been violated by something during this
 * feature's short life: the source must have given a number, the window must
 * not have rolled over since, and the number must not have drifted. Consumers
 * are free to draw a greyed-out or aged bar instead — everything this returns
 * false for still carries its timestamps — but nothing may draw a *live* bar
 * without passing here.
 */
export function isDrawable(reading: UsageWindowReading, now = Date.now()): boolean {
  if (reading.used.state !== 'reported') return false
  const freshness = usageFreshness(reading, now)
  return !freshness.expired && !freshness.stale
}

/* -------------------------------------------------------------------------- */
/* Assembly                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * The key part of a reading's id that names the account.
 *
 * The configuration directory when there is one, because that is what an
 * account *is* here and two profiles can share a name. `system` for a reading
 * this app could not attribute — one bucket, which is right: unattributed
 * readings are not distinguishable from each other either.
 */
export function accountKey(account: UsageAccountRef): string {
  return account.id ?? account.configDir ?? 'system'
}

export function readingId(account: UsageAccountRef, window: UsageWindowKind, suffix = ''): string {
  const tail = suffix === '' ? window : `${window}:${suffix}`
  return `${account.provider}/${accountKey(account)}/${tail}`
}

/**
 * Order readings the way a person reads them: shortest window first.
 *
 * The five-hour bar is the one Asad asked for and the one that moves; the week
 * is context for it. Within a period, the account name keeps a machine-wide
 * report from reshuffling itself between pushes.
 */
const WINDOW_ORDER: Record<UsageWindowKind, number> = {
  'five-hour': 0,
  weekly: 1,
  monthly: 2,
  other: 3,
}

export function sortReadings(readings: UsageWindowReading[]): UsageWindowReading[] {
  return [...readings].sort((a, b) => {
    const byWindow = WINDOW_ORDER[a.window] - WINDOW_ORDER[b.window]
    if (byWindow !== 0) return byWindow
    return a.id.localeCompare(b.id)
  })
}

/**
 * Build a report, with the `reason` field kept in step with the readings.
 *
 * A single constructor because the invariant — a reason exactly when the list
 * is empty — is the whole contract with the consumer, and it was going to be
 * re-implemented at every call site otherwise.
 */
export function usageReport(
  sessionId: string | null,
  readings: UsageWindowReading[],
  reason: string,
  at = Date.now(),
  account: UsageAccountRef | null = null,
): UsageReport {
  const sorted = sortReadings(readings)
  return {
    sessionId,
    readings: sorted,
    reason: sorted.length === 0 ? reason : null,
    account,
    assembledAt: at,
  }
}
