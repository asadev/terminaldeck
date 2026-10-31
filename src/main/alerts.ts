/**
 * Smart alerts — the handful of things about a project worth interrupting for.
 *
 * Split deliberately in two:
 *
 *  - **A pure layer** (`deriveAlerts` and the rules it calls) that takes data
 *    someone else already gathered and returns alerts. No filesystem, no child
 *    processes, no clock of its own. Every threshold in it is a named constant,
 *    so the tests are about behaviour rather than plumbing.
 *  - **A gathering layer** (`collectAlertInput`, `registerAlertsIpc`) that goes
 *    and fetches the transcripts, the git status and the installed CLIs.
 *
 * The reason for the split is the invariant this module lives or dies by: **a
 * brand-new project must be silent.** An alerts panel that greets an empty
 * folder with five warnings gets ignored within a day, and then it is worse
 * than nothing because the one real alert is ignored too. Every rule below
 * therefore requires positive evidence — sessions that actually ran, a provider
 * actually in use, enough sessions with tokens on them for a median to mean
 * anything — and returns nothing when it has none.
 *
 * Thresholds for context come from `cost.ts` rather than being restated here,
 * so the inspector's bloat warning and this panel can never disagree.
 *
 * Wiring:
 *
 *     import { registerAlertsIpc } from './alerts'
 *     registerAlertsIpc(ipcMain)
 */

import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { stat } from 'node:fs/promises'
import { isAbsolute, join, resolve } from 'node:path'
import type { ProviderId, SessionStatus } from '../shared/types'
import {
  contextWarning,
  formatTokens,
  preContextWarning,
  totalTokens,
  type ContextUsage,
} from './cost'
/*
 * Across into `deck-control/` for one function, which is the wrong direction on
 * paper and the right one here.
 *
 * `progress.ts` is the app's judgement about whether an agent is getting
 * anywhere. It happens to live under `deck-control/` because the copilot was
 * the first thing that needed it, and it depends on nothing from that folder —
 * one type import, erased at compile — so nothing circular arrives with it.
 * Moving it up here would be the tidier arrangement and a larger edit into a
 * file another agent is holding; importing it is what keeps the panel and the
 * copilot answering "is that session stuck" with the same numbers, which is
 * the property that actually matters.
 */
import { assessProgress, REPEAT_CRITICAL, type ProgressReport } from './deck-control/progress'
import { readGitStatus, type GitStatusResult } from './git'
import { detectProviders, PROVIDERS } from './providers'
import { readToolTrail, TRAIL_WINDOW_BYTES } from './tool-trail'
import {
  DEFAULT_MAX_AGE_MS,
  DEFAULT_MAX_SESSIONS,
  listTranscripts,
  readTranscript,
  transcriptDirs,
  type TranscriptScope,
} from './transcript'

export const ALERTS_CHANNEL = 'alerts:project'

/* -------------------------------------------------------------------------- */
/* Thresholds                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * How long a session may sit on an unanswered question before it is an alert.
 *
 * `session-activity.ts` distinguishes `waiting` (an empty prompt, ready for
 * you) from `input` (a question asked and not answered). Only the second is
 * blocked — a session parked at a ready prompt is just a session you are not
 * using, and alerting on that would fire on every open tab.
 */
export const BLOCKED_WARNING_MS = 10 * 60 * 1000
export const BLOCKED_CRITICAL_MS = 45 * 60 * 1000

/**
 * This rule used to be about money: a session that had *cost* several times the
 * project median, with the two dollar figures in its detail line. It is about
 * tokens now, and it is a better rule for it. The money was never the signal —
 * it was tokens multiplied by a rate card, and the rate card was the part this
 * app had no honest way to apply (see the bottom of `cost.ts`). A session that
 * moved eight times the usual number of tokens is the same runaway session,
 * measured directly, in a unit the transcript actually recorded.
 */

/** Sessions with tokens on them needed before a median is worth comparing against. */
export const HEAVY_MIN_SAMPLE = 5
/** Multiple of the project median that counts as unusual. */
export const HEAVY_MULTIPLE = 3
/**
 * Where a heavy session stops being a curiosity and starts being worth acting
 * on. It still never reaches `critical`: tokens already spent are not an
 * emergency, and ranking it above a blocked session or a missing CLI would put
 * the one alert you cannot act on at the top of the list.
 */
export const HEAVY_SEVERE_MULTIPLE = 6
/**
 * Absolute floor, because a ratio alone is meaningless at small counts: a
 * project whose median session moves 4k tokens would otherwise raise an alert
 * the first time one moves 20k, which is a single long answer.
 *
 * A million is roughly one warm agent session that never compacted — the shape
 * this alert exists to catch. Below it, a multiple of the median is describing
 * noise.
 */
export const HEAVY_MIN_TOKENS = 1_000_000

/**
 * How recently a session must have done something for a loop to be worth
 * raising.
 *
 * A loop alert is about money being spent *now*. A transcript that stopped
 * moving two hours ago describes a session that already finished being stuck,
 * and there is nothing left to interrupt anybody about — the evidence is still
 * there for `sessions.result` to read when somebody asks. Thirty minutes is
 * comfortably longer than the span of the thirty tool calls
 * `deck-control/progress.ts` examines, so a session that is genuinely mid-loop
 * is always inside it.
 */
