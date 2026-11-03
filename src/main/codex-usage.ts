/**
 * Codex's rate limits, read out of the rollout transcript it already writes.
 *
 * Unlike Claude Code, Codex does not have to be asked and does not have to be
 * on screen. Every turn it takes appends a `token_count` event to the session's
 * rollout file, and that event carries a `rate_limits` struct with the exact
 * numbers a bar wants. Read from the real files under `~/.codex/sessions/` on
 * this machine, not from documentation:
 *
 *     {"timestamp":"2026-04-30T01:58:04.123Z","type":"event_msg","payload":{
 *       "type":"token_count","info":null,"rate_limits":{
 *         "limit_id":"codex","limit_name":null,
 *         "primary":{"used_percent":33.0,"window_minutes":300,"resets_at":1777519084},
 *         "secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":1777962625},
 *         "credits":null,"plan_type":"prolite","rate_limit_reached_type":null}}}
 *
 * Three things about that record decided the shape of this module.
 *
 * **`primary` is not always the five-hour window.** The investigation that
 * preceded this file recorded `primary` as the 300-minute window and
 * `secondary` as the 10080-minute one, which is what a `prolite` account looks
 * like. Two other accounts' rollouts on this same machine disagree: a `free`
 * account has `primary.window_minutes` of 10080 with no secondary at all, and a
 * `go` account has 43200 with no secondary. So the window a reading describes
 * comes from `window_minutes`, always, and never from which key it arrived
 * under. Trusting the key name would have drawn a monthly figure as a
 * five-hour bar for anybody on the wrong plan.
 *
 * **`resets_at` is a Unix instant in seconds.** 1777519084 is 2026-04-30
 * 05:58 UTC, eight minutes after the rollout that carries it was written —
 * checked against the file's own name. It is comparable to the clock, which is
 * what makes {@link usageFreshness} able to say a Codex reading has expired.
 *
 * **The record only exists when a turn ran.** This is the whole reason
 * `reportedAt` exists as a separate field from `observedAt`. A rollout's last
 * `rate_limits` can be months old — the newest one on this machine is from
 * 2026-06-04 — and it is *exactly right about 2026-06-04*. Presenting it as
 * current is the bug this feature nearly shipped, so the line's own timestamp
 * travels with the numbers and every consumer gets to see the gap.
 *
 * Nothing here reads `auth.json`. `profiles-signin.ts` set that rule — "reading
 * a user's credential file to decorate a row is not a trade this app makes" —
 * and it applies twice over here, because the account these numbers belong to
 * is already fully determined by *which `CODEX_HOME` the rollout was found in*.
 * The credential adds nothing but risk.
 */

import { watch, type FSWatcher } from 'node:fs'
import { open, readdir, stat } from 'node:fs/promises'
import { join } from 'node:path'
import {
  fractionFromPercent,
  readingId,
  resetAtEpoch,
  windowFromMinutes,
  type UsageAccountRef,
  type UsageWindowReading,
} from './usage-window'

/* -------------------------------------------------------------------------- */
/* Locating rollouts                                                           */
/* -------------------------------------------------------------------------- */

/** Codex files rollouts as `sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl`. */
const SESSIONS_DIR = 'sessions'
/**
 * A second, flat directory of rollouts beside the dated tree.
 *
 * `~/.codex/archived_sessions/` holds the same file format with the same
 * `rate_limits` events — verified on this machine — and it is searched because
 * "archived" describes what the user did with a conversation, not how long ago
 * they had it. Leaving it out would have this module report nothing for an
 * account whose only recent turn was in a session since tidied away.
 */
const ARCHIVED_DIR = 'archived_sessions'

/** How many dated day-directories to look inside, newest first. */
const MAX_DAYS_SCANNED = 5
/** Hard ceiling on files opened for one read. */
const MAX_FILES_SCANNED = 8
/**
 * Once this many files have been examined, a reading already in hand is good
 * enough to stop on.
 *
 * More than one, because the newest file by modification time is not
 * guaranteed to hold the newest `rate_limits` — several rollouts can be open at
 * once, and only some of them take turns. Three covers that without turning a
 * cheap read into a directory crawl.
 */
