/**
 * Claude subscription plan limits, read out of the session's own terminal.
 *
 * There is no local file and no CLI flag that reports how much of a plan's
 * rolling limit is left. Checked on this machine against Claude Code 2.1.228:
 *
 *  - `claude --help` has no usage/limit command; the only commands are agents,
 *    auth, auto-mode, doctor, gateway, import, install, mcp, plugin, project,
 *    setup-token, ultrareview and update.
 *  - `~/.claude.json` caches an account, an org and a rate-limit *tier name*,
 *    but no utilisation and no reset time. `~/.claude/` holds no usage cache
 *    either — grepped for `resets_at`, `utilization`, `five_hour`.
 *  - The CLI itself fetches the numbers at runtime (`GET /api/oauth/usage`) and
 *    from `anthropic-ratelimit-unified-*` response headers, then draws them.
 *
 * So the only honest local source is what Claude Code puts on screen, which it
 * does in two shapes. Both were captured from a real PTY here rather than
 * guessed:
 *
 *     Current session
 *     ██▌                                                5% used
 *     Resets 4am (Asia/Dubai)
 *
 *     Current week (all models)
 *     ████████████████████████████████████████           80% used
 *     Resets Aug 14 at 2pm (Asia/Dubai)
 *
 * — the `/usage` panel, and one-line warnings like "You've used 85% of your
 * weekly limit · resets …" that appear near the prompt only once a limit is
 * close. Nothing is printed while usage is low, which is why "not available" is
 * a normal state here and is reported as such rather than estimated.
 *
 * Reading the *screen* rather than the byte stream is not optional: the same
 * capture shows the stream carrying `██████████10% used` and `Resets4am` as the
 * TUI repaints, with the spacing that separates a bar from its number existing
 * only on screen. This module therefore feeds a headless terminal, exactly as
 * `session-activity.ts` does for status, and parses its viewport.
 */

import { Terminal } from '@xterm/headless'
import type { IpcMain, IpcMainInvokeEvent, WebContents } from 'electron'
import { stripAnsi } from './session-activity'
import { onWebContentsDestroyed } from './web-contents-teardown'
import {
  fractionFromPercent,
  readingId,
  resetDescribed,
  type UsageAccountRef,
  type UsageWindowKind,
  type UsageWindowReading,
} from './usage-window'

/* -------------------------------------------------------------------------- */
/* Types                                                                       */
/* -------------------------------------------------------------------------- */

/** Which rolling window a limit belongs to. `other` covers usage credits. */
export type PlanLimitScope = 'session' | 'week' | 'other'

export interface PlanLimit {
  /** Stable key — `session`, `week`, `week:opus`, `other:usage-credit`. */
  id: string
  /** Exactly what the CLI called it. Never re-worded here. */
  label: string
  scope: PlanLimitScope
  /**
   * Percent of the limit consumed, or null when the CLI named the limit without
   * a number ("Approaching weekly limit"). Null is never rendered as 0.
   */
  percent: number | null
  /** Verbatim reset text, e.g. `Aug 14 at 2pm (Asia/Dubai)`. */
  resetsAt: string | null
}

export type PlanLimitSource = 'usage-panel' | 'warning'

export interface PlanLimitSnapshot {
  sessionId: string
  /** False means: nothing has been seen. The UI must say so, not guess. */
  available: boolean
  limits: PlanLimit[]
  source: PlanLimitSource | null
  /** The CLI's own warning sentence, when that is where the reading came from. */
  message: string | null
  /** When the reading was taken off the screen. Plan limits go stale. */
  capturedAt: number
  /**
   * When these exact numbers first appeared on the screen.
   *
   * `capturedAt` is re-stamped every time the viewport is read, which is right
   * for "when did this app last look" and wrong for "how old is this number".
   * A `/usage` panel sits on screen until it is dismissed, so re-reading it an
   * hour later would otherwise report an hour-old figure as one second old —
   * and the whole reason this feature was not built on `~/.claude.json` is that
   * a stale figure presented as current is worse than no figure.
   *
   * So this holds the *earliest* moment the current text was seen, and it only
   * moves when the text does. It errs old: a panel that Claude Code redrew with
   * unchanged numbers keeps the earlier time, because the screen cannot tell a
   * redraw from a leftover. Under-claiming freshness costs a slightly dimmer
   * bar; over-claiming it is the bug.
   */
  firstSeenAt: number
  /** One sentence explaining an unavailable reading. */
  reason: string | null
}