export const LOOP_ACTIVE_WITHIN_MS = 30 * 60 * 1000

/**
 * How many transcripts one scan will read the tool trail of.
 *
 * The trail read is a bounded tail rather than the whole file, so it is cheap
 * next to the full `readTranscript` pass this scan already does — but it is not
 * free, and a project with forty recent transcripts must not turn a 60-second
 * refresh into forty extra reads. Three is enough: the sessions are sorted by
 * how recently they moved, and a person running more than three agents in one
 * folder at once has a different problem.
 */
export const LOOP_MAX_TRAILS = 3

/** Sessions that have to have run since the working tree was last touched. */
export const DIRTY_TREE_SESSION_STREAK = 3
export const DIRTY_TREE_CRITICAL_STREAK = 8
/** Below this a dirty tree is normal work in progress, not an accumulation. */
export const DIRTY_TREE_MIN_FILES = 1

/* -------------------------------------------------------------------------- */
/* Types                                                                       */
/* -------------------------------------------------------------------------- */

export type AlertSeverity = 'info' | 'warning' | 'critical'

export type AlertKind =
  | 'context-bloat'
  | 'pre-context-bloat'
  | 'session-blocked'
  | 'provider-missing'
  | 'heavy-session'
  /**
   * A live session that is repeating itself and writing nothing.
   *
   * The one alert here that is about *behaviour* rather than about a quantity.
   * Everything else in this list fires on a number crossing a line — context
   * percentage, token multiple, minutes blocked, files uncommitted — and a
   * session stuck in a loop crosses none of them: it is `working`, the dot is
   * green, output is arriving, and the token count climbs at the ordinary rate
   * for as long as somebody lets it. `heavy-session` eventually catches the
   * expensive ones, at `HEAVY_MIN_TOKENS` — a million tokens later.
   *
   * `COPILOT-CAPABILITIES.md` §2.3 calls loop detection "the cheapest safety
   * feature in the design and the one most often skipped", and the reason it
   * has to be an *alert* rather than only a tool the copilot can call is in the
   * same sentence: the failure this catches happens while nobody is looking.
   */
  | 'loop'
  | 'dirty-tree'
  /**
   * A device has paired and is waiting for somebody here to approve it.
   *
   * **Nothing in this file produces one, and that is deliberate rather than an
   * omission.** Every rule below is a fact about *a project*, reached by reading
   * that project's transcripts and its git state; this is a fact about *the
   * machine*, equally true in every folder open on it, and it is not visible
   * from anything `collectAlertInput` reads. The window derives it from the
   * device roster the remote bridge already answers with, and folds it into the
   * report — see `src/renderer/alerts-devices.ts`, which carries the argument at
   * length.
   *
   * The kind lives here anyway, because this file is the *vocabulary* the panel
   * mirrors, and a kind declared only on the renderer's copy would be the exact
   * drift that copy's comment warns about. What a producer must not do is claim
   * a kind it cannot evaluate; declaring one it does not raise costs nothing and
   * keeps both sides reading from one list.
   */
  | 'device-pending'

/**
 * What the UI offers to do about an alert. Optional — several alerts are worth
 * knowing about and have no single right response.
 */
export interface AlertAction {
  kind:
    | 'open-inspector'
    | 'focus-session'
    | 'compact-session'
    | 'open-git'
    | 'install-provider'
    /**
     * Open the step-by-step approval flow for the device in `target`.
     *
     * The odd one out among these, and the difference is worth stating because
     * it is a security property rather than a routing detail. The other five are
     * *navigations* — show a panel, focus a tab — and the sheet hands them to the
     * window to carry out. This one is answered by the alerts sheet itself, which
     * mounts the very same `DeviceApproval` flow the settings pane mounts and
     * ends in the very same `remote:device:approve` call, the one that writes the
     * device's kind and its folders **before** it admits anything.
     *
     * It is written that way so there is exactly one road into approval. An
     * action that merely opened Settings would be an alert telling somebody to go
     * and look — the failure this whole surface exists to remove — and one that
     * approved the device outright would be a second road into the gate, with the
     * two questions the flow asks skipped.
     */
    | 'approve-device'
  label: string
  /** Session id, provider id, device id or path, depending on `kind`. */
  target?: string
}

export interface Alert {
  /**
   * Stable across refreshes for the same underlying condition, so the panel can
   * keep a dismissal or an expansion attached to it rather than to a list index.
   */
  id: string
  kind: AlertKind
  severity: AlertSeverity
  title: string
  /** Plain-language explanation: what happened, and why it matters. */
  detail: string
  sessionId?: string
  /** Epoch ms of the evidence, not of the scan. */
  at: number
  action: AlertAction | null
}