const ENOUGH_FILES = 3

interface Candidate {
  path: string
  mtimeMs: number
}

async function listDir(dir: string): Promise<string[]> {
  try {
    return await readdir(dir)
  } catch {
    // Missing is the ordinary case for an account that has never run Codex, and
    // unreadable is the ordinary case for a directory this app was not granted.
    // Neither is an error worth surfacing: the caller reports "nothing".
    return []
  }
}

async function candidatesIn(dir: string): Promise<Candidate[]> {
  const names = await listDir(dir)
  const found: Candidate[] = []
  for (const name of names) {
    if (!name.endsWith('.jsonl')) continue
    const path = join(dir, name)
    try {
      const info = await stat(path)
      if (info.isFile()) found.push({ path, mtimeMs: info.mtimeMs })
    } catch {
      /* vanished between readdir and stat — a live session being rotated */
    }
  }
  return found
}

/** Newest first, by name. Zero-padded date components sort chronologically. */
function newestFirst(names: string[]): string[] {
  return [...names].sort((a, b) => b.localeCompare(a))
}

/**
 * The rollout files worth opening, newest modification first.
 *
 * The dated tree is walked from the newest year down rather than crawled: a
 * long-lived `~/.codex` has a directory per day going back months, and the
 * answer to "what did Codex last report" is never in a directory from March.
 */
export async function findCodexRollouts(codexHome: string): Promise<string[]> {
  const root = join(codexHome, SESSIONS_DIR)
  const candidates: Candidate[] = []

  let daysSeen = 0
  for (const year of newestFirst(await listDir(root))) {
    if (daysSeen >= MAX_DAYS_SCANNED) break
    const yearDir = join(root, year)
    for (const month of newestFirst(await listDir(yearDir))) {
      if (daysSeen >= MAX_DAYS_SCANNED) break
      const monthDir = join(yearDir, month)
      for (const day of newestFirst(await listDir(monthDir))) {
        if (daysSeen >= MAX_DAYS_SCANNED) break
        daysSeen += 1
        candidates.push(...(await candidatesIn(join(monthDir, day))))
      }
    }
  }

  candidates.push(...(await candidatesIn(join(codexHome, ARCHIVED_DIR))))
  return candidates
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(0, MAX_FILES_SCANNED)
    .map((candidate) => candidate.path)
}

/* -------------------------------------------------------------------------- */
/* Reading one rollout backwards                                               */
/* -------------------------------------------------------------------------- */

/**
 * How much of a file's tail to read looking for the last rate-limit event.
 *
 * The events are frequent — one per turn — so the last of them is close to the
 * end of the file. 256 KB covers a final turn with a large tool result in it;
 * the escalation covers the pathological case of a single enormous last event,
 * and 4 MB is where it stops, because a rollout on this machine reaches 6.4 MB
 * and reading all of it to decorate a bar is not a trade worth making.
 */
const TAIL_STEPS = [256 * 1024, 4 * 1024 * 1024]

/** Cheap pre-filter, the same trick `transcript.ts` uses to skip most lines. */
const MARKER = '"rate_limits"'

/** One window as Codex writes it. Every field is checked, never cast. */
interface CodexWindow {
  usedPercent: number | null
  windowMinutes: number | null
  resetsAt: number | null
}

export interface CodexRateLimits {
  /** When the line carrying this record was written — the turn's own clock. */
  reportedAt: number
  windows: CodexWindow[]
}

function numberOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function readWindow(raw: unknown): CodexWindow | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const window: CodexWindow = {
    usedPercent: numberOrNull(record.used_percent),
    windowMinutes: numberOrNull(record.window_minutes),
    resetsAt: numberOrNull(record.resets_at),
  }
  // A window with no percentage in it is not a reading, it is an empty slot —
  // which is what `"secondary":null` already says more clearly. Dropping it
  // here keeps a "not reported" bar from appearing for a limit that does not
  // exist on this plan at all.
  return window.usedPercent === null ? null : window
}