export function emptySnapshot(sessionId: string, reason: string): PlanLimitSnapshot {
  return {
    sessionId,
    available: false,
    limits: [],
    source: null,
    message: null,
    capturedAt: 0,
    firstSeenAt: 0,
    reason,
  }
}

/* -------------------------------------------------------------------------- */
/* Parsing                                                                     */
/* -------------------------------------------------------------------------- */

/** `Current session` / `Current week (all models)` / `Current week (Fable)`. */
const PANEL_HEADING = /^Current\s+(session|week)\b(?:\s*\(([^)]*)\))?\s*$/i
/** The bar and its number share a line: `██▌   5% used`. */
const PERCENT_USED = /(\d{1,3})%\s+used\b/i
const RESETS_LINE = /^Resets\b\s*(.*)$/i

/** "You've used 85% of your weekly limit · resets Aug 14 at 2pm". */
const WARN_USED = /you['’]ve used\s+(\d{1,3})%\s+of your\s+(.+)$/i
/** "Your weekly limit resets Aug 14 at 2pm". */
const WARN_RESETS = /^\W*your\s+(.+?)\s+resets\s+(.+)$/i
/** "Approaching weekly limit" / "You're close to your weekly limit" / "You've hit your weekly limit". */
const WARN_NAMED = /(?:approaching|you['’]re close to your|you['’]ve hit your)\s+(.+)$/i

/** How far below a heading the bar and the reset line are allowed to sit. */
const LOOKAHEAD_LINES = 4

/**
 * Map a label the CLI printed onto a stable key.
 *
 * The CLI names the same limit two ways — `Current week (all models)` in the
 * panel, `weekly limit` in a warning — and both have to land on one key or a
 * panel reading and a warning reading would render as two different limits.
 */
export function identifyLimit(label: string): { id: string; scope: PlanLimitScope } {
  const text = label.toLowerCase()
  const isWeek = /week/.test(text)
  const isSession = /session|5[- ]hour|five[- ]hour/.test(text)

  // Model-scoped weekly limits: "Current week (Opus)", "Opus limit".
  const model = /\b(opus|sonnet|haiku|fable|mythos)\b/.exec(text)?.[1]
  if (model && (isWeek || /limit/.test(text))) return { id: `week:${model}`, scope: 'week' }
  if (isWeek) return { id: 'week', scope: 'week' }
  if (isSession) return { id: 'session', scope: 'session' }
  if (/credit/.test(text)) return { id: 'other:usage-credit', scope: 'other' }
  return { id: `other:${slug(text)}`, scope: 'other' }
}

/**
 * Guard against reading a plan limit out of ordinary agent output.
 *
 * The screen this parses is a *terminal*: an agent that writes "you've hit your
 * retry limit" would otherwise be quoted back as a subscription reading. A
 * genuine one always names both the window and the word "limit".
 */
const LIMIT_SCOPE_WORD = /\b(session|weekly|week|5-hour|five-hour|opus|sonnet|haiku|fable|mythos|credits?)\b/i

export function isLimitLabel(label: string): boolean {
  return /\blimits?\b/i.test(label) && LIMIT_SCOPE_WORD.test(label)
}

function slug(text: string): string {
  return text.replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '').toLowerCase() || 'limit'
}

function percentOf(raw: string): number | null {
  const value = Number(raw)
  // Over 100 is real — a limit can be exhausted — but a four-digit number is a
  // mis-parse, and rendering it would be worse than reporting nothing.
  return Number.isFinite(value) && value >= 0 && value <= 999 ? value : null
}

function tidy(text: string): string {
  return text.replace(/[·•,;:\s]+$/g, '').trim()
}

/**
 * Limits visible on one screen, or null when the screen shows none.
 *
 * Null and an empty list are the same thing to a caller, but the distinction
 * matters upstream: a screen with no limits on it is *not* evidence that the
 * limits changed, so it must never overwrite an earlier reading.
 */
export function parsePlanLimits(
  screen: string,
): { limits: PlanLimit[]; source: PlanLimitSource; message: string | null } | null {
  const lines = stripAnsi(screen).split('\n').map((line) => line.trimEnd())

  const panel = parseUsagePanel(lines)
  if (panel.length > 0) return { limits: panel, source: 'usage-panel', message: null }

  const warning = parseWarning(lines)
  return warning
}