/** One session's already-gathered numbers. */
export interface AlertSession {
  sessionId: string
  transcriptPath: string
  /** Occupancy of the context window, or null before the first request. */
  context: ContextUsage | null
  /** Prompt size of the first request — the prefix every later turn re-pays. */
  preContextTokens: number
  /** Deduplicated API requests. Zero means the transcript exists but is empty. */
  requests: number
  /** Every token class summed — input, output and both cache sides. */
  tokens: number
  startedAt: number
  lastActivityAt: number
  /** Live status when the session is open in the app; null for history. */
  status: SessionStatus | null
  /** Epoch ms the status last changed, used to age a blocked session. */
  statusSince?: number
  provider?: ProviderId
  /**
   * What the tail of this session's tool use looks like, when it was read.
   *
   * Absent on most entries and that is the normal case, not a gap:
   * `collectAlertInput` only reads a trail for the handful of transcripts that
   * could be about a *live* loop — see {@link LOOP_ACTIVE_WITHIN_MS} and
   * {@link LOOP_MAX_TRAILS}. `undefined` here means "not looked at", which
   * {@link loopAlerts} treats as silence. It is deliberately not the same value
   * as a {@link ProgressReport} whose verdict is `unknown`, which means "looked,
   * and there was nothing to read" — the distinction the whole of `progress.ts`
   * exists to keep, because reporting silence as health is how a supervision
   * surface starts lying.
   */
  progress?: ProgressReport
  /**
   * The app's own id for the session this transcript belongs to, when it can be
   * told, so an alert about it can point at a tab.
   *
   * Almost always absent, and the reason is the namespace split documented at
   * the bottom of `collectAlertInput`: `PtyManager` names a session with its own
   * `randomUUID()` while a transcript is named with the id the CLI generated
   * inside that process, so {@link AlertSession.sessionId} on a transcript entry
   * is *not* a session id this app can focus. It is filled in only for the one
   * case where the answer is a fact rather than a guess — exactly one live
   * session open in the folder — which is the same `only-one` basis
   * `deck-control/transcript-match.ts` reasons about at greater length.
   */
  appSessionId?: string
}

export interface AlertGit {
  /** False for a folder that is not a repository — never an alert on its own. */
  repo: boolean
  dirty: boolean
  changedFiles: number
  /**
   * Newest mtime among the uncommitted files. Sessions that started after it
   * are sessions that ran on top of work nobody committed.
   */
  lastChangeAt: number | null
}

export interface AlertInput {
  projectPath: string
  now: number
  sessions: AlertSession[]
  /**
   * Providers this project actually uses — from its open sessions and its saved
   * default. Empty means "we have no evidence any CLI is wanted here", which is
   * exactly the state a new project is in, and no provider alert fires.
   */
  providersInUse: ProviderId[]
  /** Which CLIs are on PATH, from `detectProviders()`. */
  providersInstalled: Partial<Record<ProviderId, boolean>>
  git: AlertGit | null
}

