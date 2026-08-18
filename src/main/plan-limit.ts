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

/* -------------------------------------------------------------------------- */
/* Recognising the panel itself, as opposed to the numbers in it               */
/* -------------------------------------------------------------------------- */

/**
 * The tab row Claude Code draws across the top of every one of its settings
 * panes, `/usage` included.
 *
 * Transcribed from two real screens rather than guessed: a PTY here on
 * 2026-08-18 running Claude Code 2.1.234, which drew
 * `   Settings  Status   Config   Usage   Stats`, and a Windows recording of
 * 2.1.224 which drew the same five words with its own spacing. The whole line
 * has to be those five words and nothing else, which is what keeps an agent
 * that happens to write the word "Settings" from reading as an open panel.
 *
 * This is a different question from {@link parsePlanLimits} and the difference
 * is the whole of the bug this was written for. That function answers *"are
 * there limits on this screen"*; this one answers *"is this app's panel sitting
 * over somebody's work"*. On an account with no subscription limits the first
 * is permanently no and the second is yes, and an app that only knows how to
 * ask the first will type `/usage`, find nothing, and walk away leaving the
 * panel open — which is exactly what a fifteen-second recording from his
 * Windows machine shows, repeatedly.
 */
const PANEL_TABS = /^\s*Settings\s+Status\s+Config\s+Usage\s+Stats\s*$/m

/**
 * The heading over the panel's lower half, which is on screen whenever the
 * panel is.
 *
 * A second, independent marker, because the tab row can be scrolled off: the
 * panel is taller than a 40-row viewport — measured here, the CLI drew a `↓`
 * in the corner — and a reader who scrolls has not closed anything.
 */
const PANEL_CONTRIBUTORS = /contributing to your limits usage/i

/** True when Claude Code's `/usage` panel is on the screen. */
export function usagePanelOnScreen(screen: string): boolean {
  const flat = stripAnsi(screen)
  return PANEL_TABS.test(flat) || PANEL_CONTRIBUTORS.test(flat)
}

/**
 * The panel's own words while it is still working.
 *
 * It walks the local transcript store to answer *"what's contributing to your
 * limits usage?"*, and says so, with `Esc to cancel` underneath. Two things
 * follow, and the second is the one that was got wrong.
 *
 * The first is that a scan in progress means *still working*, not *nothing
 * here*, so a reader of this screen has to keep waiting rather than conclude.
 *
 * The second is that the offer of Escape belongs to the scan. The plan-limit
 * bars are drawn from a network call the CLI makes on opening the panel and
 * they do not wait for the scan — measured here at 104ms against a scan that
 * ran for 2273ms over a 3.6GB store — so waiting for the scan buys nothing and
 * costs the panel sitting on somebody's screen for as long as it takes. On the
 * Windows recording the scan was still running ten seconds in.
 */
const PANEL_SCANNING = /Scanning local sessions/i