function parseUsagePanel(lines: string[]): PlanLimit[] {
  const limits: PlanLimit[] = []
  const seen = new Set<string>()

  for (let i = 0; i < lines.length; i += 1) {
    const heading = PANEL_HEADING.exec(lines[i].trim())
    if (!heading) continue

    // "Current week (all models)" is the unscoped weekly limit; anything else
    // in the parentheses names a model. The label keeps the CLI's own words.
    const qualifier = heading[2]?.trim() ?? ''
    const label = qualifier ? `Current ${heading[1]} (${qualifier})` : `Current ${heading[1]}`
    const key =
      qualifier && !/^all models$/i.test(qualifier)
        ? identifyLimit(`${heading[1]} ${qualifier}`)
        : identifyLimit(heading[1])

    let percent: number | null = null
    let resetsAt: string | null = null
    let cursor = i + 1
    for (; cursor <= i + LOOKAHEAD_LINES && cursor < lines.length; cursor += 1) {
      const found = PERCENT_USED.exec(lines[cursor])
      if (found) {
        percent = percentOf(found[1])
        break
      }
      // Another heading before the number: this block has no bar of its own.
      if (PANEL_HEADING.test(lines[cursor].trim())) break
    }
    if (percent === null) continue

    for (let j = cursor + 1; j <= cursor + LOOKAHEAD_LINES && j < lines.length; j += 1) {
      const reset = RESETS_LINE.exec(lines[j].trim())
      if (reset) {
        resetsAt = tidy(reset[1]) || null
        break
      }
      if (PANEL_HEADING.test(lines[j].trim())) break
    }

    if (seen.has(key.id)) continue
    seen.add(key.id)
    limits.push({ id: key.id, label, scope: key.scope, percent, resetsAt })
  }

  return limits
}

function parseWarning(
  lines: string[],
): { limits: PlanLimit[]; source: PlanLimitSource; message: string | null } | null {
  // Newest first: the prompt area redraws, so a later line is the current state.
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i].trim()
    if (line.length === 0) continue

    const used = WARN_USED.exec(line)
    if (used) {
      const rest = used[2]
      const cut = /\bresets\b/i.exec(rest)
      const label = tidy(cut ? rest.slice(0, cut.index) : rest)
      const resetsAt = cut ? tidy(rest.slice(cut.index + cut[0].length)) || null : null
      if (isLimitLabel(label)) {
        return {
          limits: [{ ...identifyLimit(label), label, percent: percentOf(used[1]), resetsAt }],
          source: 'warning',
          message: line,
        }
      }
    }

    const resets = WARN_RESETS.exec(line)
    if (resets && isLimitLabel(resets[1])) {
      const label = tidy(resets[1])
      return {
        limits: [{ ...identifyLimit(label), label, percent: null, resetsAt: tidy(resets[2]) || null }],
        source: 'warning',
        message: line,
      }
    }

    const named = WARN_NAMED.exec(line)
    if (named && isLimitLabel(named[1])) {
      const label = tidy(named[1])
      return {
        limits: [{ ...identifyLimit(label), label, percent: null, resetsAt: null }],
        source: 'warning',
        message: line,
      }
    }
  }
  return null
}

/* -------------------------------------------------------------------------- */
/* Translating into the shared usage vocabulary                                */
/* -------------------------------------------------------------------------- */

/**
 * Claude's own words for a window, mapped onto the period it actually is.
 *
 * "Current session" is the five-hour rolling window — the CLI names it after
 * the thing being limited rather than after its length, and the chrome draws
 * bars per period, so the two have to be reconciled somewhere. It is done here,
 * once, and the CLI's own label rides along untouched in `label` so nothing on
 * screen has to take this translation's word for it.
 */
function windowForScope(scope: PlanLimitScope): UsageWindowKind {
  if (scope === 'session') return 'five-hour'
  if (scope === 'week') return 'weekly'
  return 'other'
}

/**
 * One session's screen reading, in the shape every provider shares.
 *
 * The account is supplied rather than derived: this module watches a terminal
 * and knows nothing about which login the terminal was started under. See
 * `usage-ipc.ts`, which resolves it from the session's profile.
 *
 * An unavailable snapshot yields an empty list rather than a list of zeroes.
 * There is no reading to translate, and inventing one at 0% would be the
 * `~/.claude.json` mistake with a different source.
 */