export interface AlertReport {
  projectPath: string
  alerts: Alert[]
  counts: Record<AlertSeverity, number>
  /** Highest severity present, or null when the project is quiet. */
  worst: AlertSeverity | null
  scannedAt: number
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

const SEVERITY_ORDER: Record<AlertSeverity, number> = { critical: 0, warning: 1, info: 2 }

export function median(values: number[]): number {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/** Human duration at the coarseness the sentence needs — "12 minutes", "3 hours". */
export function formatDuration(ms: number): string {
  // Clamped before the plural is chosen: a 20-second wait rounds to 0 minutes,
  // and reporting it as "1 minutes" is the classic version of this bug.
  const minutes = Math.max(1, Math.round(ms / 60_000))
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'}`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'}`
  const days = Math.round(hours / 24)
  return `${days} day${days === 1 ? '' : 's'}`
}

/** Short, stable session label for a sentence. Full uuids are unreadable. */
function shortId(sessionId: string): string {
  return sessionId.slice(0, 8)
}

/**
 * Sessions that produced something. A transcript with zero requests is a file
 * the CLI opened and never used, and it must not weigh on any rule.
 */
function activeSessions(sessions: AlertSession[]): AlertSession[] {
  return sessions.filter((session) => session.requests > 0)
}

/* -------------------------------------------------------------------------- */
/* Rules                                                                       */
/* -------------------------------------------------------------------------- */

/**
 * Context bloat, straight off `cost.ts`'s thresholds.
 *
 * Only the most recently active session is considered: an old session's final
 * context is history, not a thing anyone can act on, and reporting one line per
 * historical session would bury the live one.
 */
export function contextAlerts(input: AlertInput): Alert[] {
  const active = activeSessions(input.sessions)
  if (active.length === 0) return []

  const newest = [...active].sort((a, b) => b.lastActivityAt - a.lastActivityAt)[0]
  const alerts: Alert[] = []

  if (newest.context) {
    const warning = contextWarning(newest.context)
    if (warning) {
      alerts.push({
        id: `context-bloat:${newest.sessionId}`,
        kind: 'context-bloat',
        severity: warning.level,
        title: `Context ${Math.round(newest.context.percent)}% full`,
        // The old third sentence argued the case for compacting now. The alert
        // already carries a "Compact this session" button; an alert that has to
        // sell its own action twice is one sentence too long.
        detail: `${warning.message} Session ${shortId(newest.sessionId)} is holding ${formatTokens(
          newest.context.tokens,
        )} of a ${formatTokens(newest.context.window)} window.`,
        sessionId: newest.sessionId,
        at: newest.lastActivityAt,
        action: { kind: 'compact-session', label: 'Compact this session', target: newest.sessionId },
      })
    }
  }

  const window = newest.context?.window ?? 0
  const prefix = preContextWarning(newest.preContextTokens, window)
  if (prefix) {
    alerts.push({
      id: `pre-context-bloat:${newest.sessionId}`,
      kind: 'pre-context-bloat',
      severity: prefix.level,
      title: 'Every request starts heavy',
      detail: `${prefix.message} It is re-sent on every turn of every session in this project.`,
      sessionId: newest.sessionId,
      at: newest.lastActivityAt,
      action: { kind: 'open-inspector', label: 'Open the inspector', target: newest.transcriptPath },
    })
  }

  return alerts
}

/**
 * A session that asked a question and never got an answer.
 *
 * Needs a live status, so it can only fire for sessions currently open in the
 * app — history has no such state, and inventing one from a transcript's last
 * timestamp would flag every session that ever ended.
 */
export function blockedAlerts(input: AlertInput): Alert[] {
  const alerts: Alert[] = []
  for (const session of input.sessions) {
    if (session.status !== 'input') continue
    const since = session.statusSince ?? session.lastActivityAt
    if (!since || since <= 0) continue
    const waited = input.now - since
    if (waited < BLOCKED_WARNING_MS) continue

    alerts.push({
      id: `session-blocked:${session.sessionId}`,
      kind: 'session-blocked',
      severity: waited >= BLOCKED_CRITICAL_MS ? 'critical' : 'warning',
      title: `Waiting on you for ${formatDuration(waited)}`,
      detail: `Session ${shortId(
        session.sessionId,
      )} asked a question ${formatDuration(waited)} ago and has done nothing since. Nothing is running and nothing is being spent — it is simply stopped until you answer.`,
      sessionId: session.sessionId,
      at: since,
      action: { kind: 'focus-session', label: 'Go to the session', target: session.sessionId },
    })
  }
  return alerts
}

/**
 * A provider this project uses that is not installed.
 *
 * Gated on `providersInUse` rather than on the whole `PROVIDERS` table: a
 * machine without the Gemini CLI is not a problem until something here asks for
 * Gemini. `shell` is skipped — it is always present by construction.
 */
export function providerAlerts(input: AlertInput): Alert[] {
  const alerts: Alert[] = []
  const seen = new Set<ProviderId>()
  for (const provider of input.providersInUse) {
    if (provider === 'shell' || seen.has(provider)) continue
    seen.add(provider)
    if (input.providersInstalled[provider] !== false) continue

    const spec = PROVIDERS[provider]
    // `providersInUse` can carry a project's *saved* default, which is a string
    // in a JSON file — whatever a hand-edit or an older build of the app left
    // behind. Today an unrecognised id is caught one line above, because the
    // installed map is only ever built from `PROVIDERS`' own keys and so never
    // reports `false` for an id outside it. That is a coincidence of the
    // current wiring, and the failure if it stops holding is out of all
    // proportion: an undefined `spec.label` throws out of a *pure* function,
    // through `deriveAlerts`, and the panel shows an error instead of the
    // alerts it had already worked out.
    if (!spec) continue

    alerts.push({
      id: `provider-missing:${provider}`,
      kind: 'provider-missing',
      severity: 'critical',
      title: `${spec.label} is not installed`,
      // Both halves earn their place: the binary name is what somebody types to
      // check, and "sessions will fail" is why this is critical rather than
      // informational. What went was "This project is set up to run X, but" —
      // the title says that already.
      detail: `\`${spec.bin}\` is not on the login shell's PATH, so sessions started with it fail immediately.`,
      at: input.now,
      action: { kind: 'install-provider', label: `Set up ${spec.label}`, target: provider },
    })
  }
  return alerts
}

/**
 * A session that moved far more tokens than this project's usual.
 *
 * Median rather than mean, because one runaway session drags a mean up far
 * enough to hide the next one. Requires a real sample and an absolute floor —
 * see `HEAVY_MIN_TOKENS` for why a ratio alone is not enough.
 */
export function heavySessionAlerts(input: AlertInput): Alert[] {
  const counted = activeSessions(input.sessions).filter((session) => session.tokens > 0)
  if (counted.length < HEAVY_MIN_SAMPLE) return []

  const middle = median(counted.map((session) => session.tokens))
  if (middle <= 0) return []

  const alerts: Alert[] = []
  // Only the worst offender: a project that changed shape produces a dozen of
  // these at once, and a dozen alerts saying the same thing is noise.
  const worst = [...counted].sort((a, b) => b.tokens - a.tokens)[0]
  const ratio = worst.tokens / middle
  if (ratio < HEAVY_MULTIPLE || worst.tokens < HEAVY_MIN_TOKENS) return alerts

  alerts.push({
    id: `heavy-session:${worst.sessionId}`,
    kind: 'heavy-session',
    severity:
      ratio >= HEAVY_SEVERE_MULTIPLE && worst.tokens >= HEAVY_MIN_TOKENS * 5 ? 'warning' : 'info',
    title: `One session used ${ratio.toFixed(1)}x the usual tokens`,
    detail: `Session ${shortId(worst.sessionId)} moved ${formatTokens(
      worst.tokens,
    )} tokens against a median of ${formatTokens(
      middle,
    )} across ${counted.length} sessions here. Worth a look at what it spent them on — usually a context that was never compacted, or a tool loop.`,
    sessionId: worst.sessionId,
    at: worst.lastActivityAt,
    action: { kind: 'open-inspector', label: 'See where it went', target: worst.transcriptPath },
  })
  return alerts
}