/**
 * Pull the rate-limit record out of one rollout line, or null if it has none.
 *
 * Exported because it is the whole parse, and a parse of somebody else's file
 * format is the part most likely to drift when they change it.
 */
export function parseRolloutLine(line: string, fallbackAt: number): CodexRateLimits | null {
  if (!line.includes(MARKER)) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    // A truncated first line from a tail read, or a half-written last line from
    // a session mid-turn. Both are expected; neither is worth a log line.
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const event = parsed as Record<string, unknown>
  const payload = event.payload
  if (typeof payload !== 'object' || payload === null) return null
  const limits = (payload as Record<string, unknown>).rate_limits
  if (typeof limits !== 'object' || limits === null) return null

  const record = limits as Record<string, unknown>
  const windows: CodexWindow[] = []
  // Both keys, and the window each one describes is decided by its own
  // `window_minutes` further down. See the module header: `primary` is the
  // five-hour window on one plan and the monthly window on another.
  for (const key of ['primary', 'secondary'] as const) {
    const window = readWindow(record[key])
    if (window) windows.push(window)
  }
  if (windows.length === 0) return null

  const stamped = typeof event.timestamp === 'string' ? Date.parse(event.timestamp) : Number.NaN
  return {
    reportedAt: Number.isFinite(stamped) ? stamped : fallbackAt,
    windows,
  }
}

/**
 * The last rate-limit record in a file, read from the end.
 *
 * Reads backwards rather than forwards because the answer is always the most
 * recent turn and a rollout is mostly conversation. The first line of a tail
 * chunk is usually a fragment; it fails `JSON.parse` and is skipped, which is
 * why no offset bookkeeping is needed to make this safe.
 */
export async function readLastRateLimits(path: string): Promise<CodexRateLimits | null> {
  let size: number
  let mtimeMs: number
  try {
    const info = await stat(path)
    size = info.size
    mtimeMs = info.mtimeMs
  } catch {
    return null
  }
  if (size === 0) return null

  for (const step of TAIL_STEPS) {
    const length = Math.min(step, size)
    const buffer = Buffer.allocUnsafe(length)
    let handle
    try {
      handle = await open(path, 'r')
    } catch {
      return null
    }
    try {
      const { bytesRead } = await handle.read(buffer, 0, length, size - length)
      if (bytesRead > 0) {
        const lines = buffer.subarray(0, bytesRead).toString('utf8').split('\n')
        for (let i = lines.length - 1; i >= 0; i -= 1) {
          const found = parseRolloutLine(lines[i], mtimeMs)
          if (found) return found
        }
      }
    } catch {
      return null
    } finally {
      await handle.close().catch(() => {})
    }
    // Nothing in that much of the tail, and there is no more file to read.
    if (length >= size) return null
  }
  return null
}

/* -------------------------------------------------------------------------- */
/* Readings                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * How to say a window's length when Codex has not named it.
 *
 * `limit_name` is null in every rollout on this machine, so there are no words
 * to carry through and something has to be written. What is written is the one
 * fact the source did give — the length — rather than a plan-specific name that
 * would be a guess about what OpenAI calls it this month.
 */
export function describeCodexWindow(minutes: number | null): string {
  if (minutes === 300) return '5-hour limit'
  if (minutes === 10080) return 'Weekly limit'
  if (minutes === 43200) return '30-day limit'
  if (minutes === null) return 'Rate limit'
  if (minutes % 1440 === 0) return `${minutes / 1440}-day limit`
  if (minutes % 60 === 0) return `${minutes / 60}-hour limit`
  return `${minutes}-minute limit`
}

/**
 * Every window Codex last reported for one account.
 *
 * Empty means nothing has been reported — no rollouts, or none carrying a
 * rate-limit record within the files worth opening. That is a different fact
 * from "nothing is used", and the caller must say so.
 */