export function planUsageReadings(
  snapshot: PlanLimitSnapshot,
  account: UsageAccountRef,
): UsageWindowReading[] {
  if (!snapshot.available || snapshot.source === null) return []
  const source = snapshot.source === 'usage-panel' ? 'claude-usage-panel' : 'claude-warning'
  return snapshot.limits.map((limit) => {
    const window = windowForScope(limit.scope)
    // `week:opus` and `other:usage-credit` carry a qualifier after the colon.
    // It has to survive into the id or a model-scoped weekly limit would
    // collide with the unscoped one and the second would be dropped.
    const qualifier = limit.id.includes(':') ? limit.id.slice(limit.id.indexOf(':') + 1) : ''
    return {
      id: readingId(account, window, qualifier),
      account,
      window,
      // Claude Code never states a window length — the panel says "Current
      // session", not "300 minutes" — so there is nothing truthful to put here.
      windowMinutes: null,
      label: limit.label,
      used: fractionFromPercent(limit.percent),
      // Words, not an instant: "Resets 4am (Asia/Dubai)" omits the date, the
      // year and the DST rule, and `usage-window.ts` explains why guessing them
      // would be worse than being unable to count down.
      resets: resetDescribed(limit.resetsAt),
      observedAt: snapshot.capturedAt,
      reportedAt: snapshot.firstSeenAt || snapshot.capturedAt,
      source,
    }
  })
}

/* -------------------------------------------------------------------------- */
/* Watching one session's screen                                               */
/* -------------------------------------------------------------------------- */

/** Output has to stop before the screen is worth reading — same reason as status. */
const SETTLE_MS = 600
const DEFAULT_COLS = 120
const DEFAULT_ROWS = 40
/**
 * Claude Code draws its prompt as `❯`, verified against real output.
 *
 * Not unique to it: pure, starship and spaceship draw a zsh prompt the same
 * way, so this says "the prompt box is empty", not "this is Claude Code". The
 * consequence of being wrong is bounded — `/usage` typed at a shell is an
 * unknown command — and the refusal wording says as much rather than insisting
 * there is text in a Claude Code prompt that may not exist.
 */
const EMPTY_PROMPT = /^\s*❯\s*$/m

/**
 * Mirrors one session's screen and reports the plan limits on it.
 *
 * Only sessions the UI is actually watching get one of these, so the cost is a
 * map lookup per output chunk for everything else.
 */
export class PlanLimitTracker {
  private term: Terminal
  private timer: NodeJS.Timeout | undefined
  private lastOutputAt = 0
  private snapshot: PlanLimitSnapshot

  constructor(
    readonly sessionId: string,
    private readonly onChange: (snapshot: PlanLimitSnapshot) => void,
    cols = DEFAULT_COLS,
    rows = DEFAULT_ROWS,
  ) {
    this.term = new Terminal({ cols, rows, allowProposedApi: true, scrollback: 100 })
    this.snapshot = emptySnapshot(sessionId, NOT_SEEN)
  }

  get current(): PlanLimitSnapshot {
    return this.snapshot
  }