/**
 * A session that is spending money without getting anywhere.
 *
 * The judgement is not made here. `deck-control/progress.ts` owns it — the
 * window, the thresholds, the four signals and the rule that repetition alone
 * is not a loop unless nothing is being written — and this rule does nothing
 * but decide whether the verdict it already reached is worth interrupting
 * somebody about. That split is deliberate and it is the reason this file
 * imports across into `deck-control/`, which is otherwise the wrong direction:
 * the alternative was a second copy of the same thresholds, and the copilot
 * saying "this looks stuck" while the alerts panel said nothing is precisely
 * the disagreement `COPILOT-DESIGN.md` argues the whole feature exists to
 * avoid.
 *
 * Only `looping` fires. `suspect` is repetition with files still landing, which
 * is what a refactor looks like from the outside, and alerting on it would put
 * a warning on ordinary work — the failure mode this module's header calls the
 * one it lives or dies by.
 */
export function loopAlerts(input: AlertInput): Alert[] {
  const alerts: Alert[] = []
  for (const session of input.sessions) {
    const progress = session.progress
    if (progress === undefined || progress.verdict !== 'looping') continue

    /*
     * Severity comes from the count the finding fired on, against
     * `progress.ts`'s own two thresholds — ten repeats is worth a line, twenty
     * is "it is nearly all this session is doing". Reading the number off the
     * finding rather than re-deriving it here is what keeps one set of
     * thresholds in the product: if somebody retunes `REPEAT_CRITICAL`, this
     * moves with it.
     */
    const worst = progress.findings.reduce<number>(
      (top, finding) => (finding.count === null ? top : Math.max(top, finding.count)),
      0,
    )
    const severity: AlertSeverity = worst >= REPEAT_CRITICAL ? 'critical' : 'warning'

    const tool = progress.findings.find((finding) => finding.tool !== null)?.tool ?? null
    /*
     * Its own sentence, not a clause.
     *
     * Every `ProgressFinding.detail` already ends in a full stop, so appending
     * " over the last 6 minutes" produced "…in the last 26 tool calls. over the
     * last 6 minutes." — which is what the real alert said on this machine
     * before somebody read one. A joined list of finished sentences can only be
     * extended with another finished sentence.
     */
    const forHow =
      progress.spanMs === null || progress.spanMs <= 0
        ? ''
        : ` It has been doing that for ${formatDuration(progress.spanMs)}.`

    alerts.push({
      id: `loop:${session.sessionId}`,
      kind: 'loop',
      severity,
      title:
        tool === null
          ? 'A session is repeating itself and writing nothing'
          : `A session is stuck on ${tool}`,
      /*
       * The findings, joined, and then the honest qualifier.
       *
       * `progressSentence` is not used even though it exists, because it opens
       * with "Looks stuck." and this alert's title has already said that. What
       * is wanted here is the evidence underneath it — the counts a person can
       * act on in one glance — which is what `COPILOT-CAPABILITIES.md` §2.3
       * means by preferring "Bash 14 times, 11 of them failing, nothing
       * written" over "looks stuck".
       */
      detail: `${progress.findings.map((finding) => finding.detail).join(' ')}${forHow} This is read from tool names and outcomes only, so it is a strong hint rather than proof — open it before stopping it.`,
      ...(session.appSessionId === undefined ? {} : { sessionId: session.appSessionId }),
      at: session.lastActivityAt,
      action: { kind: 'open-inspector', label: 'See what it is doing', target: session.transcriptPath },
    })
  }
  /*
   * Worst first, then at most one.
   *
   * Two agents looping in one folder is real, and reporting both would still be
   * right — but the panel groups by severity and the routine that hangs off
   * this trigger starts a copilot turn per *new* alert id. One line about the
   * worst one, with the second reachable through the tool, is the same call
   * `heavySessionAlerts` makes two rules above and for the same reason.
   */
  alerts.sort((a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity] || b.at - a.at)
  return alerts.slice(0, 1)
}

/**
 * Uncommitted work that several sessions have now been built on top of.
 *
 * "Across many sessions" is measured against the tree itself: count the
 * sessions that *started* after the newest uncommitted change. That is real,
 * derivable evidence — no counter to persist, and it resets by itself the
 * moment anything is committed or the files are touched again.
 */
export function dirtyTreeAlerts(input: AlertInput): Alert[] {
  const git = input.git
  if (!git || !git.repo || !git.dirty) return []
  if (git.changedFiles < DIRTY_TREE_MIN_FILES) return []
  if (git.lastChangeAt === null || git.lastChangeAt <= 0) return []

  const since = activeSessions(input.sessions).filter(
    (session) => session.startedAt > (git.lastChangeAt ?? 0),
  ).length
  if (since < DIRTY_TREE_SESSION_STREAK) return []

  return [
    {
      id: 'dirty-tree',
      kind: 'dirty-tree',
      severity: since >= DIRTY_TREE_CRITICAL_STREAK ? 'warning' : 'info',
      title: `${git.changedFiles} file${git.changedFiles === 1 ? '' : 's'} uncommitted across ${since} sessions`,
      // Shortened but not softened: the risk here is that there is no clean
      // state to return to, and an alert that dropped that would be advice
      // without a reason.
      detail: `Dirty since before the last ${since} sessions started — there is no clean state to roll back to. Commit or stash before the next one.`,
      at: git.lastChangeAt,
      action: { kind: 'open-git', label: 'Open the git panel', target: input.projectPath },
    },
  ]
}