/** True while the panel's transcript scan is still running. */
export function usagePanelScanning(screen: string): boolean {
  return PANEL_SCANNING.test(stripAnsi(screen))
}

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
  /** Set by {@link dispose}; see {@link flush} for the one thing it changes. */
  private disposed = false

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

  /**
   * Resolve once everything pushed so far is on the screen.
   *
   * `Terminal.write` is asynchronous — xterm queues the bytes and parses them on
   * its own schedule — so "I pushed four chunks" and "the screen shows four
   * chunks" are different moments, and nothing outside this class can tell them
   * apart. The empty write with a callback is xterm's own way of asking; it is
   * exactly what the settle timer above already does before it reads.
   *
   * It exists because a test waited one macrotask instead and passed on the
   * machine it was written on for weeks, then failed on the Windows runner that
   * gates releases — a loaded machine simply loses that race. A test that has to
   * guess how long a parser takes is measuring the parser, not the thing it is
   * about. This makes the wait exact.
   */
  flush(): Promise<void> {
    /*
     * A disposed terminal never calls the callback, and a caller that awaits it
     * would wait for the life of the process.
     *
     * Not hypothetical since this became something `refresh` awaits inside a
     * loop: closing the tab a refresh is running against calls
     * `dropPlanSession`, which disposes this — and an unresolved promise there
     * would leave `plan:refresh` pending for ever and `refreshing` stuck true,
     * so the session could never be read again even if it came back.
     */
    if (this.disposed) return Promise.resolve()
    return new Promise((resolve) => {
      this.term.write('', () => resolve())
    })
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

  /** True when Claude Code's `/usage` panel is on this session's screen. */
  panelOnScreen(): boolean {
    return usagePanelOnScreen(this.screen())
  }

  /** True while that panel is still walking the local transcript store. */
  panelScanning(): boolean {
    return usagePanelScanning(this.screen())
  }

  /**
   * True when the panel this app opened is demonstrably gone.
   *
   * Two independent positives, either of which is enough, because each covers
   * the other's blind spot.
   *
   * The panel marker being *absent* is the direct answer, and it is the one
   * that can be wrong in the app's favour: on a screen with conversation above
   * it the CLI draws the panel into the region the prompt normally occupies,
   * and this code cannot promise that no trace of that text is left in the
   * viewport once it has been dismissed. So a lingering marker alone must not
   * be reported as "I could not close it" — a false alarm of that kind is a
   * lie in the other direction, and it would arrive with an extra Escape in
   * somebody's terminal.
   *
   * The prompt box being *back* is the other, and it cannot linger: the CLI
   * draws it only when it is at the prompt, and it is drawn nowhere inside the
   * panel — verified on a real PTY here, where `promptIsEmpty` was false for
   * every frame the panel was up and true on the first frame after Escape.
   */
  panelClosed(): boolean {
    return this.promptIsEmpty() || !this.panelOnScreen()
  }

  dispose(): void {
    this.disposed = true
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
  /**
   * A terminal answer this session has already given, or null.
   *
   * Set when a `/usage` ran to completion and established something that will
   * not change by being asked again: the panel has no plan-limit section for
   * this account, or the panel would not close. While it is set, nothing this
   * app decides to do on its own types into the session again — only a person
   * pressing, which clears it. See `refresh`, and `RefreshReason`.
   *
   * It is here rather than in the renderer because this is the side that types.
   * A window that reloaded, or a second window that never saw the first
   * refusal, would otherwise be able to walk straight past the block and put
   * the panel back on somebody's conversation.
   */
  blocked: RefreshReason
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
    blocked: null,
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

/**
 * Why a refresh did not produce a reading.
 *
 * Two of these are new on 2026-08-18 and they are the two that mattered. The
 * list used to end at `no-panel`, which said *"Claude Code did not show its
 * usage panel"* and was used for every failure including the one where the
 * panel was shown, was read, contained no plan limits at all, and was left
 * sitting on the screen.
 */
export type RefreshReason =
  | 'unwired'
  | 'not-watching'
  | 'busy'
  | 'prompt-busy'
  | 'no-panel'
  /**
   * The panel opened and settled and has no plan-limit section in it.
   *
   * Not a timeout and not a slow answer — an answer. Claude Code draws
   * `Current session` and `Current week` from the subscription's own limits,
   * and an account billed through the API has none, so those blocks are simply
   * absent. Frames from his Windows machine show exactly that: the panel
   * complete, `Usage by model` with dollar costs against it, and no bars
   * anywhere between the cost block and *"What's contributing to your limits
   * usage?"*.
   *
   * It is terminal for the session, which is the point of separating it. The
   * old code could not tell this apart from "the CLI is being slow", so it
   * waited eight seconds, gave up, and let the automatic fetcher come back and
   * do it again — every twenty seconds, for as long as the session was open.
   */
  | 'no-limits'
  /**
   * The panel was opened by this app and would not close.
   *
   * Said out loud rather than swallowed, because the alternative is what the
   * recording shows: a panel over somebody's conversation and nothing anywhere
   * that admits to having put it there. Also terminal — an app that could not
   * clean up after one attempt has no business making a second.
   */
  | 'panel-open'
  | null

export interface RefreshResult {
  ok: boolean
  /**
   * Why a refresh did not run, or did not find anything. Reported rather than
   * swallowed: a control that appears to do nothing is worse than one that says
   * why it did not.
   */
  reason: RefreshReason
  /**
   * Whether this attempt typed anything into the session at all.
   *
   * The gates above the typing — busy, prompt-busy, unwired — cost the session
   * nothing, and an attempt that cost nothing may be made again the moment the
   * gate clears. Everything after the `/usage` has been sent has left a mark on
   * somebody's screen, and the retry rule upstream is built on this distinction
   * rather than on guessing it back out of the reason.
   */
  typed: boolean
  /**
   * True when this app opened a panel it could not close.
   *
   * The one failure this feature is not allowed to have. It exists as a field
   * rather than only as a reason because it has to survive a *successful*
   * reading too: a fetch that got its numbers and then could not dismiss the
   * panel has still left something on the screen, and the person is owed that
   * sentence either way.
   */
  residue: boolean
  snapshot: PlanLimitSnapshot
}

const USAGE_COMMAND = '/usage\r'
/** Escape closes the panel — the same key a person presses to dismiss it. */
const CLOSE_PANEL = '\u001b'
const POLL_MS = 250

/**
 * The timings this operation is built out of, all measured rather than picked.
 *
 * They are a value rather than a row of module constants for one reason: a test
 * that proves a five-second rule must not spend five real seconds doing it, and
 * the alternative — a fake clock over `setTimeout` — would be measuring the
 * test harness instead of this. Nothing in the app passes anything but
 * {@link DEFAULT_TIMINGS}.
 */
export interface RefreshTimings {
  /**
   * How long the session must have been quiet before anything is typed into it.
   *
   * A second, because the thing being avoided is appending `/usage` to a line
   * somebody is in the middle of writing, or interrupting an agent mid-answer.
   */
  idleBeforeTyping: number
  /**
   * How long the panel has to appear at all before this gives up on it.
   *
   * Measured on a real PTY here on 2026-08-18: the panel was on screen and
   * parseable 104ms after the newline. Six seconds is that with two orders of
   * magnitude of slack, and it is bounded on the other side by what it costs to
   * be wrong — a session that is not running Claude Code has had `/usage`
   * submitted to it as a prompt and there is nothing to be gained by waiting
   * longer to admit it.
   */
  panelAppears: number
  /**
   * How much longer a settled panel with no limits in it gets, before that is
   * taken as the answer.
   *
   * The limits are not part of the transcript scan — they arrive with the panel
   * itself, from the network call the CLI makes on opening it — so a panel that
   * has stopped scanning and still has no `Current session` block is finished
   * rather than slow. Five seconds is for the case that reasoning is wrong: a
   * slow link, an OAuth call still in flight, a redraw caught between frames.
   */
  settledGrace: number
  /**
   * The ceiling on a panel that is open, has no limits in it, and is still
   * scanning.
   *
   * The scan is not what this is waiting for. Measured on a real PTY here: the
   * `Current session` and `Current week` bars were on screen and parseable
   * 104ms after the newline, while `Scanning local sessions…` and `Esc to
   * cancel` sat underneath them for another 2273ms — because the bars come from
   * the network call the CLI makes on opening the panel and the scan answers a
   * different question, *"what's contributing"*, which this app does not read.
   *
   * So what the scan is evidence of is only that the panel is alive rather than
   * frozen, and ten seconds is how long that is worth: long enough that a slow
   * OAuth call still lands inside it, short enough that the worst case — an
   * account that can never report, on the day the network is bad — is ten
   * seconds of panel over somebody's conversation, once, and never again.
   *
   * It was twenty for a day. Twenty is what his Windows scan needs to finish and
   * finishing is not the point: waiting out a scan whose result this app does
   * not even read would be committing the offence in order to be polite about
   * it. If a slow link ever does cost a wrong `no-limits`, the sentence says
   * what was seen and the press in the panel undoes it.
   */
  scanCeiling: number
  /**
   * How long one Escape gets to take effect before another is tried.
   *
   * Measured: on Claude Code 2.1.234 a single Escape closed the panel within
   * 103ms, both mid-scan and after it. A second and a half is that with room
   * for a machine under load.
   */
  closeSettle: number
}

export const DEFAULT_TIMINGS: RefreshTimings = {
  idleBeforeTyping: 1_000,
  panelAppears: 6_000,
  settledGrace: 5_000,
  scanCeiling: 10_000,
  closeSettle: 1_500,
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export interface PlanLimitOptions {
  /**
   * Writes to a session's PTY. Without it `plan:refresh` reports `unwired` and
   * the UI hides the control instead of offering a button that does nothing.
   */
  write?: (sessionId: string, data: string) => void
  /** See {@link RefreshTimings}. Overridden by tests and by nothing else. */
  timings?: RefreshTimings
}

/**
 * Put the panel away, and prove it went.
 *
 * ## Why this is not one `write` and a hope
 *
 * Because that is what it was, and a fifteen-second recording from his Windows
 * machine is what that cost: `/usage` typed into a live conversation, the panel
 * drawn over it, one Escape written into the pty, and the app moving on without
 * ever asking whether the Escape had done anything. It had not. The panel was
 * still there, ten seconds later, over his work.
 *
 * What is *not* known is why it had not, and this deliberately does not need to
 * know. On this Mac, with Claude Code 2.1.234 driven through a real PTY, one
 * Escape closes the panel in about a tenth of a second whether or not the
 * transcript scan is still running and still offering `Esc to cancel` — that
 * was measured three times, and it refutes the first theory, which was that the
 * scan swallows the first press. His build is 2.1.224 on Windows, where the
 * keystroke crosses a conpty rather than a Unix pty, and neither of those can
 * be tested from here. So this does the thing that is right under every one of
 * those explanations: it looks at the screen, and if the panel is still there
 * it presses Escape again, and if it is *still* there it says so.
 *
 * ## Why exactly one more, and not a loop
 *
 * A second Escape is cheap and was measured to be cheap: typed at an ordinary
 * prompt with a half-written line in it, on 2.1.234, the line survived
 * untouched. A third would be a program hammering somebody's keyboard on a
 * theory it has already twice failed to confirm. Two presses, then the truth.
 */
async function closePanel(
  entry: Entry,
  sessionId: string,
  write: (sessionId: string, data: string) => void,
  timings: RefreshTimings,
): Promise<boolean> {
  for (let press = 0; press < 2; press += 1) {
    write(sessionId, CLOSE_PANEL)
    const until = Date.now() + timings.closeSettle
    while (Date.now() < until) {
      await delay(POLL_MS)
      // Everything the CLI has sent, actually on the screen before it is read.
      // `Terminal.write` is asynchronous, so "the repaint arrived" and "the
      // repaint is in the buffer" are two moments — and reading between them is
      // the race that has already failed twice on the Windows runner while
      // passing on every Mac. See `PlanLimitTracker.flush`.
      await entry.tracker.flush()
      if (entry.tracker.panelClosed()) return true
    }
  }
  await entry.tracker.flush()
  return entry.tracker.panelClosed()
}

/**
 * Run `/usage` in a session and read the panel it draws.
 *
 * This types into the user's session, so it runs only when the session is quiet
 * *and* its prompt box is empty — otherwise the text would be appended to what
 * they were typing and submitted as a prompt. The panel is closed again with
 * Escape, which is what a person does, and — since 2026-08-18 — the close is
 * verified rather than assumed. See {@link closePanel}.
 *
 * The empty-prompt gate matches an idle prompt glyph. That is Claude Code's,
 * but it is also what several zsh themes draw, so the gate proves the box is
 * empty rather than proving which program owns it; in a plain shell the worst
 * case is an unknown command, and nothing is submitted to an agent.
 *
 * ## Three endings, not two
 *
 * The old loop had two: a panel with limits in it, or eight seconds of silence
 * called `no-panel`. Everything else fell into the second, and the commonest
 * "everything else" turned out to be a panel that opened perfectly and had no
 * plan-limit section in it at all, because the account is billed through the
 * API and therefore has no rolling subscription limits to draw. That is an
 * answer, not a timeout, and telling the two apart is what stops the automatic
 * fetcher trying again for ever.
 *
 * `force` is the difference between a person asking and this app deciding to
 * ask. A session that has already given a terminal answer — no limits, or a
 * panel that would not close — is not asked again on its own; a press says ask
 * anyway, and clears the block.
 */
async function refresh(
  sessionId: string,
  options: PlanLimitOptions,
  force = false,
): Promise<RefreshResult> {
  const timings = options.timings ?? DEFAULT_TIMINGS
  const entry = entries.get(sessionId)
  const refused = (reason: RefreshReason, snapshot: PlanLimitSnapshot): RefreshResult => ({
    ok: false,
    reason,
    typed: false,
    residue: false,
    snapshot,
  })

  if (!entry) return refused('not-watching', emptySnapshot(sessionId, NOT_WATCHED))
  const write = options.write
  if (!write) return refused('unwired', entry.tracker.current)
  if (force) entry.blocked = null
  // A session that has already answered "there is nothing here" is not asked
  // again by anything except a person. Enforced here rather than only in the
  // renderer because this is the side that types: a window that has forgotten
  // the block, or a second window that never knew it, must not be able to reach
  // past it into somebody's terminal.
  if (entry.blocked !== null) return refused(entry.blocked, entry.tracker.current)
  if (entry.refreshing || !entry.tracker.settled(timings.idleBeforeTyping)) {
    return refused('busy', entry.tracker.current)
  }
  if (!entry.tracker.promptIsEmpty()) return refused('prompt-busy', entry.tracker.current)

  entry.refreshing = true
  const startedAt = Date.now()
  /** The first moment the panel was seen; null while it has never been seen. */
  let panelSeenAt: number | null = null
  /** The first moment the panel was seen up and *not* scanning. */
  let settledAt: number | null = null

  const finish = async (
    ok: boolean,
    reason: RefreshReason,
    snapshot: PlanLimitSnapshot,
  ): Promise<RefreshResult> => {
    const closed = await closePanel(entry, sessionId, write, timings)
    /*
     * One rule, and it is deliberately stricter than "give up after three".
     *
     * An attempt that got as far as typing has spent something that is not this
     * app's to spend — a command submitted at somebody's prompt, a panel drawn
     * over their conversation — and if it came back with nothing to show for it,
     * doing the same thing again on a timer is how a defect becomes a habit.
     * Every one of the three endings that reaches here without a reading is also
     * one whose answer will not change for being asked again: an account with no
     * subscription limits will not grow some, a panel that ignored two Escapes
     * will not yield to a third, and a prompt that answered `/usage` with no
     * panel is not running Claude Code.
     *
     * A panel this app could not put away outranks whatever it did or did not
     * read, because it is the part the person can see.
     *
     * A reading blocks nothing. That is the healthy loop — the figure goes
     * stale, the bar says so, and the next quiet moment reads it again.
     */
    if (!closed) entry.blocked = 'panel-open'
    else if (!ok) entry.blocked = reason
    return {
      ok: closed && ok,
      reason: closed ? reason : 'panel-open',
      typed: true,
      residue: !closed,
      snapshot,
    }
  }

  try {
    write(sessionId, USAGE_COMMAND)
    for (;;) {
      await delay(POLL_MS)
      /*
       * The session can go away underneath this.
       *
       * Closing the tab drops the entry and disposes the tracker, and the pty
       * behind `write` is gone with it — so there is nothing left to read and
       * nothing left to close. Reported as `not-watching` with `typed` still
       * true, because the `/usage` really was sent: it is a statement about what
       * this attempt did, not about what survived it.
       */
      if (entries.get(sessionId) !== entry) {
        return { ok: false, reason: 'not-watching', typed: true, residue: false, snapshot: entry.tracker.current }
      }
      // Same reason as in `closePanel`: read the screen only once everything
      // pushed into it has been parsed.
      await entry.tracker.flush()
      // Confirmed: `/usage` was just typed, so what comes back is a fresh
      // answer from the CLI even if it prints the same numbers as before.
      entry.tracker.capture(Date.now(), true)
      const snapshot = entry.tracker.current
      if (snapshot.source === 'usage-panel' && snapshot.capturedAt >= startedAt) {
        return await finish(true, null, snapshot)
      }

      const now = Date.now()
      if (entry.tracker.panelOnScreen()) {
        if (panelSeenAt === null) panelSeenAt = now
        if (entry.tracker.panelScanning()) {
          // Still working. Keep waiting — but not for ever: the limits do not
          // come from the scan, so a scan that outlives this ceiling is holding
          // the panel over somebody's work for a result this app never reads.
          settledAt = null
          if (now - panelSeenAt >= timings.scanCeiling) {
            return await finish(false, 'no-limits', entry.tracker.current)
          }
          continue
        }
        if (settledAt === null) settledAt = now
        else if (now - settledAt >= timings.settledGrace) {
          return await finish(false, 'no-limits', entry.tracker.current)
        }
        continue
      }

      // No panel yet, and no panel is different from an empty one: the session
      // may not be running Claude Code at all.
      if (now - startedAt >= timings.panelAppears) {
        return await finish(false, 'no-panel', entry.tracker.current)
      }
    }
  } finally {
    entry.refreshing = false
  }
}

/**
 * Register the plan-limit IPC handlers.
 *
 * Channels:
 *  - `plan:watch`   (invoke, sessionId) -> PlanLimitSnapshot   subscribe; pushes `plan:update`
 *  - `plan:refresh` (invoke, sessionId, force?) -> RefreshResult  runs /usage in the session
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

  /*
   * `force` is a person pressing, and it is the only thing that can reach past
   * a session's terminal answer. Read defensively rather than trusted: a build
   * whose renderer predates the argument sends nothing at all, and the honest
   * default for "did somebody press this" is no.
   */
  ipcMain.handle(
    'plan:refresh',
    (_e: IpcMainInvokeEvent, sessionId: string, force?: unknown): Promise<RefreshResult> =>
      refresh(sessionKey(sessionId), options, force === true),
  )

  ipcMain.on('plan:unwatch', (event, sessionId: unknown) => {
    if (typeof sessionId !== 'string' || sessionId.length === 0) return
    const entry = entries.get(sessionId)
    if (!entry) return
    entry.subscribers.delete(event.sender)
    if (!isWatched(entry)) dropPlanSession(sessionId)
  })
}