  push(chunk: string): void {
    this.term.write(chunk)
    this.lastOutputAt = Date.now()
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      // Flush pending writes before reading, or the viewport lags the output.
      this.term.write('', () => this.capture())
    }, SETTLE_MS)
  }

  resize(cols: number, rows: number): void {
    try {
      this.term.resize(Math.max(cols, 1), Math.max(rows, 1))
    } catch {
      /* invalid dimensions during teardown */
    }
  }

  /** The visible viewport, as the user sees it. */
  screen(): string {
    const buffer = this.term.buffer.active
    const lines: string[] = []
    for (let y = 0; y < this.term.rows; y += 1) {
      const line = buffer.getLine(buffer.viewportY + y)
      if (line) lines.push(line.translateToString(true))
    }
    return lines.join('\n')
  }

  /**
   * Read the screen. Returns true when the stored snapshot changed.
   *
   * A screen with no limits on it leaves the last reading alone: the `/usage`
   * panel is closed most of the time, and treating its absence as "the limits
   * are unknown again" would make the strip flicker between a number and a
   * shrug every time the user pressed a key.
   */
  capture(at = Date.now(), confirmed = false): boolean {
    const parsed = parsePlanLimits(this.screen())
    if (!parsed) return false

    const same =
      this.snapshot.available &&
      this.snapshot.source === parsed.source &&
      this.snapshot.message === parsed.message &&
      JSON.stringify(this.snapshot.limits) === JSON.stringify(parsed.limits)
    // Re-stamp the time even when the numbers match: the reading really was
    // taken again, and staleness is shown to the user.
    this.snapshot = {
      sessionId: this.sessionId,
      available: true,
      limits: parsed.limits,
      source: parsed.source,
      message: parsed.message,
      capturedAt: at,
      // Identical text keeps its original age — see `firstSeenAt`. `confirmed`
      // is the one exception, and only `refresh` sets it: it has just typed
      // `/usage`, so whatever the CLI draws in response is a fresh answer even
      // when it matches the last one. The window in which that could mislabel a
      // pre-existing warning line is bounded by `REFRESH_TIMEOUT_MS`.
      firstSeenAt: same && !confirmed ? this.snapshot.firstSeenAt : at,
      reason: null,
    }
    if (!same) this.onChange(this.snapshot)
    return !same
  }

  /** True when nothing has been drawn for `ms` — the session is not mid-answer. */
  settled(ms: number, now = Date.now()): boolean {
    return this.lastOutputAt === 0 || now - this.lastOutputAt >= ms
  }

  /**
   * True when the prompt box is empty.
   *
   * The gate for typing anything into someone's session: with half-typed text
   * in the box, `/usage` would be appended to it and submitted as a prompt.
   */
  promptIsEmpty(): boolean {
    return EMPTY_PROMPT.test(stripAnsi(this.screen()))
  }

  dispose(): void {
    clearTimeout(this.timer)
    this.term.dispose()
  }
}

const NOT_SEEN =
  'Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run.'
const NOT_WATCHED = 'No live session is being watched for plan limits.'
const EVICTED =
  'Plan limits are tracked for the most recently watched sessions only, and this one was released to make room. Reopen it to read them again.'

/* -------------------------------------------------------------------------- */
/* Registry                                                                    */
/* -------------------------------------------------------------------------- */

/** Channel the renderer listens on for pushed readings. */
export const PLAN_LIMIT_CHANNEL = 'plan:update'

/** Ceiling on resident trackers; each holds a small headless terminal. */
const MAX_TRACKERS = 8

/** A listener inside this process, as opposed to a window across the bridge. */
export type PlanLimitListener = (snapshot: PlanLimitSnapshot) => void

interface Entry {
  tracker: PlanLimitTracker
  subscribers: Set<WebContents>
  /**
   * Subscribers in the main process itself.
   *
   * This reading used to be reachable only by whoever called `plan:watch` over
   * the bridge, which made it a property of the chat view rather than a
   * property of the session. `usage-ipc.ts` needs the same numbers to fold in
   * with Codex's, and the window chrome will need them for a session that has
   * no chat view at all, so the tracker now has an in-process audience as well.
   * Both audiences are fed by the same `broadcast`, so neither can be given a
   * reading the other did not get.
   */
  listeners: Set<PlanLimitListener>
  refreshing: boolean
}

const entries = new Map<string, Entry>()

/** True while anything at all is still interested in this session. */
function isWatched(entry: Entry): boolean {
  return entry.subscribers.size > 0 || entry.listeners.size > 0
}

function broadcast(entry: Entry, snapshot: PlanLimitSnapshot): void {
  for (const contents of entry.subscribers) {
    if (contents.isDestroyed()) {
      entry.subscribers.delete(contents)
      continue
    }
    try {
      contents.send(PLAN_LIMIT_CHANNEL, snapshot.sessionId, snapshot)
    } catch (err) {
      entry.subscribers.delete(contents)
      console.error('[plan-limit] dropping a dead subscriber:', err)
    }
  }
  for (const listener of [...entry.listeners]) {
    try {
      listener(snapshot)
    } catch (err) {
      // An in-process listener that throws must not cost a window its update.
      console.error('[plan-limit] a listener threw:', err)
    }
  }
}

/**
 * Release a tracker to make room, telling whoever was watching it.
 *
 * Dropping it silently leaves the strip showing a number nothing will ever
 * update again — the reading would sit there ageing while the session it
 * described carried on, which is the failure this whole module exists to avoid.
 */