/* -------------------------------------------------------------------------- */
/* The pure entry point                                                        */
/* -------------------------------------------------------------------------- */

const RULES: Array<(input: AlertInput) => Alert[]> = [
  contextAlerts,
  blockedAlerts,
  providerAlerts,
  loopAlerts,
  heavySessionAlerts,
  dirtyTreeAlerts,
]

/**
 * Every alert a project currently warrants, worst first.
 *
 * Pure: give it the same input twice and it returns the same list. It gathers
 * nothing itself — see `collectAlertInput` for that half.
 */
export function deriveAlerts(input: AlertInput): AlertReport {
  const alerts: Alert[] = []
  for (const rule of RULES) alerts.push(...rule(input))

  alerts.sort(
    (a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity] || b.at - a.at,
  )

  const counts: Record<AlertSeverity, number> = { critical: 0, warning: 0, info: 0 }
  for (const alert of alerts) counts[alert.severity] += 1

  return {
    projectPath: input.projectPath,
    alerts,
    counts,
    worst: alerts[0]?.severity ?? null,
    scannedAt: input.now,
  }
}

/** Alerts grouped for a panel that renders one section per severity. */
export function groupBySeverity(alerts: Alert[]): Array<{ severity: AlertSeverity; alerts: Alert[] }> {
  const order: AlertSeverity[] = ['critical', 'warning', 'info']
  return order
    .map((severity) => ({ severity, alerts: alerts.filter((alert) => alert.severity === severity) }))
    .filter((group) => group.alerts.length > 0)
}

/* -------------------------------------------------------------------------- */
/* Gathering                                                                   */
/* -------------------------------------------------------------------------- */

/** Live session state the app already holds. Supplied by the caller — see `registerAlertsIpc`. */
export interface LiveSession {
  sessionId: string
  cwd: string
  status: SessionStatus
  /** Epoch ms the status last changed. */
  statusSince?: number
  provider?: ProviderId
}

export interface AlertsOptions {
  /**
   * Open sessions, so a blocked one can be spotted. Wire this to the app's
   * session registry; without it the blocked rule simply never fires, which is
   * the correct behaviour for a process that cannot see any live session.
   */
  liveSessions?: (projectPath: string) => LiveSession[]
  /** The project's saved default provider, if it has one. */
  defaultProvider?: (projectPath: string) => ProviderId | undefined
  /** Injectable for tests. */
  now?: () => number
  /**
   * Claude config root to read transcripts from. Defaults to the live one.
   *
   * Present so a profile's isolated config dir can be honoured — `profiles.ts`
   * gives each profile its own — and so the gathering layer is testable without
   * writing into the developer's real `~/.claude`.
   */
  configDir?: string
  /**
   * Where confined sessions' per-device homes live. Defaults to whatever the
   * host core installed; `null` asks about the profile's store alone.
   *
   * A session started from a paired device runs with a home of its own, so its
   * transcript is not under `configDir` at all — and a blocked session nobody
   * can see is exactly the thing alerts exist to surface. Overridable for the
   * same reason `configDir` is: so the tests can point it at a scratch directory
   * instead of the developer's real one.
   */
  deviceHomes?: string | null
  /**
   * Every report this channel produces, as it produces it.
   *
   * There is no push side to alerts and there deliberately still is not: the
   * panel asks, and this module answers. What this hook adds is a way for the
   * main process to *overhear* an answer somebody already asked for, which is
   * what the routine engine's `alert` trigger subscribes to. It is not a
   * scanner and it does not cause a scan — a machine where nothing ever asks
   * for alerts produces no reports and therefore fires no alert routines, and
   * the engine reports that state rather than looking quietly idle.
   *
   * Called after the report is built and before it is returned, so a routine
   * reacting to an alert cannot be beaten to it by the window rendering it.
   * Defensive, because an observer that throws must not turn the panel's answer
   * into an error.
   */
  onReport?(report: AlertReport): void
}

/**
 * Files stat-ed while looking for the newest uncommitted change.
 *
 * The rule only needs the maximum mtime, and a serial `stat` per dirty path was
 * unbounded work on the main process repeated on every 60-second refresh: a
 * monorepo mid-rebase, or a merge that touched a generated directory, hands
 * back thousands of paths. Capping loses precision only when more than this
 * many files are dirty, and by then the alert fires on any of them.
 */
export const MAX_DIRTY_STATS = 400

/** `stat` calls issued at once. Enough to hide latency, not enough to exhaust fds. */
const STAT_BATCH = 32

/**
 * Newest mtime among the uncommitted files.
 *
 * Files are stat-ed rather than trusting git's index timestamps because a file
 * edited and reverted still shows in `git status` with an old mtime, and the
 * dirty-tree rule is about how long the work has been sitting there.
 */