export async function readCodexUsage(
  codexHome: string,
  account: UsageAccountRef,
  now = Date.now(),
): Promise<UsageWindowReading[]> {
  const paths = await findCodexRollouts(codexHome)
  let best: CodexRateLimits | null = null
  let examined = 0

  for (const path of paths) {
    examined += 1
    const found = await readLastRateLimits(path)
    // Newest wins on the *turn's* timestamp, not the file's. Several rollouts
    // can be open at once and the file touched most recently is not necessarily
    // the one that last spoke to the API.
    if (found && (!best || found.reportedAt > best.reportedAt)) best = found
    if (best && examined >= ENOUGH_FILES) break
  }
  if (!best) return []

  const readings: UsageWindowReading[] = []
  const seen = new Set<string>()
  for (const window of best.windows) {
    const kind = windowFromMinutes(window.windowMinutes)
    // Two windows of the same length in one record would be a format change,
    // not a second limit; the length is the identity here, so the first wins
    // rather than the pair colliding on one id.
    const id = readingId(account, kind, kind === 'other' ? String(window.windowMinutes ?? '?') : '')
    if (seen.has(id)) continue
    seen.add(id)
    readings.push({
      id,
      account,
      window: kind,
      windowMinutes: window.windowMinutes,
      label: describeCodexWindow(window.windowMinutes),
      used: fractionFromPercent(window.usedPercent),
      resets: resetAtEpoch(window.resetsAt),
      observedAt: now,
      reportedAt: best.reportedAt,
      source: 'codex-rollout',
    })
  }
  return readings
}

/* -------------------------------------------------------------------------- */
/* Watching                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Long enough for a turn's burst of appends to finish before re-reading.
 *
 * Codex writes several events per turn and the rate-limit one is not the last,
 * so a watcher that re-read on the first change would read the file three times
 * and get the same answer twice.
 */
const SETTLE_MS = 750

/**
 * Re-reads an account's rollouts when Codex writes to them.
 *
 * A watcher rather than a timer, for the reason Asad has given more than once:
 * never poll what already pushes. Codex appends to the rollout the instant a
 * turn ends, and `fs.watch` on the sessions tree is that event. There is no
 * interval in this file.
 */
export class CodexUsageWatcher {
  private watcher: FSWatcher | undefined
  private timer: NodeJS.Timeout | undefined
  private reading = false
  private again = false
  private disposed = false

  constructor(
    private readonly codexHome: string,
    private readonly account: UsageAccountRef,
    private readonly onChange: (readings: UsageWindowReading[]) => void,
  ) {}

  /**
   * Start watching, and take the first reading.
   *
   * Returns whether a watcher was actually attached. False means the account
   * has no sessions directory — Codex has never run under it — and the caller
   * has a one-shot reading and nothing that will ever update it, which it must
   * not present as live.
   */
  async start(): Promise<boolean> {
    await this.reload()
    if (this.disposed) return false
    try {
      // Recursive because the rollouts are three directories down, under a path
      // that gains a new component at midnight. Supported on macOS and Windows;
      // on a platform without it the catch below leaves the one-shot reading.
      this.watcher = watch(join(this.codexHome, SESSIONS_DIR), { recursive: true }, () =>
        this.schedule(),
      )
      this.watcher.on('error', () => this.stopWatching())
      return true
    } catch {
      return false
    }
  }

  private schedule(): void {
    if (this.disposed) return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => void this.reload(), SETTLE_MS)
  }

  private async reload(): Promise<void> {
    if (this.disposed) return
    // A read is several file opens; a burst of writes during one would queue a
    // read per event. Collapse them into a single follow-up instead.
    if (this.reading) {
      this.again = true
      return
    }
    this.reading = true
    try {
      const readings = await readCodexUsage(this.codexHome, this.account)
      if (!this.disposed) this.onChange(readings)
    } catch (err) {
      console.error('[codex-usage] could not read rollouts:', err)
    } finally {
      this.reading = false
      if (this.again && !this.disposed) {
        this.again = false
        this.schedule()
      }
    }
  }

  private stopWatching(): void {
    this.watcher?.close()
    this.watcher = undefined
  }

  dispose(): void {
    this.disposed = true
    clearTimeout(this.timer)
    this.stopWatching()
  }
}