function evict(sessionId: string): void {
  const entry = entries.get(sessionId)
  if (!entry) return
  broadcast(entry, emptySnapshot(sessionId, EVICTED))
  dropPlanSession(sessionId)
}

function ensureEntry(sessionId: string): Entry {
  const existing = entries.get(sessionId)
  if (existing) return existing

  if (entries.size >= MAX_TRACKERS) {
    const oldest = entries.keys().next().value
    if (typeof oldest === 'string') evict(oldest)
  }

  const entry: Entry = {
    tracker: new PlanLimitTracker(sessionId, (snapshot) => broadcast(entry, snapshot)),
    subscribers: new Set(),
    listeners: new Set(),
    refreshing: false,
  }
  entries.set(sessionId, entry)
  return entry
}

/**
 * Watch a session's plan readings from inside the main process.
 *
 * The same subscription `plan:watch` performs for a window, without a window.
 * Returns the reading held right now — which is an unavailable snapshot with a
 * reason when the CLI has not printed anything yet — and calls back on every
 * change until the returned function is invoked.
 *
 * Holding one of these keeps the tracker resident: a window closing its tab
 * must not tear down the reading that the chrome, or the usage aggregator, is
 * still watching.
 */
export function watchPlanSnapshots(
  sessionId: string,
  listener: PlanLimitListener,
): { snapshot: PlanLimitSnapshot; stop: () => void } {
  const entry = ensureEntry(sessionKey(sessionId))
  entry.listeners.add(listener)
  let stopped = false
  return {
    snapshot: entry.tracker.current,
    stop: () => {
      if (stopped) return
      stopped = true
      const current = entries.get(sessionId)
      if (!current) return
      current.listeners.delete(listener)
      if (!isWatched(current)) dropPlanSession(sessionId)
    },
  }
}

/**
 * The reading held for a session right now, without subscribing.
 *
 * An unwatched session has no tracker and therefore no reading — not an empty
 * one. The distinction is the point: `NOT_WATCHED` means "nobody is looking at
 * this session's screen", which a caller fixes by watching, and it is a
 * different sentence from "Claude Code has not printed anything".
 */
export function planSnapshot(sessionId: string): PlanLimitSnapshot {
  return entries.get(sessionId)?.tracker.current ?? emptySnapshot(sessionId, NOT_WATCHED)
}

/**
 * Feed a session's terminal output in. Call from wherever PTY data is already
 * fanned out; sessions nobody is watching cost one map lookup.
 */
export function notePlanOutput(sessionId: string, chunk: string): void {
  entries.get(sessionId)?.tracker.push(chunk)
}

/** Keep the shadow terminal the same shape as the real one, so nothing wraps differently. */
export function notePlanResize(sessionId: string, cols: number, rows: number): void {
  entries.get(sessionId)?.tracker.resize(cols, rows)
}

/** Forget a session — call when its process exits or its tab closes. */
export function dropPlanSession(sessionId: string): void {
  const entry = entries.get(sessionId)
  if (!entry) return
  entry.tracker.dispose()
  entries.delete(sessionId)
}

function releaseAll(contents: WebContents): void {
  for (const [sessionId, entry] of [...entries]) {
    entry.subscribers.delete(contents)
    // `isWatched`, not `subscribers.size`: a closing window must not take the
    // tracker away from an in-process listener that is still reading it.
    if (!isWatched(entry)) dropPlanSession(sessionId)
  }
}

function sessionKey(value: unknown): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error('plan-limit: a session id is required')
  }
  return value
}

export interface RefreshResult {
  ok: boolean
  /**
   * Why a refresh did not run. Reported rather than swallowed: a control that
   * appears to do nothing is worse than one that says why it did not.
   */
  reason: 'unwired' | 'not-watching' | 'busy' | 'prompt-busy' | 'no-panel' | null
  snapshot: PlanLimitSnapshot
}

const USAGE_COMMAND = '/usage\r'
/** Escape closes the panel — the same key a person presses to dismiss it. */
const CLOSE_PANEL = '\u001b'
/** The panel is a network fetch behind a redraw; this is generous on purpose. */
const REFRESH_TIMEOUT_MS = 8000
const POLL_MS = 250
/** How long the session must have been quiet before typing into it. */
const IDLE_BEFORE_TYPING_MS = 1000

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export interface PlanLimitOptions {
  /**
   * Writes to a session's PTY. Without it `plan:refresh` reports `unwired` and
   * the UI hides the control instead of offering a button that does nothing.
   */
  write?: (sessionId: string, data: string) => void
}