async function newestChangeAt(root: string, paths: string[]): Promise<number | null> {
  let newest = 0
  const capped = paths.slice(0, MAX_DIRTY_STATS)
  for (let i = 0; i < capped.length; i += STAT_BATCH) {
    const batch = capped.slice(i, i + STAT_BATCH)
    const times = await Promise.all(
      batch.map(async (relative) => {
        // git reports repo-relative paths, but a caller could hand back anything.
        const full = isAbsolute(relative) ? relative : join(root, relative)
        try {
          return (await stat(full)).mtimeMs
        } catch {
          // Deleted files are dirty too and have no mtime — skip, do not fail.
          return 0
        }
      }),
    )
    for (const time of times) if (time > newest) newest = time
  }
  return newest > 0 ? newest : null
}

/**
 * Resolve `work`, or fall back once `ms` has passed.
 *
 * The gathering layer shells out through `detectProviders`, and its `which`
 * probe carries no timeout of its own. A wedged login shell would leave this
 * function's promise unsettled forever, which the panel renders as "Checking…"
 * with the re-scan button disabled — an alerts panel that has quietly stopped
 * being an alerts panel, with nothing on screen to say so.
 */
async function withTimeout<T>(work: Promise<T>, ms: number, fallback: T): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      work,
      new Promise<T>((resolve) => {
        timer = setTimeout(() => resolve(fallback), ms)
      }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/** Ceiling on each external probe the gathering layer waits for. */
export const GATHER_TIMEOUT_MS = 15_000

function toAlertGit(status: GitStatusResult, lastChangeAt: number | null): AlertGit {
  if (!status.repo) return { repo: false, dirty: false, changedFiles: 0, lastChangeAt: null }
  const changedFiles =
    status.staged.length + status.unstaged.length + status.untracked.length + status.conflicted.length
  return { repo: true, dirty: !status.clean, changedFiles, lastChangeAt }
}

/**
 * Go and fetch everything `deriveAlerts` needs.
 *
 * Bounded the same way the cost watcher is — reading every transcript a project
 * ever produced is unbounded work on the main process, and some of these
 * directories hold hundreds of megabytes.
 */
export async function collectAlertInput(
  projectPath: string,
  options: AlertsOptions = {},
): Promise<AlertInput> {
  const now = options.now?.() ?? Date.now()
  const root = resolve(projectPath)

  const cutoff = now - DEFAULT_MAX_AGE_MS
  // Every store this project's conversations can be in — the profile's, and one
  // per device that has run a confined session here. Merged and then capped, so
  // "the forty most recent" stays an answer about the project rather than forty
  // per directory.
  const scope: TranscriptScope = {
    ...(options.configDir === undefined ? {} : { configDir: options.configDir }),
    ...(options.deviceHomes === undefined ? {} : { deviceHomes: options.deviceHomes }),
  }
  const files = (await Promise.all(transcriptDirs(root, scope).map((dir) => listTranscripts(dir))))
    .flat()
    .sort((a, b) => b.modifiedAt - a.modifiedAt)
    .filter((file) => file.modifiedAt >= cutoff)
    .slice(0, DEFAULT_MAX_SESSIONS)

  const live = options.liveSessions?.(root) ?? []

  const sessions: AlertSession[] = []
  for (const file of files) {
    // One transcript that cannot be read must not cost the project its alerts.
    // A permission-denied file under `~/.claude/projects` — or one deleted
    // between the listing and the read — used to reject the whole scan with a
    // raw EACCES, and the panel showed that instead of the blocked session it
    // had every other input for.
    let summary
    try {
      summary = await readTranscript(file.path)
    } catch {
      continue
    }
    sessions.push({
      sessionId: summary.sessionId,
      transcriptPath: summary.transcriptPath,
      context: summary.context,
      preContextTokens: summary.preContextTokens,
      requests: summary.requests,
      tokens: totalTokens(summary.usage),
      startedAt: summary.startedAt,
      lastActivityAt: summary.lastActivityAt,
      // Never a live status: see the loop below for why the two cannot be joined.
      status: null,
    })
  }

  /*
   * Live sessions are appended, never merged into the transcripts above.
   *
   * It is tempting to attach a live status to the transcript it belongs to, and
   * it cannot be done by id: `PtyManager` names a session with its own
   * `randomUUID()`, while a transcript is named with the id *Claude Code*
   * generated inside that process. They are different namespaces, so a join on
   * `sessionId` matches nothing and the blocked rule would silently never fire —
   * the failure mode being that the panel looks fine and simply never warns.
   *
   * Kept apart, each carries what it actually knows: transcripts carry tokens
   * and context, live sessions carry status. `requests: 0` keeps these entries out
   * of every rule except the blocked one, which is the only rule that wants them.
   */
  for (const session of live) {
    sessions.push({
      sessionId: session.sessionId,
      transcriptPath: '',
      context: null,
      preContextTokens: 0,
      requests: 0,
      tokens: 0,
      startedAt: session.statusSince ?? now,
      lastActivityAt: session.statusSince ?? now,
      status: session.status,
      statusSince: session.statusSince,
      provider: session.provider,
    })
  }

  await attachProgress(sessions, live, now)

  const providersInUse: ProviderId[] = []
  for (const session of live) {
    if (session.provider && !providersInUse.includes(session.provider)) {
      providersInUse.push(session.provider)
    }
  }
  const preferred = options.defaultProvider?.(root)
  if (preferred && !providersInUse.includes(preferred)) providersInUse.push(preferred)

  const noProviders: Partial<Record<ProviderId, boolean>> = {}
  const noGit: GitStatusResult = { repo: false, cwd: root, reason: 'error', message: 'git failed' }
  const [installed, gitStatus] = await Promise.all([
    // An empty map reads as "we could not look", which `providerAlerts` treats
    // as silence rather than as "nothing is installed".
    withTimeout(detectProviders().catch(() => noProviders), GATHER_TIMEOUT_MS, noProviders),
    withTimeout(readGitStatus(root).catch(() => noGit), GATHER_TIMEOUT_MS, noGit),
  ])

  const dirtyPaths = gitStatus.repo
    ? [...gitStatus.staged, ...gitStatus.unstaged, ...gitStatus.untracked, ...gitStatus.conflicted].map(
        (file) => file.path,
      )
    : []
  const lastChangeAt = gitStatus.repo ? await newestChangeAt(gitStatus.root, dirtyPaths) : null

  return {
    projectPath: root,
    now,
    sessions,
    providersInUse,
    providersInstalled: installed,
    git: toAlertGit(gitStatus, lastChangeAt),
  }
}

/**
 * Read the tool trail of the few transcripts a live loop could be in, and hang
 * the verdict on them.
 *
 * Three gates before a single byte is read, in this order, because each one is
 * cheaper than the next and each removes most of what the next would look at:
 *
 *  1. **No live session in this folder, no read at all.** A loop alert is about
 *     an agent burning wall-clock right now. A transcript with no process
 *     behind it is history — still readable through `sessions.result` when
 *     somebody asks, never worth an interruption.
 *  2. **Only transcripts that moved inside {@link LOOP_ACTIVE_WITHIN_MS}**, and
 *     only ones with requests on them, which is the same `activeSessions` rule
 *     every other quantitative rule here obeys.
 *  3. **At most {@link LOOP_MAX_TRAILS}**, newest first.
 *
 * In the ordinary case — a project open in the sidebar with nothing running in
 * it — that is zero extra reads, which is what makes this affordable on a scan
 * the panel drives from a timer.
 *
 * Mutates the entries in place rather than returning a new list. The array was
 * built four lines above by its only caller and the transcript entries are
 * already the objects the rules read; rebuilding it to attach one optional
 * field would be a copy whose only purpose is to look functional.
 */
async function attachProgress(
  sessions: AlertSession[],
  live: readonly LiveSession[],
  now: number,
): Promise<void> {
  if (live.length === 0) return

  const candidates = sessions
    .filter(
      (session) =>
        session.transcriptPath !== '' &&
        session.requests > 0 &&
        session.lastActivityAt >= now - LOOP_ACTIVE_WITHIN_MS,
    )
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt)
    .slice(0, LOOP_MAX_TRAILS)

  /*
   * One live session in the folder means the conversation is that session's.
   *
   * With two or more it genuinely cannot be told from here — the ids are in
   * different namespaces, and this scan does not hold the session start times
   * that `deck-control/transcript-match.ts` uses to do better. So the alert
   * keeps its transcript pointer and drops the session link rather than
   * guessing, and the sentence a person reads names the file instead of a tab.
   */
  const only = live.length === 1 ? live[0].sessionId : undefined

  await Promise.all(
    candidates.map(async (session) => {
      const trail = await readToolTrail(session.transcriptPath, TRAIL_WINDOW_BYTES)
      session.progress = assessProgress(trail)
      if (only !== undefined) session.appSessionId = only
    }),
  )
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

function projectPathOf(value: unknown): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error('alerts: a project path is required')
  }
  return resolve(value)
}

/**
 * Register the alerts channel.
 *
 *  - `alerts:project` (projectPath) -> AlertReport
 *
 * Pass `liveSessions` from the app's session registry so a blocked session can
 * be detected; everything else is read from disk.
 */
export function registerAlertsIpc(ipcMain: IpcMain, options: AlertsOptions = {}): void {
  /*
   * One scan per project at a time, shared by every caller waiting on it.
   *
   * A scan reads up to `DEFAULT_MAX_SESSIONS` transcripts and shells out to
   * git, and the panel drives it from a 60-second interval, from every mount,
   * and from a button. Two windows on the same project, or a refresh that
   * outlasts its interval, otherwise stack full scans on the main process — all
   * of them reading the same files to reach the same answer.
   */
  const inFlight = new Map<string, Promise<AlertReport>>()

  ipcMain.handle(
    ALERTS_CHANNEL,
    async (_event: IpcMainInvokeEvent, projectPath: string): Promise<AlertReport> => {
      const root = projectPathOf(projectPath)
      const running = inFlight.get(root)
      if (running) return running

      const scan = collectAlertInput(root, options)
        .then(deriveAlerts)
        .then((report) => {
          try {
            options.onReport?.(report)
          } catch (error) {
            console.error('[alerts] a report observer threw:', error)
          }
          return report
        })
        .finally(() => {
          inFlight.delete(root)
        })
      inFlight.set(root, scan)
      return scan
    },
  )
}