/**
 * Run `/usage` in a session and read the panel it draws.
 *
 * This types into the user's session, so it is only ever user-initiated, and
 * only when the session is quiet *and* its prompt box is empty — otherwise the
 * text would be appended to what they were typing and submitted as a prompt.
 * The panel is closed again with Escape, which is what a person does.
 *
 * The empty-prompt gate matches an idle `❯` prompt. That is Claude Code's, but
 * it is also what several zsh themes draw, so the gate proves the box is empty
 * rather than proving which program owns it; in a plain shell the worst case is
 * an unknown command, and nothing is submitted to an agent.
 */
async function refresh(sessionId: string, options: PlanLimitOptions): Promise<RefreshResult> {
  const entry = entries.get(sessionId)
  if (!entry) return { ok: false, reason: 'not-watching', snapshot: emptySnapshot(sessionId, NOT_WATCHED) }
  if (!options.write) return { ok: false, reason: 'unwired', snapshot: entry.tracker.current }
  if (entry.refreshing || !entry.tracker.settled(IDLE_BEFORE_TYPING_MS)) {
    return { ok: false, reason: 'busy', snapshot: entry.tracker.current }
  }
  if (!entry.tracker.promptIsEmpty()) {
    return { ok: false, reason: 'prompt-busy', snapshot: entry.tracker.current }
  }

  entry.refreshing = true
  const startedAt = Date.now()
  try {
    options.write(sessionId, USAGE_COMMAND)
    const deadline = startedAt + REFRESH_TIMEOUT_MS
    while (Date.now() < deadline) {
      await delay(POLL_MS)
      // Confirmed: `/usage` was just typed, so what comes back is a fresh
      // answer from the CLI even if it prints the same numbers as before.
      entry.tracker.capture(Date.now(), true)
      const snapshot = entry.tracker.current
      if (snapshot.source === 'usage-panel' && snapshot.capturedAt >= startedAt) {
        options.write(sessionId, CLOSE_PANEL)
        return { ok: true, reason: null, snapshot }
      }
    }
    options.write(sessionId, CLOSE_PANEL)
    return { ok: false, reason: 'no-panel', snapshot: entry.tracker.current }
  } finally {
    entry.refreshing = false
  }
}

/**
 * Register the plan-limit IPC handlers.
 *
 * Channels:
 *  - `plan:watch`   (invoke, sessionId) -> PlanLimitSnapshot   subscribe; pushes `plan:update`
 *  - `plan:refresh` (invoke, sessionId) -> RefreshResult       runs /usage in the session
 *  - `plan:unwatch` (send,   sessionId) -> void
 */
export function registerPlanLimitIpc(ipcMain: IpcMain, options: PlanLimitOptions = {}): void {
  ipcMain.handle('plan:watch', (event: IpcMainInvokeEvent, sessionId: string): PlanLimitSnapshot => {
    const entry = ensureEntry(sessionKey(sessionId))
    const contents = event.sender
    entry.subscribers.add(contents)
    // Registered per WebContents, not per entry. The guard here used to be
    // `if (!entry.subscribers.has(contents))`, which attaches one `destroyed`
    // listener for every *session* a window watches — eleven tabs, eleven
    // listeners on one emitter, and Node starts warning at ten. `releaseAll`
    // already drops this contents from every entry, so one is all it ever
    // needed. See `web-contents-teardown.ts`.
    onWebContentsDestroyed(contents, 'plan-limit', () => releaseAll(contents))
    return entry.tracker.current
  })

  ipcMain.handle(
    'plan:refresh',
    (_e: IpcMainInvokeEvent, sessionId: string): Promise<RefreshResult> =>
      refresh(sessionKey(sessionId), options),
  )

  ipcMain.on('plan:unwatch', (event, sessionId: unknown) => {
    if (typeof sessionId !== 'string' || sessionId.length === 0) return
    const entry = entries.get(sessionId)
    if (!entry) return
    entry.subscribers.delete(event.sender)
    if (!isWatched(entry)) dropPlanSession(sessionId)
  })
}
